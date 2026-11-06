// The iPhone app (approved phone mockups, John 2026-11-04). Every non-screen part comes from DatelineCore, shared with the Mac.
import SwiftUI
import DatelineCore

@main
struct DatelineApp: App {
    @StateObject private var app: PhoneState

    init() {
        let made: PhoneState = MainActor.assumeIsolated {
            #if DEBUG
            if let demo = Demo.make() { return demo }  // debug builds only: sample calendars for the checks and pictures, never a real calendar
            #endif
            return PhoneState(store: Store(sample: false), today: Date(), sample: false)
        }
        _app = StateObject(wrappedValue: made)
    }

    var body: some Scene {
        WindowGroup { RootView().environmentObject(app).environmentObject(app.store) }
    }
}

struct Toast: Identifiable { let id = UUID(); var text: String }

/// What the screens share: which tab and view are showing, the day in view, and the open sheets.
@MainActor
final class PhoneState: ObservableObject {
    enum Mode: String, CaseIterable { case list = "List", day = "Day", week = "Week", month = "Month", year = "Year" }
    enum Tab: String, CaseIterable {
        case calendar = "Calendar", tasks = "Tasks", places = "Places", settings = "Settings"
    }

    let store: Store
    let sample: Bool  // sample calendars: tests and pictures
    @Published var today: Date
    @Published var mode: Mode = .list { didSet { reload() } }  // the list is the main screen (approved mockup, John 2026-11-05)
    @Published var anchor: Date { didSet { reload() } }
    @Published var tab: Tab = .calendar
    @Published var path: [String] = []  // event ids open on the calendar tab
    @Published var adding: String?  // the add sheet's starting text; nil = closed
    @Published var email: EmailFind?
    @Published var searching = false
    var searchStart = ""  // pictures only: the search box's starting text
    @Published var showUnlock = false
    @Published var settingsPath: [String] = []  // the settings pages open, e.g. ["accounts", "iCloud"]
    @Published var look = 0  // bumped when a Look choice changes here or arrives from the Mac, so the screens redraw in it
    var unlockNext = false  // an add refused by the ended trial: the unlock screen opens once the add sheet has closed
    @Published var problem: String?
    // shortcut: only the sample fills this; the phone does not run the shared drive planner (Trips) yet, which also schedules the leave alerts (a later step).
    @Published var drive: [String: Int] = [:]  // minutes of driving before an event with a place
    @Published var emails: [EmailFind] = []  // events found in emails shared to Dateline
    var opened: [String: Item] = [:]  // events opened from outside the days in view (the map)
    var demoWidgets = false
    var demoEdit = false  // pictures only: open the event's edit sheet
    var demoDrag: DragLive?  // pictures only: an event held mid-drag
    var demoHold = false  // pictures only: the Undo banner stays up
    @Published var addStart: Date?  // a tap on an empty time: the add sheet starts there
    @Published var toast: Toast?  // the Undo banner
    @Published var dragUntil = Date.distantPast  // the day-to-day swipe stays quiet while an event is held and for a moment after
    let undo = UndoStack()
    var demoTask: String?  // pictures only: which task sheet the Tasks tab opens (edit, edit-place, new, lists)

    init(store: Store, today: Date, sample: Bool) {
        self.store = store; self.today = today; self.sample = sample
        anchor = cal.startOfDay(for: today)
        reload()
    }

    /// The days the day and week views show: one, or three from the anchor (the phone's week).
    var days: [Date] { (0..<(mode == .day ? 1 : 3)).map { addDays(anchor, $0) } }

    private var range: (Date, Date) {
        switch mode {
        case .list: return (startOfWeek(anchor), addDays(anchor, AgendaView.span))  // the week strip and the list's days
        case .day, .week: return (anchor, addDays(anchor, days.count))
        case .month: let g = monthGrid(anchor); return (g.first!, addDays(g.last!, 1))
        case .year: let y = cal.dateInterval(of: .year, for: anchor)!; return (y.start, y.end)
        }
    }

    func lookChanged() { look += 1 }

    func reload() { let r = range; store.show(from: addDays(r.0, -7), to: addDays(r.1, 7)) }

    func step(_ n: Int) {
        switch mode {
        case .list: anchor = addDays(anchor, 7 * n)
        case .day: anchor = addDays(anchor, n)
        case .week: anchor = addDays(anchor, 3 * n)
        case .month: anchor = cal.date(byAdding: .month, value: n, to: anchor)!
        case .year: anchor = cal.date(byAdding: .year, value: n, to: anchor)!
        }
    }

    func goToday() { anchor = cal.startOfDay(for: today) }

