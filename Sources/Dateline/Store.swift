// The calendars and events, from the Mac's own calendar store (F1, J3: the accounts already set up on this Mac, nothing leaves it).
// Sample mode (--sample, and every test) uses made-up calendars in memory and never asks for calendar access.
import Foundation
import EventKit
import SwiftUI

struct CalInfo: Identifiable, Hashable {
    let id: String
    var title: String
    var account: String
    var color: Color
    var writable: Bool
}

struct Item: Identifiable, Equatable {
    var id: String
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var place: String
    var notes: String
    var showAs: ShowAs
    // Kept by Dateline on this Mac only (Phase 3), never written to the calendar: works on invites from others too.
    var emoji = ""
    var color: Int? = nil  // a place in Palette.tags; nil = the calendar's color
    var tags: [String] = []
    var rich: Data? = nil  // the notes with their formatting (RTF); the calendar gets the plain text
    var shownTitle: String { emoji.isEmpty ? title : emoji + " " + title }
}

// What Dateline adds to one event, saved on this Mac by the event's identifier.
struct Extra: Codable, Equatable {
    var emoji = "", color: Int? = nil, tags: [String] = [], rich: Data? = nil
    var plain: String? = nil  // the notes text `rich` was made from; if the notes changed elsewhere, the formatting is dropped
    var isEmpty: Bool { emoji.isEmpty && color == nil && tags.isEmpty && rich == nil }
}

// A calendar set (B6, F7): which calendars it shows and where its new events go.
struct CalSet: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var calendars: [String]
    var defaultCalendar: String?
    var lists: [String]? = nil  // Reminders lists shown (Phase 4); nil = sets saved before Phase 4, which leave lists alone
}

// The set whose calendars are exactly the ones shown (calendars no longer on this Mac are ignored).
func activeSet(_ sets: [CalSet], calendars: [String], hidden: Set<String>) -> CalSet? {
    let all = Set(calendars), shown = all.subtracting(hidden)
    if shown == all { return nil }  // "All calendars" is picked, even when a set holds every calendar
    return sets.first { Set($0.calendars).intersection(all) == shown }
}

// Same event in the calendar's eyes: only Dateline's own extras may differ.
func sameInCalendar(_ a: Item, _ b: Item) -> Bool {
    var a = a, b = b
    a.emoji = ""; a.color = nil; a.tags = []; a.rich = nil
    b.emoji = ""; b.color = nil; b.tags = []; b.rich = nil
    return a == b
}

@MainActor
final class Store: ObservableObject {
    @Published var calendars: [CalInfo] = []
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenCalendars") }
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var soon: [Item] = []  // the next 120 days, for the "Coming up" card
    @Published var access: Access = .unknown
    @Published var defaultCalendarID: String?
    @Published var sets: [CalSet] = [] { didSet { save(sets, "calendarSets") } }
    @Published var recentEmoji: [String] = [] { didSet { save(recentEmoji, "recentEmoji") } }
    enum Access { case unknown, granted, denied, sample }

