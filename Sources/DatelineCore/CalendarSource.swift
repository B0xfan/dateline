// The one door to the Mac's calendars and reminders. AppleCalendar is the real thing (F1, J3: the accounts already set up on this Mac, nothing leaves it);
// SampleCalendar is made-up data in memory for every test and picture, and never asks for access. Only this file talks to Apple's calendar framework.
// Items going through here carry what the calendar holds; Dateline's own extras (emoji, tags, travel) stay in Store.
import Foundation
import EventKit
import SwiftUI
import CoreLocation
@MainActor

public protocol CalendarSource: AnyObject {
    // A Mac calendar an account signed in here already shows, by its account's name: left out of what's read, so nothing shows twice.
    var shownElsewhere: (_ account: String, _ calDAV: Bool) -> Bool { get set }
    func askForEvents(_ done: @escaping @MainActor (Bool) -> Void)
    func askForReminders(_ done: @escaping @MainActor (Bool) -> Void)
    func onChange(_ act: @escaping @MainActor () -> Void)  // changed in Apple Calendar, Reminders or on another device

    func calendars() -> [CalInfo]
    func allCalendars() -> [CalInfo]  // with the ones shown elsewhere
    func defaultCalendar() -> (id: String, title: String, elsewhere: Bool)?
    func events(from a: Date, to b: Date) -> [Item]
    func eventsInBackground(from a: Date, to b: Date) async -> [Item]
    func eventIDs(from a: Date, to b: Date, calendars: [String]) -> [(id: String, calendarID: String, uid: String)]
    func add(_ it: Item, alertMinutes: Int?, repeats: (unit: Character, n: Int)?) -> Result<Item, Failure>
    func update(_ it: Item, before: Item?) -> Result<String?, Failure>  // the event's identifier now: moving calendars can change it
    func delete(_ it: Item, series: Bool) -> Result<Bool, Failure>  // true when no other occurrence is left
    func repeats(_ it: Item) -> Bool  // part of a repeating event (the phone asks "this one or all future" before deleting)
    func copyAlerts(from old: Item, to new: Item)  // also after `old` was deleted, for undo

    func reminderLists() -> [CalInfo]
    func readReminders(_ done: @escaping @MainActor ([ToDo]) -> Void)
    func addReminder(_ t: ToDo, listID: String?) -> Result<ToDo, Failure>
    func updateReminder(_ t: ToDo, old: ToDo?) -> Failure?
    func deleteReminder(_ t: ToDo) -> Failure?
}

#if os(watchOS)
// The watch may read calendars and reminders but never save them (Apple's rule): its changes go to the phone instead.
private let onPhone = Failure("The watch can't save this; it goes through your iPhone.")
#endif

@MainActor
public final class AppleCalendar: CalendarSource {
    private let ek = EKEventStore()
    // What a deleted reminder had beyond ToDo (repeats, phone-set alerts, priority, link), so Undo puts back the whole task.
    private var removed: [String: (rules: [EKRecurrenceRule]?, alarms: [EKAlarm]?, priority: Int, url: URL?)] = [:]
    private var observer: Any?
    private var deletedAlarms: [String: [EKAlarm]] = [:]
    public var shownElsewhere: (String, Bool) -> Bool = { _, _ in false }
    public init() {}  // the watch face pieces read through one of their own

    public static var hasEventAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    public func askForEvents(_ done: @escaping @MainActor (Bool) -> Void) {
        ek.requestFullAccessToEvents { ok, _ in Task { @MainActor in done(ok) } }
    }
    public func askForReminders(_ done: @escaping @MainActor (Bool) -> Void) {
        ek.requestFullAccessToReminders { ok, _ in Task { @MainActor in done(ok) } }
    }
    public func onChange(_ act: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { _ in Task { @MainActor in act() } }
    }

    // The Mac tells display and sound alerts from email and program ones; the iPhone has only the first two.
    private nonisolated static func isShownAlarm(_ a: EKAlarm) -> Bool {
        #if os(macOS)
        return a.type == .display || a.type == .audio
        #else
        return true
        #endif
    }