    func open(_ it: Item) { opened[it.id] = it; path.append(it.id) }
    func item(_ id: String) -> Item? { store.items.first { $0.id == id } ?? opened[id] }

    /// After a sheet closes: the unlock screen, when the ended trial refused what the sheet tried.
    func sheetClosed() { addStart = nil; if unlockNext { unlockNext = false; showUnlock = true } }

    /// Where a new event goes: a typed /code, else the shown set's calendar, else the phone's default (as on the Mac).
    func calendarFor(_ p: Parsed, pick: String? = nil) -> CalInfo? {
        let writable = store.calendars.filter(\.writable)
        if let code = p.calendarCode, let c = matchCalendar(code, in: writable, hidden: store.hidden) { return c }  // a typed /code beats the menu
        if let pick, let c = writable.first(where: { $0.id == pick }) { return c }
        if let s = store.activeSet, let c = writable.first(where: { $0.id == s.defaultCalendar }) { return c }
        return writable.first { $0.id == store.defaultCalendarID } ?? writable.first
    }

    @discardableResult
    func add(_ p: Parsed, emoji: String = "", pick: String? = nil) -> Result<Item, Failure> {
        var r = store.add(p, calendarID: calendarFor(p, pick: pick)?.id)
        if case .success(var it) = r, !emoji.isEmpty {
            it.emoji = emoji
            if store.update(it) == nil { r = .success(it) }
        }
        if case .success(let it) = r {
            undo.push { [weak self] in self?.store.delete(it, series: true) }  // like the Mac: a repeating one goes whole
            say("Added \(it.shownTitle)")
        }
        return r
    }

    /// A saved change to an event (drag, stretch, edit): Undo puts `old` back.
    @discardableResult
    func change(_ new: Item, from old: Item, _ what: String) -> Failure? {
        if let f = store.update(new) { return f }
        undo.push { [weak self] in self?.store.update(old) }
        say("\(what) \(old.shownTitle)")
        return nil
    }

    /// Deletes one event; Undo puts it back as a copy. (A whole series has no undo, as on the Mac.)
    @discardableResult
    func delete(_ it: Item, series: Bool) -> Failure? {
        if let f = store.delete(it, series: series) { return f }
        guard !series else { return nil }
        undo.push { [weak self] in self?.store.restore(it) == nil ? Failure("Couldn't put the event back.") : nil }
        say("Deleted \(it.shownTitle)")
        return nil
    }

    func say(_ text: String) {
        let t = Toast(text: text)
        toast = t
        UIAccessibility.post(notification: .announcement, argument: text)
        guard !demoHold else { return }
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if toast?.id == t.id { toast = nil } }
    }

    /// The Undo button and shake to undo.
    func undoLast() {
        toast = nil
        if let f = undo.undo() { problem = f.message }
    }

    func toggle(_ t: ToDo) { var n = t; n.done.toggle(); save(n) }

    /// Left swipe on a task: the same time, `days` after today.
    func moveTask(_ t: ToDo, days: Int) {
        var n = t
        let day = addDays(cal.startOfDay(for: today), days)
        n.due = t.due.map { t.timed ? sameClock($0, on: day) : day } ?? day
        save(n)
    }

    private func save(_ t: ToDo) { if let f = store.updateTask(t) { problem = f.message } }

    /// The Mac's quick-add rules for a task: a day or time in the sentence becomes its due date.
    func addTask(_ text: String, listID: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let p = parseSentence(text, now: today)
        let title = !p.dateGiven || p.title.isEmpty ? text : p.place.isEmpty ? p.title : "\(p.title) at \(p.place)"
        var t = ToDo(id: "", listID: "", title: title)
        if p.dateGiven { t.due = p.allDay ? cal.startOfDay(for: p.start) : p.start; t.timed = !p.allDay }
        if case .failure(let f) = store.addTask(t, listID: listID) { problem = f.message }
    }

    // Weather and sun for a day header, where Settings says (the town, else where the phone is).
    func wx(_ d: Date) -> WxDay? { WeatherPrefs.on ? headerSpot().flatMap { WeatherStore.shared.forecast($0)?.days[wxDayKey(d)] } : nil }
    func sun(_ d: Date) -> (rise: Date, set: Date)? { WorkWeek.sun ? headerSpot().flatMap { sunTimes(d, at: $0) } : nil }
}

/// An event read out of an email shared to Dateline (the share step itself comes later; the sample shows one).
struct EmailFind: Identifiable {
    let id = UUID()
    var from: String, quote: String
    var parsed: Parsed, emoji = "", alert = ""
}
