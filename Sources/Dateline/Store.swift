// The calendars and events, from the Mac's own calendar store (F1, J3: the accounts already set up on this Mac, nothing leaves it).
// Sample mode (--sample, and every test) uses made-up calendars in memory and never asks for calendar access.
import Foundation
import EventKit
import SwiftUI
import CoreLocation

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
    var geo: Geo? = nil  // where the place is on the map (Phase 5); saved in the calendar with the place, so the phone sees it too
    // Phase 5 travel, kept by Dateline on this Mac: no drive time, the leave alert (nil = the Settings default), where the drive starts.
    var noTravel = false, leave: Bool? = nil, from: From = .here
    var alerts: [Date] = []  // when the calendar's own alerts go off (Phase 6 plays the picked sound with them)
    var link = ""  // the event's own web link (Phase 8: a pasted Zoom, Meet or Teams link goes here)
    var shownTitle: String { emoji.isEmpty ? title : emoji + " " + title }
}

// What Dateline adds to one event, saved on this Mac by the event's identifier.
struct Extra: Codable, Equatable {
    var emoji = "", color: Int? = nil, tags: [String] = [], rich: Data? = nil
    var plain: String? = nil  // the notes text `rich` was made from; if the notes changed elsewhere, the formatting is dropped
    var noTravel: Bool? = nil, leave: Bool? = nil, from: From? = nil  // optional, so extras saved before Phase 5 still read back
    var isEmpty: Bool { emoji.isEmpty && color == nil && tags.isEmpty && rich == nil && noTravel == nil && leave == nil && from == nil }
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
    a.emoji = ""; a.color = nil; a.tags = []; a.rich = nil; a.noTravel = false; a.leave = nil; a.from = .here
    b.emoji = ""; b.color = nil; b.tags = []; b.rich = nil; b.noTravel = false; b.leave = nil; b.from = .here
    return a == b
}

// Phase 8: the Zoom, Meet or Teams link in an event: its own link first, then the place, then the notes.
struct Call: Equatable { let service: String, url: URL }
private let linkFinder = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
func callLink(_ it: Item) -> Call? { callLink(in: [it.link, it.place, it.notes]) }
func callLink(in texts: [String]) -> Call? {
    func on(_ h: String, _ d: String) -> Bool { h == d || h.hasSuffix("." + d) }  // never a look-alike such as evilzoom.us
    for text in texts where !text.isEmpty {
        for m in linkFinder?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let u = m.url, let h = u.host?.lowercased() else { continue }
            let path = u.path.lowercased()
            if on(h, "zoom.us"), ["/j/", "/my/", "/w/"].contains(where: path.hasPrefix) { return Call(service: "Zoom", url: u) }
            if h == "meet.google.com", path.count > 4 { return Call(service: "Google Meet", url: u) }
            if on(h, "teams.microsoft.com") || on(h, "teams.live.com"), path.contains("meetup-join") || path.hasPrefix("/meet/") { return Call(service: "Microsoft Teams", url: u) }
        }
    }
    return nil
}