    private func info(_ c: EKCalendar) -> CalInfo {
        #if os(macOS)
        let color = Color(nsColor: c.color)
        #else
        let color = Color(cgColor: c.cgColor)
        #endif
        return CalInfo(id: c.calendarIdentifier, title: c.title, account: c.source.title, color: color, writable: c.allowsContentModifications)
    }
    // A Dateline account reads only its own calendars, so the Mac's subscriptions in that account (football feeds) stay shown here.
    private func elsewhere(_ c: EKCalendar) -> Bool { c.type != .subscription && shownElsewhere(c.source.title, c.source.sourceType == .calDAV) }

    public func calendars() -> [CalInfo] {
        ek.calendars(for: .event).filter { !elsewhere($0) }.sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }.map(info)
    }
    public func allCalendars() -> [CalInfo] { ek.calendars(for: .event).map(info) }
    public func defaultCalendar() -> (id: String, title: String, elsewhere: Bool)? {
        ek.defaultCalendarForNewEvents.map { ($0.calendarIdentifier, $0.title, elsewhere($0)) }
    }

    // The calendars to read, nil when that's all of them. Empty: nothing to read.
    private func kept() -> (cals: [EKCalendar]?, none: Bool) {
        let all = ek.calendars(for: .event), keep = all.filter { !elsewhere($0) }
        return (keep.count == all.count ? nil : keep, keep.isEmpty)
    }

    public func events(from a: Date, to b: Date) -> [Item] {
        let k = kept()
        return k.none ? [] : ek.events(matching: ek.predicateForEvents(withStart: a, end: b, calendars: k.cals)).map(Self.item)
    }

    public func eventsInBackground(from a: Date, to b: Date) async -> [Item] {
        let k = kept()
        if k.none { return [] }
        let ids = k.cals.map { Set($0.map(\.calendarIdentifier)) }
        return await Task.detached(priority: .utility) {
            let own = EKEventStore()  // the main thread keeps using the shared one
            let search = own.predicateForEvents(withStart: a, end: b, calendars: ids.map { ids in own.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } })
            return own.events(matching: search).filter { $0.calendar != nil }.map(AppleCalendar.item)  // a calendar deleted during the read leaves none
        }.value
    }

    public func eventIDs(from a: Date, to b: Date, calendars ids: [String]) -> [(id: String, calendarID: String, uid: String)] {
        let cals = ek.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        if cals.isEmpty { return [] }
        return ek.events(matching: ek.predicateForEvents(withStart: a, end: b, calendars: cals)).compactMap { e in
            guard let id = e.eventIdentifier, let uid = e.calendarItemExternalIdentifier else { return nil }
            return (id, e.calendar.calendarIdentifier, uid)
        }
    }

    public nonisolated static func item(_ e: EKEvent) -> Item {
        let s: ShowAs = e.availability == .free ? .free : e.availability == .tentative ? .maybe : .busy
        // A repeating event's occurrences share one identifier; the start date tells them apart. A one-time event keeps its plain identifier so moving it keeps it selected.
        let occ = e.hasRecurrenceRules ? "|" + String(e.occurrenceDate?.timeIntervalSince1970 ?? 0) : ""
        return Item(id: (e.eventIdentifier ?? UUID().uuidString) + occ,
                    calendarID: e.calendar.calendarIdentifier, title: e.title ?? "", start: e.startDate, end: e.endDate,
                    allDay: e.isAllDay, place: e.location ?? "", notes: e.notes ?? "", showAs: s,
                    geo: e.structuredLocation?.geoLocation.map { Geo(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) },
                    alerts: (e.alarms ?? []).filter { $0.proximity == .none && isShownAlarm($0) && !(e.hasRecurrenceRules && $0.absoluteDate != nil) }
                        .map { $0.absoluteDate ?? e.startDate.addingTimeInterval($0.relativeOffset) },
                    link: e.url?.absoluteString ?? "", uid: e.calendarItemExternalIdentifier ?? "")
    }

    private func event(_ it: Item, now: Item? = nil) -> EKEvent? {
        let parts = it.id.split(separator: "|")
        guard let id = parts.first.map(String.init) else { return nil }
        guard parts.count == 2, let t = Double(parts[1]) else { return ek.event(withIdentifier: id) }
        // One occurrence of a repeating event: search between its original date and where it is now (it may have been moved).
        // Never fall back to the series, or a change would land on the wrong occurrence.
        let at = Date(timeIntervalSince1970: t)
        // `now`: where it sits before this change, so an undo that moves it back across days still finds it.
        let lo = [at, it.start, now?.start ?? at].min()!, hi = [at, it.end, now?.end ?? at].max()!
        let pred = ek.predicateForEvents(withStart: lo.addingTimeInterval(-86400), end: hi.addingTimeInterval(86400), calendars: nil)
        return ek.events(matching: pred).first { $0.eventIdentifier == id && $0.occurrenceDate == at }
    }

    public func add(_ it: Item, alertMinutes: Int?, repeats: (unit: Character, n: Int)?) -> Result<Item, Failure> {
        #if os(watchOS)
        return .failure(onPhone)
        #else
        guard let c = ek.calendar(withIdentifier: it.calendarID) else { return .failure(Failure("That calendar is gone.")) }
        let e = EKEvent(eventStore: ek)
        e.calendar = c
        apply(it, to: e)
        if let m = alertMinutes { e.addAlarm(EKAlarm(relativeOffset: -Double(m * 60))) }
        if let r = repeats {
            let f: [Character: EKRecurrenceFrequency] = ["d": .daily, "w": .weekly, "m": .monthly, "y": .yearly]
            e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: f[r.unit]!, interval: r.n, end: nil))
        }
        do { try ek.save(e, span: .thisEvent, commit: true) } catch { return .failure(Failure(error.localizedDescription)) }
        return .success(Self.item(e))
        #endif
    }

    public func update(_ it: Item, before: Item?) -> Result<String?, Failure> {
        #if os(watchOS)
        return .failure(onPhone)
        #else
        guard let e = event(it, now: before) else { return .failure(Failure("That event is gone.")) }
        if e.calendar.calendarIdentifier != it.calendarID, let c = ek.calendar(withIdentifier: it.calendarID) { e.calendar = c }
        apply(it, to: e)
        do { try ek.save(e, span: .thisEvent, commit: true) } catch { return .failure(Failure(error.localizedDescription)) }
        return .success(e.eventIdentifier)
        #endif
    }

    public func repeats(_ it: Item) -> Bool { event(it)?.hasRecurrenceRules == true }
    public func delete(_ it: Item, series: Bool) -> Result<Bool, Failure> {
        #if os(watchOS)
        return .failure(onPhone)
        #else
        guard let e = event(it) else { return .failure(Failure("That event is gone.")) }
        let alarms = e.alarms ?? [], oneTime = !e.hasRecurrenceRules
        do { try ek.remove(e, span: series ? .futureEvents : .thisEvent, commit: true) } catch { return .failure(Failure(error.localizedDescription)) }
        deletedAlarms[it.id] = alarms  // undo puts them back
        return .success(oneTime)
        #endif
    }

    public func copyAlerts(from old: Item, to new: Item) {
        #if os(watchOS)
        return
        #else
        if let alarms = event(old)?.alarms ?? deletedAlarms[old.id], !alarms.isEmpty, let e = ek.event(withIdentifier: new.id) {
            alarms.forEach { a in e.addAlarm(a.absoluteDate.map(EKAlarm.init(absoluteDate:)) ?? EKAlarm(relativeOffset: a.relativeOffset)) }
            try? ek.save(e, span: .thisEvent)
        }
        #endif
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

    // MARK: Reminders (Phase 4)

    public func reminderLists() -> [CalInfo] { ek.calendars(for: .reminder).sorted { $0.title < $1.title }.map(info) }

    // Every unfinished reminder, plus the ones finished in the last week (for "Show done tasks" and ticked ones on the calendar).
    public func readReminders(_ done: @escaping @MainActor ([ToDo]) -> Void) {
        let ek = ek
        let open = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let finished = ek.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-7 * 86400), ending: nil, calendars: nil)
        ek.fetchReminders(matching: open) { a in
            let first = (a ?? []).map(AppleCalendar.todo)
            ek.fetchReminders(matching: finished) { b in
                let all = first + (b ?? []).map(AppleCalendar.todo)
                DispatchQueue.main.async { MainActor.assumeIsolated { done(all) } }
            }
        }
    }

    public nonisolated static func todo(_ r: EKReminder) -> ToDo {
        let c = r.dueDateComponents
        var t = ToDo(id: r.calendarItemIdentifier, listID: r.calendar.calendarIdentifier, title: r.title ?? "",
                     due: c.flatMap { cal.date(from: $0) }, timed: c?.hour != nil, done: r.isCompleted, notes: r.notes ?? "")
        if let a = r.alarms?.first(where: { $0.proximity != .none }), let l = a.structuredLocation, let g = l.geoLocation {
            t.remind = a.proximity == .enter ? .arriving : .leaving
            t.place = Spot(name: l.title ?? "", lat: g.coordinate.latitude, lon: g.coordinate.longitude, radius: l.radius == 0 ? 150 : l.radius)
        }
        return t
    }

    public func addReminder(_ t: ToDo, listID: String?) -> Result<ToDo, Failure> {
        #if os(watchOS)
        return .failure(onPhone)
        #else
        guard let c = listID.flatMap(ek.calendar(withIdentifier:)) ?? ek.defaultCalendarForNewReminders() else { return .failure(Failure("No Reminders list on this Mac can take new tasks.")) }
        let r = EKReminder(eventStore: ek)
        r.calendar = c
        apply(t, old: nil, to: r)
        if let k = removed.removeValue(forKey: t.id) {  // Undo of a delete
            r.recurrenceRules = k.rules; r.alarms = k.alarms; r.priority = k.priority; r.url = k.url
        }
        do { try ek.save(r, commit: true) } catch { return .failure(Failure(error.localizedDescription)) }
        return .success(Self.todo(r))
        #endif
    }

    public func updateReminder(_ t: ToDo, old: ToDo?) -> Failure? {
        #if os(watchOS)
        return onPhone
        #else
        guard let r = ek.calendarItem(withIdentifier: t.id) as? EKReminder else { return Failure("That task is gone.") }
        if r.calendar.calendarIdentifier != t.listID, let c = ek.calendar(withIdentifier: t.listID) { r.calendar = c }
        apply(t, old: old, to: r)
        do { try ek.save(r, commit: true) } catch { return Failure(error.localizedDescription) }
        return nil
        #endif
    }

    public func deleteReminder(_ t: ToDo) -> Failure? {
        #if os(watchOS)
        return onPhone
        #else
        guard let r = ek.calendarItem(withIdentifier: t.id) as? EKReminder else { return Failure("That task is gone.") }
        let keep = (r.recurrenceRules?.map { $0.copy() as! EKRecurrenceRule }, r.alarms?.map { $0.copy() as! EKAlarm }, r.priority, r.url)
        do { try ek.remove(r, commit: true) } catch { return Failure(error.localizedDescription) }
        removed[t.id] = keep
        return nil
        #endif
    }

    private func apply(_ t: ToDo, old: ToDo?, to r: EKReminder) {
        r.title = t.title
        r.notes = t.notes.isEmpty ? nil : t.notes
        if r.isCompleted != t.done { r.isCompleted = t.done }
        r.dueDateComponents = t.due.map { cal.dateComponents(t.timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: $0) }
        // Alerts are rewritten only when what they hang on changed, so alerts set on the phone (e.g. "1 day before") are kept otherwise.
        guard old.map({ ($0.due, $0.timed, $0.remind, $0.place) != (t.due, t.timed, t.remind, t.place) }) ?? true,
              t.remind == .time || t.place != nil else { return }  // Arriving/Leaving with no place yet: wait for the place
        (r.alarms ?? []).filter { ($0.proximity != .none && $0.structuredLocation?.geoLocation != nil) || $0.absoluteDate != nil }.forEach(r.removeAlarm)
        if t.remind == .time, t.timed, let d = t.due { r.addAlarm(EKAlarm(absoluteDate: d)) }
        if t.remind != .time, let p = t.place {
            let l = EKStructuredLocation(title: p.name)
            l.geoLocation = CLLocation(latitude: p.lat, longitude: p.lon)
            l.radius = p.radius
            let a = EKAlarm()
            a.structuredLocation = l
            a.proximity = t.remind == .arriving ? .enter : .leave
            r.addAlarm(a)
        }
    }
}

