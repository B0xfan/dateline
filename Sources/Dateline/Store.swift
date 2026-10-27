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
}

@MainActor
final class Store: ObservableObject {
    @Published var calendars: [CalInfo] = []
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenCalendars") }
    }
    @Published private(set) var items: [Item] = []
    @Published var access: Access = .unknown
    @Published var defaultCalendarID: String?
    enum Access { case unknown, granted, denied, sample }

    private let ek = EKEventStore()
    private var range: (Date, Date) = (Date(), Date())
    private var sample: [Item] = []
    private var observer: Any?

    init(sample: Bool) {
        if sample { loadSample() } else { requestAccess() }
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
        fetch()
    }

    // Loads the events between two dates (the visible view plus a margin).
    func show(from: Date, to: Date) {
        range = (from, to)
        fetch()
    }

    private func fetch() {
        let (a, b) = range
        if access == .sample {
            items = sample.filter { $0.end > a && $0.start < b }.sorted { $0.start < $1.start }
            return
        }
        guard access == .granted else { return }
        let pred = ek.predicateForEvents(withStart: a, end: b, calendars: nil)
        items = ek.events(matching: pred).map(Self.item).sorted { $0.start < $1.start }
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
        guard let e = ekEvent(it) else { return Failure("That event is gone.") }
        if e.calendar.calendarIdentifier != it.calendarID, let c = ek.calendar(withIdentifier: it.calendarID) { e.calendar = c }
        apply(it, to: e)
        do { try ek.save(e, span: .thisEvent, commit: true) } catch { fetch(); return Failure(error.localizedDescription) }
        fetch()
        return nil
    }

    @discardableResult
    func delete(_ it: Item) -> Failure? {
        if access == .sample {
            guard sample.contains(where: { $0.id == resolve(it.id) }) else { return Failure("That event is gone.") }
            sample.removeAll { $0.id == resolve(it.id) }; fetch(); return nil
        }
        guard let e = ekEvent(it) else { return Failure("That event is gone.") }
        do { try ek.remove(e, span: .thisEvent, commit: true) } catch { return Failure(error.localizedDescription) }
        fetch()
        return nil
    }

    // Undo of a delete: puts the event back as a new copy (the Mac gives it a new identifier).
    func restore(_ it: Item) -> Item? {
        if access == .sample { var back = it; back.id = UUID().uuidString; replaced[it.id] = back.id; sample.append(back); fetch(); return back }
        var p = Parsed(start: it.start, end: it.end); p.title = it.title; p.allDay = it.allDay; p.place = it.place; p.showAs = it.showAs
        guard case .success(var back) = add(p, calendarID: it.calendarID) else { return nil }
        if !it.notes.isEmpty { back.notes = it.notes; update(back) }
        replaced[it.id] = back.id
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
        let mon = startOfWeek(sampleToday ?? Date())
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: addDays(mon, d))! }
        var n = 0
        func ev(_ c: String, _ t: String, _ d: Int, _ h: Int, _ m: Int, _ mins: Int, _ s: ShowAs = .busy, place: String = "", notes: String = "") {
            n += 1
            sample.append(Item(id: "s\(n)", calendarID: c, title: t, start: at(d, h, m), end: at(d, h, m + mins), allDay: false, place: place, notes: notes, showAs: s))
        }
        ev("work", "Team standup", 0, 9, 0, 30)
        ev("work", "Write proposal", 0, 10, 0, 120, notes: "Sample notes: outline goals, budget and next steps for the proposal.")
        ev("personal", "Lunch with Sam", 0, 12, 30, 60, .maybe, place: "Café Playa")
        ev("family", "School pickup", 0, 15, 0, 30)
        ev("personal", "Gym", 0, 17, 30, 60, .free)
        ev("work", "Client call", 1, 11, 0, 60, place: "Zoom")
        ev("family", "Dentist", 2, 8, 30, 60, place: "Clínica Dental")
        ev("work", "Design review", 3, 14, 0, 90)
        ev("personal", "Dinner with Ana", 4, 19, 0, 60, place: "Casa Luna")
        ev("family", "Beach day", 5, 9, 0, 240, .free)
        sample.append(Item(id: "s-ad", calendarID: "school", title: "Holiday: no school", start: addDays(mon, 2), end: addDays(mon, 3), allDay: true, place: "", notes: "", showAs: .free))
        fetch()
    }
}

// Set by --render so the pictures always show the mockup's week.
var sampleToday: Date?

struct Failure: Error { let message: String; init(_ m: String) { message = m } }