@MainActor
final class Store: ObservableObject {
    @Published var calendars: [CalInfo] = []
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) {
        didSet {
            guard access != .sample else { return }  // tests and pictures never touch the real choice
            UserDefaults.standard.set(Array(hidden), forKey: "hiddenCalendars")
            // The set by name too, so a launch reopens on it even when a calendar came or went since (empty = all, or a hand-picked mix).
            if !calendars.isEmpty { UserDefaults.standard.set(activeSet?.id ?? "", forKey: "lastSet") }
        }
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
    // Phase 7: subscribed and ready-made calendars (Subscribed.swift).
    @Published var subs: [Sub] = [] { didSet { save(subs, "subscriptions") } }
    var subParsed: [String: [ICalEvent]] = [:]
    var subTried: [String: Date] = [:]
    var extras: [String: Extra] = [:] { didSet { save(extras, "eventExtras") } }
    // Phase 8: accounts signed in inside Dateline (Accounts.swift).
    @Published var accounts: [Account] = [] { didSet { save(accounts, "accounts") } }
    let accData = AccData()
    var onError: ((String) -> Void)?  // a change that failed on its way to an account

    init(sample: Bool) {
        if sample { loadSample(); return }
        // Only when the saved copy reads back: a copy that fails to read must not be overwritten with an empty one.
        if let v: [CalSet] = load("calendarSets") { sets = v }
        if let v: [String] = load("recentEmoji") { recentEmoji = v }
        if let v: [String: Extra] = load("eventExtras") { extras = v }
        loadSubs()
        loadAccounts()
        requestAccess()
        requestReminders()
    }

    // Dateline's own saved data. Sample mode (every test and picture) keeps it in memory only.
    private func save<T: Encodable>(_ v: T, _ key: String) {
        guard access != .sample, let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func load<T: Decodable>(_ key: String) -> T? {
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

    func decorated(_ it: Item) -> Item {
        guard let x = extras[key(it.id)] else { return it }
        var it = it
        it.emoji = x.emoji; it.color = x.color; it.tags = x.tags
        it.noTravel = x.noTravel ?? false; it.leave = x.leave; it.from = x.from ?? .here
        if x.plain == it.notes { it.rich = x.rich }
        return it
    }

    private func setExtras(_ it: Item) {
        let x = Extra(emoji: it.emoji, color: it.color, tags: it.tags, rich: it.rich, plain: it.rich == nil ? nil : it.notes,
                      noTravel: it.noTravel ? true : nil, leave: it.leave, from: it.from == .here ? nil : it.from)
        if extras[key(it.id)] != (x.isEmpty ? nil : x) { extras[key(it.id)] = x.isEmpty ? nil : x }
    }

    func calendar(_ id: String) -> CalInfo? { calendars.first { $0.id == id } }

    private func requestAccess() {
        ek.requestFullAccessToEvents { ok, _ in
            Task { @MainActor in
                self.access = ok ? .granted : .denied
                guard ok else { return }
                self.reloadCalendars()
                self.refreshSubs()
                // Changes made in Apple Calendar or on another device show up here straight away.
                self.observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.ek, queue: .main) { _ in
                    Task { @MainActor in self.reloadCalendars() }
                }
            }
        }
    }

    private var reopened = false
    func reloadCalendars() {
        calendars = ek.calendars(for: .event).filter { !shownHere($0.source) }
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { CalInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(nsColor: $0.color), writable: $0.allowsContentModifications) }
            + accInfos + subInfos
        if !reopened {
            reopened = true
            if let id = UserDefaults.standard.string(forKey: "lastSet"), let s = sets.first(where: { $0.id == id }), activeSet?.id != id { use(s) }
        }
        defaultCalendarID = ek.defaultCalendarForNewEvents.map { d in shownHere(d.source) ? accInfos.first { $0.title == d.title }?.id : d.calendarIdentifier } ?? nil
        pastCache = nil
        fetch()
    }

    func refetch() { fetch() }

    // Loads the events between two dates (the visible view plus a margin).
    func show(from: Date, to: Date) {
        range = (from, to)
        fetch()
    }

    private func fetch() {
        let (a, b) = range
        let now = sampleToday ?? Date(), later = now.addingTimeInterval(120 * 86400)
        items = between(a, b)
        let subSoon = subEvents(from: now.addingTimeInterval(-86400), to: later).filter { sub($0.calendarID)?.kind == nil }  // not a sunrise line every day
        if access == .sample { soon = sample.filter { $0.end > now && $0.start < later } + subSoon; return }
        let accSoon = accEvents(from: now.addingTimeInterval(-86400), to: later)
        guard access == .granted else { soon = subSoon + accSoon; return }  // subscribed calendars and accounts need no calendar access
        soon = ekFind(now.addingTimeInterval(-86400), later).map { decorated(Self.item($0)) } + subSoon + accSoon
    }

    // Events between two dates, read without changing what the window shows (the map of places).
    func between(_ a: Date, _ b: Date) -> [Item] {
        if access == .sample { return (sample.filter { $0.end > a && $0.start < b } + subEvents(from: a, to: b)).sorted { $0.start < $1.start } }
        guard access == .granted else { return (subEvents(from: a, to: b) + accEvents(from: a, to: b)).sorted { $0.start < $1.start } }
        return (ekFind(a, b).map { decorated(Self.item($0)) } + subEvents(from: a, to: b) + accEvents(from: a, to: b)).sorted { $0.start < $1.start }
    }

    // The Mac's events, without the calendars an account here already shows.
    private func ekFind(_ a: Date, _ b: Date) -> [EKEvent] {
        let all = ek.calendars(for: .event), keep = accounts.isEmpty ? all : all.filter { !shownHere($0.source) }
        if keep.isEmpty { return [] }
        return ek.events(matching: ek.predicateForEvents(withStart: a, end: b, calendars: keep.count == all.count ? nil : keep))
    }

    // The last year's events, one per title, newest first (quick add's "From your past events"). Kept until the calendars change.
    private var pastCache: [Item]?
    func past() -> [Item] {
        if let pastCache { return pastCache }
        let now = sampleToday ?? Date()
        let list = access == .sample ? sample.filter { $0.start < now }
            : (access == .granted ? ekFind(now.addingTimeInterval(-365 * 86400), now).map(Self.item) : []) + accEvents(from: now.addingTimeInterval(-365 * 86400), to: now)
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
                    allDay: e.isAllDay, place: e.location ?? "", notes: e.notes ?? "", showAs: s,
                    geo: e.structuredLocation?.geoLocation.map { Geo(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) },
                    alerts: (e.alarms ?? []).filter { $0.proximity == .none && ($0.type == .display || $0.type == .audio) && !(e.hasRecurrenceRules && $0.absoluteDate != nil) }
                        .map { $0.absoluteDate ?? e.startDate.addingTimeInterval($0.relativeOffset) },
                    link: e.url?.absoluteString ?? "")
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
        if access != .sample, isAcc(calID) {
            return accAdd(Item(id: "", calendarID: calID, title: p.title.isEmpty ? "New event" : p.title, start: p.start, end: p.end, allDay: p.allDay, place: p.place, notes: "", showAs: p.showAs, geo: p.geo),
                          alertMinutes: p.alertMinutes, repeats: p.repeats.map { ($0.unit, $0.n) })
        }
        var it = Item(id: UUID().uuidString, calendarID: calID, title: p.title.isEmpty ? "New event" : p.title, start: p.start, end: p.end,
                      allDay: p.allDay, place: p.place, notes: "", showAs: p.showAs, geo: p.geo)
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
        if isSub(it.calendarID) { return Failure("Events in a subscribed calendar can't be changed.") }
        let before = items.first { $0.id == it.id }
        if isAcc(it.calendarID) || before.map({ isAcc($0.calendarID) }) == true {
            if let f = accUpdate(it, old: before) { fetch(); return f }
            setExtras(it); fetch(); return nil
        }
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
        if isSub(it.calendarID) { return Failure("Events in a subscribed calendar can't be deleted. Remove the whole calendar from the sidebar instead.") }
        if isAcc(it.calendarID) {
            let oneTime = !accRepeats(it)
            if let f = accDelete(it, series: series) { return f }
            if oneTime || series { extras[key(it.id)] = nil }
            fetch(); return nil
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
        var p = Parsed(start: it.start, end: it.end); p.title = it.title; p.allDay = it.allDay; p.place = it.place; p.geo = it.geo; p.showAs = it.showAs
        guard case .success(let added) = add(p, calendarID: isSub(it.calendarID) ? nil : it.calendarID) else { return nil }  // a copy of a subscribed event goes to your own calendar
        var back = added
        back.notes = it.notes; back.link = it.link; back.emoji = it.emoji; back.color = it.color; back.tags = it.tags; back.rich = it.rich
        back.noTravel = it.noTravel; back.leave = it.leave; back.from = it.from
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
        // A place picked from Apple Maps keeps its spot on the map; only rewritten when it changed, so a phone-made place keeps its address.
        let had = e.structuredLocation?.geoLocation.map { Geo(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        if e.location ?? "" != it.place || had != it.geo {
            if let g = it.geo, !it.place.isEmpty {
                let l = EKStructuredLocation(title: it.place)
                l.geoLocation = CLLocation(latitude: g.lat, longitude: g.lon)
                e.structuredLocation = l
            } else { e.structuredLocation = nil; e.location = it.place.isEmpty ? nil : it.place }
        }
        e.notes = it.notes.isEmpty ? nil : it.notes
        // A pasted "Join: https://…" keeps only the call's own address, so Apple Calendar can open it too.
        let link = callLink(in: [it.link])?.url.absoluteString ?? it.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.url?.absoluteString ?? "" != link { e.url = URL(string: link) }
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
                emoji: String = "", color: Int? = nil, tags: [String] = [], geo: Geo? = nil) {
            n += 1
            sample.append(Item(id: "s\(n)", calendarID: c, title: t, start: at(d, h, m), end: at(d, h, m + mins), allDay: false, place: place, notes: notes, showAs: s,
                               emoji: emoji, color: color, tags: tags, geo: geo))
        }
        ev("personal", "Lunch with Sam", -14, 12, 30, 60, place: "Casa Luna")
        ev("work", "Lunch with the team", -27, 12, 0, 60, place: "Office")
        ev("work", "Team standup", 0, 9, 0, 30)
        ev("work", "Write proposal", 0, 10, 0, 120, notes: "Sample notes: outline goals, budget and next steps for the proposal.")
        ev("personal", "Lunch with Sam", 0, 12, 30, 60, .maybe, place: "Café Playa")
        ev("family", "School pickup", 0, 15, 0, 30)
        ev("personal", "Gym", 0, 17, 30, 60, .free)
        ev("work", "Client call", 1, 11, 0, 60, place: "Zoom", notes: "Join: https://us02web.zoom.us/j/8123456789")
        ev("family", "Christian at the condo", 1, 13, 30, 60, place: "Condo", notes: "Fix before he leaves:\n[x] Kitchen tap drips\n[ ] Balcony door lock sticks\n- Gate code is in the group chat",
           emoji: "🏠", color: 3, tags: ["Condo", "Visitors"], geo: Geo(lat: 10.2930, lon: -85.8318))
        ev("family", "Dentist", 2, 8, 30, 60, place: "Clínica Dental Tamarindo", emoji: "🦷", geo: Geo(lat: 10.2995, lon: -85.8371))
        ev("work", "Design review", 3, 14, 0, 90)
        ev("work", "Site visit", 3, 10, 0, 60, place: "Hotel Pasatiempo", geo: Geo(lat: 10.2958, lon: -85.8362))
        ev("personal", "Call with Lee", 4, 16, 0, 60)
        ev("personal", "Dinner with Ana", 4, 19, 0, 120, place: "Casa Luna, Tamarindo", notes: "Table on the terrace", geo: Geo(lat: 10.3046, lon: -85.8405))
        ev("family", "Beach day", 5, 9, 0, 240, .free, place: "Playa Grande", geo: Geo(lat: 10.3329, lon: -85.8586))
        loadSampleTasks(mon)
        subs = [Sub(id: "sub-sample", url: "https://calendar.example-school.cr/grade5/schedule.ics", name: "Grade 5 schedule", color: 3, updated: sampleToday)]
        subParsed["sub-sample"] = parseICS(sampleICS)
        calendars += subInfos
        sample.append(Item(id: "s-ad", calendarID: "school", title: "Holiday: no school", start: addDays(mon, 2), end: addDays(mon, 3), allDay: true, place: "", notes: "", showAs: .free))
        fetch()
    }
}

// Set by --render so the pictures always show the mockup's week.
var sampleToday: Date?

struct Failure: Error { let message: String; init(_ m: String) { message = m } }