// Made-up calendars, events and tasks around the mockup's week, relative to today.
@MainActor
public final class SampleCalendar: CalendarSource {
    public var shownElsewhere: (String, Bool) -> Bool = { _, _ in false }
    public var events: [Item] = []
    public var tasks: [ToDo] = []
    public let firstExtras: [String: Extra]  // what Dateline keeps on these events; Store starts with it
    public let mon: Date
    private var changed: (@MainActor () -> Void)?
    public func fireChange() { changed?() }  // what another device's change does, for the self-check

    private let cals = [
        CalInfo(id: "work", title: "Work", account: "Google (sample)", color: Palette.work, writable: true),
        CalInfo(id: "personal", title: "Personal", account: "iCloud (sample)", color: Palette.personal, writable: true),
        CalInfo(id: "family", title: "Family", account: "iCloud (sample)", color: Palette.family, writable: true),
        CalInfo(id: "school", title: "School (sample)", account: "Subscribed (sample)", color: Color(red: 0.55, green: 0.42, blue: 0.85), writable: false),
    ]
    private let lists = [CalInfo(id: "r-main", title: "Reminders", account: "iCloud (sample)", color: Palette.work, writable: true),
                         CalInfo(id: "r-condo", title: "Condo", account: "iCloud (sample)", color: Palette.family, writable: true),
                         CalInfo(id: "r-groc", title: "Groceries", account: "iCloud (sample)", color: Palette.personal, writable: true)]