    let ek = EKEventStore()
    private var range: (Date, Date) = (Date(), Date())
    private var sample: [Item] = []
    private var observer: Any?
    // Phase 4: Apple Reminders (Tasks.swift).
    @Published var lists: [CalInfo] = []
    @Published var hiddenLists: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenLists") ?? []) {
        didSet { if access != .sample { UserDefaults.standard.set(Array(hiddenLists), forKey: "hiddenLists") } }
    }
    @Published var todos: [ToDo] = []
    @Published var taskAccess: Access = .unknown
    var taskObserver: Any?
    var taskFetch = 0  // only the newest Reminders read is kept

    private var deletedAlarms: [String: [EKAlarm]] = [:]
    private var extras: [String: Extra] = [:] { didSet { save(extras, "eventExtras") } }

    init(sample: Bool) {
        if sample { loadSample(); return }
        // Only when the saved copy reads back: a copy that fails to read must not be overwritten with an empty one.
        if let v: [CalSet] = load("calendarSets") { sets = v }
        if let v: [String] = load("recentEmoji") { recentEmoji = v }
        if let v: [String: Extra] = load("eventExtras") { extras = v }
        requestAccess()
        requestReminders()
    }

    // Dateline's own saved data. Sample mode (every test and picture) keeps it in memory only.
    private func save<T: Encodable>(_ v: T, _ key: String) {
        guard access != .sample, let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    private func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    var activeSet: CalSet? { Dateline.activeSet(sets, calendars: calendars.map(\.id), hidden: hidden) }

    // Shows only that set's calendars; nil = all calendars.
    func use(_ s: CalSet?) {
        hidden = s.map { Set(calendars.map(\.id)).subtracting($0.calendars) } ?? []
        if s == nil { hiddenLists = [] } else if let l = s?.lists, !lists.isEmpty { hiddenLists = Set(lists.map(\.id)).subtracting(l) }
    }

    // Every tag in use and how many events have it, most used first.
    var allTags: [(String, Int)] {
        let lists = access == .sample ? sample.map(\.tags) : extras.values.map(\.tags)
        return Dictionary(lists.flatMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +).sorted { ($1.1, $0.0) < ($0.1, $1.0) }
    }

    func usedEmoji(_ e: String) { recentEmoji = Array(([e] + recentEmoji.filter { $0 != e }).prefix(16)) }

    // A repeating event's occurrences share their extras.
    private func key(_ id: String) -> String { String(resolve(id).split(separator: "|").first ?? "") }

    private func decorated(_ it: Item) -> Item {
        guard let x = extras[key(it.id)] else { return it }
        var it = it
        it.emoji = x.emoji; it.color = x.color; it.tags = x.tags
        if x.plain == it.notes { it.rich = x.rich }
        return it
    }

    private func setExtras(_ it: Item) {
        let x = Extra(emoji: it.emoji, color: it.color, tags: it.tags, rich: it.rich, plain: it.rich == nil ? nil : it.notes)
        if extras[key(it.id)] != (x.isEmpty ? nil : x) { extras[key(it.id)] = x.isEmpty ? nil : x }
    }

    func calendar(_ id: String) -> CalInfo? { calendars.first { $0.id == id } }

    private func requestAccess() {
        ek.requestFullAccessToEvents { ok, _ in
            Task { @MainActor in
                self.access = ok ? .granted : .denied
                guard ok else { return }
                self.reloadCalendars()
                // Changes made in Apple Calendar or on another device show up here straight away.
                self.observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.ek, queue: .main) { _ in
                    Task { @MainActor in self.reloadCalendars() }
                }
            }
        }
    }

    private func reloadCalendars() {
        calendars = ek.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { CalInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(nsColor: $0.color), writable: $0.allowsContentModifications) }
        defaultCalendarID = ek.defaultCalendarForNewEvents?.calendarIdentifier
        pastCache = nil
        fetch()
    }

    // Loads the events between two dates (the visible view plus a margin).
    func show(from: Date, to: Date) {
        range = (from, to)
        fetch()
    }

    private func fetch() {
        let (a, b) = range
        let now = sampleToday ?? Date(), later = now.addingTimeInterval(120 * 86400)
        if access == .sample {
            items = sample.filter { $0.end > a && $0.start < b }.sorted { $0.start < $1.start }
            soon = sample.filter { $0.end > now && $0.start < later }
            return
        }
        guard access == .granted else { return }
        let pred = ek.predicateForEvents(withStart: a, end: b, calendars: nil)
        items = ek.events(matching: pred).map { decorated(Self.item($0)) }.sorted { $0.start < $1.start }
        soon = ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-86400), end: later, calendars: nil)).map { decorated(Self.item($0)) }
    }

    // The last year's events, one per title, newest first (quick add's "From your past events"). Kept until the calendars change.
    private var pastCache: [Item]?
    func past() -> [Item] {
        if let pastCache { return pastCache }
        let now = sampleToday ?? Date()
        let list = access == .sample ? sample.filter { $0.start < now }
            : access == .granted ? ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-365 * 86400), end: now, calendars: nil)).map(Self.item) : []
        var seen = Set<String>()
        let out = list.sorted { $0.start > $1.start }.filter { seen.insert($0.title.lowercased()).inserted }
        pastCache = out
        return out
    }

    private static func item(_ e: EKEvent) -> Item {
        let s: ShowAs = e.availability == .free ? .free : e.availability == .tentative ? .maybe : .busy
        // A repeating event's occurrences share one identifier; the start date tells them apart. A one-time event keeps its plain identifier so moving it keeps it selected.
        let occ = e.hasRecurrenceRules ? "|" + String(e.occurrenceDate?.timeIntervalSince1970 ?? 0) : ""
        return Item(id: (e.eventIdentifier ?? UUID().uuidString) + occ,
                    calendarID: e.calendar.calendarIdentifier, title: e.title ?? "", start: e.startDate, end: e.endDate,
                    allDay: e.isAllDay, place: e.location ?? "", notes: e.notes ?? "", showAs: s)
    }

    private func ekEvent(_ it: Item) -> EKEvent? {
        let parts = resolve(it.id).split(separator: "|")
        guard let id = parts.first.map(String.init) else { return nil }
        guard parts.count == 2, let t = Double(parts[1]) else { return ek.event(withIdentifier: id) }
        // One occurrence of a repeating event: search between its original date and where it is now (it may have been moved).
        // Never fall back to the series, or a change would land on the wrong occurrence.
        let at = Date(timeIntervalSince1970: t)
        let pred = ek.predicateForEvents(withStart: min(at, it.start).addingTimeInterval(-86400), end: max(at, it.end).addingTimeInterval(86400), calendars: nil)
        return ek.events(matching: pred).first { $0.eventIdentifier == id && $0.occurrenceDate == at }
    }

    // An event deleted and then put back by undo gets a new identifier; older undo steps still hold the old one.
    private var replaced: [String: String] = [:]
    private func resolve(_ id: String) -> String {
        var id = id
        while let n = replaced[id] { id = n }
        return id
    }

    // Adds a new event; returns the saved item, or an error message.
    @discardableResult
    func add(_ p: Parsed, calendarID: String?) -> Result<Item, Failure> {
        let calID = calendarID ?? defaultCalendarID ?? calendars.first(where: \.writable)?.id
        guard let calID else { return .failure(Failure("No calendar on this Mac can take new events.")) }
        var it = Item(id: UUID().uuidString, calendarID: calID, title: p.title.isEmpty ? "New event" : p.title, start: p.start, end: p.end,
                      allDay: p.allDay, place: p.place, notes: "", showAs: p.showAs)
        if access == .sample { sample.append(it); fetch(); return .success(it) }
        guard let c = ek.calendar(withIdentifier: calID) else { return .failure(Failure("That calendar is gone.")) }
        let e = EKEvent(eventStore: ek)
        e.calendar = c
        apply(it, to: e)
        if let m = p.alertMinutes { e.addAlarm(EKAlarm(relativeOffset: -Double(m * 60))) }
        if let r = p.repeats {
            let f: [Character: EKRecurrenceFrequency] = ["d": .daily, "w": .weekly, "m": .monthly, "y": .yearly]
            e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: f[r.unit]!, interval: r.n, end: nil))
        }
        do { try ek.save(e, span: .thisEvent, commit: true) } catch { return .failure(Failure(error.localizedDescription)) }
        it = Self.item(e)
        fetch()
        return .success(it)
    }

    // Saves changes to an event (move, stretch, edits in the details panel). Repeating events change this occurrence only.
    @discardableResult
    func update(_ it: Item) -> Failure? {
        if access == .sample {
            guard let i = sample.firstIndex(where: { $0.id == resolve(it.id) }) else { return Failure("That event is gone.") }
            sample[i] = it; sample[i].id = resolve(it.id)
            fetch(); return nil
        }
        // Only Dateline's extras changed (also on read-only calendars and invites): nothing goes to the calendar.
        if let old = items.first(where: { $0.id == it.id }), sameInCalendar(old, it) { setExtras(it); fetch(); return nil }
        guard let e = ekEvent(it) else { return Failure("That event is gone.") }
        if e.calendar.calendarIdentifier != it.calendarID, let c = ek.calendar(withIdentifier: it.calendarID) { e.calendar = c }
        apply(it, to: e)
        let oldKey = key(it.id)
        do { try ek.save(e, span: .thisEvent, commit: true) } catch { fetch(); return Failure(error.localizedDescription) }
        // Moving to another calendar can give the event a new identifier: the extras move with it.
        if let nid = e.eventIdentifier, nid != oldKey { extras[oldKey] = nil; var moved = it; moved.id = nid; setExtras(moved) } else { setExtras(it) }
        fetch()
        return nil
    }

    // `series`: this and every later occurrence (undo of adding a repeating event).
    @discardableResult
    func delete(_ it: Item, series: Bool = false) -> Failure? {
        if access == .sample {
            guard sample.contains(where: { $0.id == resolve(it.id) }) else { return Failure("That event is gone.") }
            sample.removeAll { $0.id == resolve(it.id) }; fetch(); return nil
        }
        guard let e = ekEvent(it) else { return Failure("That event is gone.") }
        let alarms = e.alarms ?? [], oneTime = !e.hasRecurrenceRules
        do { try ek.remove(e, span: series ? .futureEvents : .thisEvent, commit: true) } catch { return Failure(error.localizedDescription) }
        deletedAlarms[it.id] = alarms  // undo puts them back
        // shortcut: extras of events deleted in Apple Calendar stay saved; clean them up if the saved data ever grows large.
        if oneTime || series { extras[key(it.id)] = nil }  // undo copies them back from `it`
        fetch()
        return nil
    }

    // Undo of a delete: puts the event back as a new copy (the Mac gives it a new identifier).
    func restore(_ it: Item) -> Item? {
        guard let back = duplicate(it) else { return nil }
        replaced[it.id] = back.id
        return back
    }

    // A new one-time event with everything `it` has (Option drag, undo of a delete).
    func duplicate(_ it: Item) -> Item? {
        if access == .sample { var back = it; back.id = UUID().uuidString; sample.append(back); fetch(); return back }
        var p = Parsed(start: it.start, end: it.end); p.title = it.title; p.allDay = it.allDay; p.place = it.place; p.showAs = it.showAs
        guard case .success(let added) = add(p, calendarID: it.calendarID) else { return nil }
        var back = added
        back.notes = it.notes; back.emoji = it.emoji; back.color = it.color; back.tags = it.tags; back.rich = it.rich
        if back != added { update(back) }
        if let alarms = ekEvent(it)?.alarms ?? deletedAlarms[it.id], !alarms.isEmpty, let e = ek.event(withIdentifier: back.id) {
            alarms.forEach { a in e.addAlarm(a.absoluteDate.map(EKAlarm.init(absoluteDate:)) ?? EKAlarm(relativeOffset: a.relativeOffset)) }
            try? ek.save(e, span: .thisEvent)
        }
        return back
    }

    private func apply(_ it: Item, to e: EKEvent) {
        e.title = it.title
        e.isAllDay = it.allDay
        e.startDate = it.start
        e.endDate = it.end
        e.location = it.place.isEmpty ? nil : it.place
        e.notes = it.notes.isEmpty ? nil : it.notes
        let want: EKEventAvailability = it.showAs == .free ? .free : it.showAs == .maybe ? .tentative : .busy
        // Not every account takes every mark (many only know busy and free); keep what it allows.
        let ok = e.calendar.supportedEventAvailabilities
        if want == .busy || (want == .free && ok.contains(.free)) || (want == .tentative && ok.contains(.tentative)) { e.availability = want }
    }

    // Made-up calendars and events around the mockup's week, relative to today.
    private func loadSample() {
        access = .sample
        calendars = [
            CalInfo(id: "work", title: "Work", account: "Google (sample)", color: Palette.work, writable: true),
            CalInfo(id: "personal", title: "Personal", account: "iCloud (sample)", color: Palette.personal, writable: true),
            CalInfo(id: "family", title: "Family", account: "iCloud (sample)", color: Palette.family, writable: true),
            CalInfo(id: "school", title: "School (sample)", account: "Subscribed (sample)", color: Color(red: 0.55, green: 0.42, blue: 0.85), writable: false),
        ]
        defaultCalendarID = "personal"
        sets = [CalSet(name: "Work", calendars: ["work"], defaultCalendar: "work"),
                CalSet(name: "Family", calendars: ["family", "personal", "school"], defaultCalendar: "family"),
                CalSet(name: "Just me", calendars: ["personal"], defaultCalendar: "personal")]
        let today = cal.startOfDay(for: sampleToday ?? Date())
        let mon = addDays(today, -((cal.component(.weekday, from: today) + 5) % 7))  // always Monday, whatever week start is saved, so samples match the mockups
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: addDays(mon, d))! }
        var n = 0
        func ev(_ c: String, _ t: String, _ d: Int, _ h: Int, _ m: Int, _ mins: Int, _ s: ShowAs = .busy, place: String = "", notes: String = "",
                emoji: String = "", color: Int? = nil, tags: [String] = []) {
            n += 1
            sample.append(Item(id: "s\(n)", calendarID: c, title: t, start: at(d, h, m), end: at(d, h, m + mins), allDay: false, place: place, notes: notes, showAs: s,
                               emoji: emoji, color: color, tags: tags))
        }
        ev("personal", "Lunch with Sam", -14, 12, 30, 60, place: "Casa Luna")
        ev("work", "Lunch with the team", -27, 12, 0, 60, place: "Office")
        ev("work", "Team standup", 0, 9, 0, 30)
        ev("work", "Write proposal", 0, 10, 0, 120, notes: "Sample notes: outline goals, budget and next steps for the proposal.")
        ev("personal", "Lunch with Sam", 0, 12, 30, 60, .maybe, place: "Café Playa")
        ev("family", "School pickup", 0, 15, 0, 30)
        ev("personal", "Gym", 0, 17, 30, 60, .free)
        ev("work", "Client call", 1, 11, 0, 60, place: "Zoom")
        ev("family", "Christian at the condo", 1, 13, 30, 60, notes: "Fix before he leaves:\n[x] Kitchen tap drips\n[ ] Balcony door lock sticks\n- Gate code is in the group chat",
           emoji: "🏠", color: 3, tags: ["Condo", "Visitors"])
        ev("family", "Dentist", 2, 8, 30, 60, place: "Clínica Dental", emoji: "🦷")
        ev("work", "Design review", 3, 14, 0, 90)
        ev("personal", "Dinner with Ana", 4, 19, 0, 60, place: "Casa Luna")
        ev("family", "Beach day", 5, 9, 0, 240, .free)
        loadSampleTasks(mon)
        sample.append(Item(id: "s-ad", calendarID: "school", title: "Holiday: no school", start: addDays(mon, 2), end: addDays(mon, 3), allDay: true, place: "", notes: "", showAs: .free))
        fetch()
    }
}

// Set by --render so the pictures always show the mockup's week.
var sampleToday: Date?

struct Failure: Error { let message: String; init(_ m: String) { message = m } }
