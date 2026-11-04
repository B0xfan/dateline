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

/// What the screens share: which tab and view are showing, the day in view, and the open sheets.
@MainActor
final class PhoneState: ObservableObject {
    enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", year = "Year" }
    enum Tab: String, CaseIterable {
        case calendar = "Calendar", tasks = "Tasks", places = "Places", settings = "Settings"
        var icon: String { ["calendar", "checklist", "mappin.and.ellipse", "gearshape"][Self.allCases.firstIndex(of: self)!] }
    }

    let store: Store
    let sample: Bool  // sample calendars: tests and pictures
    @Published var today: Date
    @Published var mode: Mode = .week { didSet { reload() } }
    @Published var anchor: Date { didSet { reload() } }
    @Published var tab: Tab = .calendar
    @Published var path: [String] = []  // event ids open on the calendar tab
    @Published var adding: String?  // the add sheet's starting text; nil = closed
    @Published var email: EmailFind?
    @Published var showUnlock = false
    @Published var problem: String?
    @Published var drive: [String: Int] = [:]  // minutes of driving before an event with a place
    @Published var emails: [EmailFind] = []  // events found in emails shared to Dateline
    var opened: [String: Item] = [:]  // events opened from outside the days in view (the map)
    var demoWidgets = false

    init(store: Store, today: Date, sample: Bool) {
        self.store = store; self.today = today; self.sample = sample
        anchor = cal.startOfDay(for: today)
        reload()
    }

    /// The days the day and week views show: one, or three from the anchor (the phone's week).
    var days: [Date] { (0..<(mode == .day ? 1 : 3)).map { addDays(anchor, $0) } }

    private var range: (Date, Date) {
        switch mode {
        case .day, .week: return (anchor, addDays(anchor, days.count))
        case .month: let g = monthGrid(anchor); return (g.first!, addDays(g.last!, 1))
        case .year: let y = cal.dateInterval(of: .year, for: anchor)!; return (y.start, y.end)
        }
    }

    func reload() { let r = range; store.show(from: addDays(r.0, -7), to: addDays(r.1, 7)) }

    func step(_ n: Int) {
        switch mode {
        case .day: anchor = addDays(anchor, n)
        case .week: anchor = addDays(anchor, 3 * n)
        case .month: anchor = cal.date(byAdding: .month, value: n, to: anchor)!
        case .year: anchor = cal.date(byAdding: .year, value: n, to: anchor)!
        }
    }

    func goToday() { anchor = cal.startOfDay(for: today) }

    func open(_ it: Item) { opened[it.id] = it; path.append(it.id) }
    func item(_ id: String) -> Item? { store.items.first { $0.id == id } ?? opened[id] }

    /// Where a new event goes: a typed /code, else the shown set's calendar, else the phone's default (as on the Mac).
    func calendarFor(_ p: Parsed) -> CalInfo? {
        let writable = store.calendars.filter(\.writable)
        if let code = p.calendarCode, let c = matchCalendar(code, in: writable, hidden: store.hidden) { return c }
        if let s = store.activeSet, let c = writable.first(where: { $0.id == s.defaultCalendar }) { return c }
        return writable.first { $0.id == store.defaultCalendarID } ?? writable.first
    }

    @discardableResult
    func add(_ p: Parsed, emoji: String = "") -> Result<Item, Failure> {
        var r = store.add(p, calendarID: calendarFor(p)?.id)
        if case .success(var it) = r, !emoji.isEmpty {
            it.emoji = emoji
            if store.update(it) == nil { r = .success(it) }
        }
        if case .failure = r, store.trialOver { showUnlock = true }
        return r
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
    func addTask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let p = parseSentence(text, now: today)
        let title = !p.dateGiven || p.title.isEmpty ? text : p.place.isEmpty ? p.title : "\(p.title) at \(p.place)"
        var t = ToDo(id: "", listID: "", title: title)
        if p.dateGiven { t.due = p.allDay ? cal.startOfDay(for: p.start) : p.start; t.timed = !p.allDay }
        if case .failure(let f) = store.addTask(t, listID: nil) { problem = f.message }
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