    // `prefix`: the start of each made-up event's id, so a check can stand in for a second device whose ids differ (as the iPhone's do); the uids stay the same.
    public init(prefix: String = "s") {
        let today = cal.startOfDay(for: sampleToday ?? Date())
        mon = addDays(today, -((cal.component(.weekday, from: today) + 5) % 7))  // always Monday, whatever week start is saved, so samples match the mockups
        let mon = mon
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: addDays(mon, d))! }
        var made: [Item] = []
        func ev(_ c: String, _ t: String, _ d: Int, _ h: Int, _ m: Int, _ mins: Int, _ s: ShowAs = .busy, place: String = "", notes: String = "",
                emoji: String = "", color: Int? = nil, tags: [String] = [], geo: Geo? = nil) {
            made.append(Item(id: "\(prefix)\(made.count + 1)", calendarID: c, title: t, start: at(d, h, m), end: at(d, h, m + mins), allDay: false, place: place, notes: notes, showAs: s,
                             emoji: emoji, color: color, tags: tags, geo: geo, uid: "sample-\(made.count + 1)"))
        }
        ev("personal", "Lunch with Sam", -14, 12, 30, 60, place: "Casa Luna")
        ev("work", "Lunch with the team", -27, 12, 0, 60, place: "Office")
        ev("work", "Team standup", 0, 9, 0, 30)
        ev("work", "Write proposal", 0, 10, 0, 120, notes: "Sample notes: outline goals, budget and next steps for the proposal.")
        ev("personal", "Lunch with Sam", 0, 12, 30, 60, .maybe, place: "Café Playa")
        ev("family", "School pickup", 0, 15, 0, 30)
        ev("personal", "Gym", 0, 17, 30, 60, .free)
        ev("work", "Client call", 1, 11, 0, 60, place: "Zoom", notes: "Join: https://us02web.zoom.us/j/8123456789")
        ev("family", "Marco at the condo", 1, 13, 30, 60, place: "Condo", notes: "Fix before he leaves:\n[x] Kitchen tap drips\n[ ] Balcony door lock sticks\n- Gate code is in the group chat",
           emoji: "🏠", color: 3, tags: ["Condo", "Visitors"], geo: Geo(lat: 10.2930, lon: -85.8318))
        ev("family", "Dentist", 2, 8, 30, 60, place: "Clínica Dental Tamarindo", emoji: "🦷", geo: Geo(lat: 10.2995, lon: -85.8371))
        ev("work", "Design review", 3, 14, 0, 90)
        ev("work", "Site visit", 3, 10, 0, 60, place: "Hotel Pasatiempo", geo: Geo(lat: 10.2958, lon: -85.8362))
        ev("personal", "Call with Lee", 4, 16, 0, 60)
        ev("personal", "Dinner with Ana", 4, 19, 0, 120, place: "Casa Luna, Tamarindo", notes: "Table on the terrace", geo: Geo(lat: 10.3046, lon: -85.8405))
        ev("family", "Beach day", 5, 9, 0, 240, .free, place: "Playa Grande", geo: Geo(lat: 10.3329, lon: -85.8586))
        made.append(Item(id: prefix + "-ad", calendarID: "school", title: "Holiday: no school", start: addDays(mon, 2), end: addDays(mon, 3), allDay: true, place: "", notes: "", showAs: .free, uid: "sample-ad"))
        firstExtras = Dictionary(uniqueKeysWithValues: made.compactMap { it in
            let x = Extra(emoji: it.emoji, color: it.color, tags: it.tags)
            return x.isEmpty ? nil : (it.id, x)
        })
        events = made.map(calendarPart)

        func on(_ d: Int, _ h: Int? = nil) -> Date { h.map { cal.date(byAdding: .hour, value: $0, to: addDays(mon, d))! } ?? addDays(mon, d) }
        var todos: [ToDo] = []
        func t(_ list: String, _ title: String, _ due: Date?, timed: Bool = false, done: Bool = false, remind: Remind = .time, place: Spot? = nil, notes: String = "") {
            todos.append(ToDo(id: "t\(todos.count + 1)", listID: list, title: title, due: due, timed: timed, done: done, notes: notes, remind: remind, place: place))
        }
        t("r-condo", "Pay condo fee", on(-3))
        t("r-main", "Renew car marchamo", on(-4))
        t("r-main", "Call the plumber", on(0))
        t("r-main", "Take out recycling", on(0, 11), timed: true)
        t("r-main", "Send invoice", on(0), done: true)
        t("r-condo", "Buy AC filter", on(1), remind: .arriving, place: Spot(name: "Ferretería Brenes, Tamarindo", lat: 10.299, lon: -85.839), notes: "Size 16 x 25 x 1, two of them")
        t("r-main", "Electrician", on(1, 10), timed: true)
        t("r-main", "Book dentist follow-up", on(2))
        t("r-condo", "Water plants at the condo", on(4))
        for g in ["Eggs", "Coffee", "Rice", "Limes"] { t("r-groc", g, nil) }
        tasks = todos
    }

    public func askForEvents(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }
    public func askForReminders(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }
    public func onChange(_ act: @escaping @MainActor () -> Void) { changed = act }

    public func calendars() -> [CalInfo] { cals }
    public func allCalendars() -> [CalInfo] { cals }
    public func defaultCalendar() -> (id: String, title: String, elsewhere: Bool)? { ("personal", "Personal", false) }
    public func events(from a: Date, to b: Date) -> [Item] { events.filter { $0.end > a && $0.start < b } }
    public func eventsInBackground(from a: Date, to b: Date) async -> [Item] { events(from: a, to: b) }
    public func eventIDs(from a: Date, to b: Date, calendars: [String]) -> [(id: String, calendarID: String, uid: String)] { [] }

    public func add(_ it: Item, alertMinutes: Int?, repeats: (unit: Character, n: Int)?) -> Result<Item, Failure> {
        guard cals.contains(where: { $0.id == it.calendarID }) else { return .failure(Failure("That calendar is gone.")) }
        var it = it
        it.id = UUID().uuidString; it.uid = it.id
        events.append(it)
        return .success(it)
    }
    public func update(_ it: Item, before: Item?) -> Result<String?, Failure> {
        guard let i = events.firstIndex(where: { $0.id == it.id }) else { return .failure(Failure("That event is gone.")) }
        events[i] = calendarPart(it)
        return .success(it.id)
    }
    public func repeats(_ it: Item) -> Bool { false }
    public func delete(_ it: Item, series: Bool) -> Result<Bool, Failure> {
        guard events.contains(where: { $0.id == it.id }) else { return .failure(Failure("That event is gone.")) }
        events.removeAll { $0.id == it.id }
        return .success(true)
    }
    public func copyAlerts(from old: Item, to new: Item) {
        if let i = events.firstIndex(where: { $0.id == new.id }) { events[i].alerts = old.alerts }
    }

    public func reminderLists() -> [CalInfo] { lists }
    public func readReminders(_ done: @escaping @MainActor ([ToDo]) -> Void) { done(tasks) }
    public func addReminder(_ t: ToDo, listID: String?) -> Result<ToDo, Failure> {
        var t = t
        t.id = UUID().uuidString; t.listID = listID ?? lists[0].id
        tasks.append(t)
        return .success(t)
    }
    public func updateReminder(_ t: ToDo, old: ToDo?) -> Failure? {
        guard let i = tasks.firstIndex(where: { $0.id == t.id }) else { return Failure("That task is gone.") }
        tasks[i] = t
        return nil
    }
    public func deleteReminder(_ t: ToDo) -> Failure? {
        tasks.removeAll { $0.id == t.id }
        return nil
    }
}

