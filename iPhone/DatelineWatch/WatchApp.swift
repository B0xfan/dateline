// The Apple Watch app (approved watch mockups, John 2026-11-09): next up, today, details, the leave-now alert and add by voice.
// It runs the shared DatelineCore engine and reads the watch's own calendars and reminders, so it works with the phone in another room.
// The watch may not save to calendars or reminders, so ticks and new events go to the phone (WatchLink there) to save.
import SwiftUI
import WatchConnectivity
import DatelineCore

@main
struct DatelineWatchApp: App {
    @StateObject private var app: WatchState = MainActor.assumeIsolated {
        #if DEBUG
        if let demo = WatchDemo.make() { return demo }  // debug builds only: sample calendars for the cloud pictures, never a real calendar
        #endif
        return WatchState(store: Store(sample: false), sample: false)
    }
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { WatchRoot().environmentObject(app).environmentObject(app.store) }
            .onChange(of: phase) { if phase == .active { app.wake() } }
    }
}

@MainActor
final class WatchState: ObservableObject {
    let store: Store
    let sample: Bool
    @Published var now: Date
    @Published var drive: [String: Int] = [:]  // minutes of driving before an event with a place
    @Published var ticked: [String: Bool] = [:]  // ticks sent to the phone, shown at once until Reminders has them
    @Published var page = 0  // 0 = Next up, 1 = Today
    @Published var path: [String] = []  // event ids open
    @Published var adding = false
    var addStart = ""  // pictures only: the add screen's spoken sentence
    private let trips = Trips()
    private var clock: Timer?

    init(store: Store, sample: Bool, now: Date = Date()) {
        self.store = store; self.sample = sample; self.now = now
        load()
        guard !sample else { return }
        LeaveAlerts.shared.install()  // the leave alert's Directions button
        Here.shared.start()
        Phone.shared.start()
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.wake() } }
    }

    /// Back on the wrist, and once a minute while open: the countdowns move on and the drive times are checked again.
    func wake() {
        guard !sample else { return }
        now = Date()
        load(); store.reloadReminders()
        Here.shared.refresh()
        let soon = store.between(now, now.addingTimeInterval(86400)).filter { $0.geo != nil && !$0.allDay && !$0.noTravel && $0.start > now }.sorted { $0.start < $1.start }
        Task { _ = await trips.run(soon, all: soon, store: store) { m in if self.drive != m { self.drive = m } } }
    }

    /// The engine reads only the days asked for: yesterday (late tasks' days are not needed) to tomorrow.
    private func load() { store.show(from: addDays(cal.startOfDay(for: now), -1), to: addDays(cal.startOfDay(for: now), 2)) }

    /// Today's timed events not yet over, soonest first; all-day ones are left to the Today list.
    var coming: [Item] { store.shown(on: now).filter { !$0.allDay && $0.end > now }.sorted { $0.start < $1.start } }
    var today: [Item] { store.shown(on: now).sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) } }
    /// Late tasks, then today's, as on the phone; a task ticked here stays until the phone has saved it.
    var tasks: [ToDo] {
        store.todos.filter { [.overdue, .today].contains(taskGroup($0, now: now)) && (!$0.done || ticked[$0.id] == true) }
            .sorted { (isOverdue($0, now: now) ? 0 : 1, $0.due ?? now) < (isOverdue($1, now: now) ? 0 : 1, $1.due ?? now) }
    }
    func isDone(_ t: ToDo) -> Bool { ticked[t.id] ?? t.done }
    func item(_ id: String) -> Item? { store.between(addDays(cal.startOfDay(for: now), -1), addDays(now, 2)).first { $0.id == id } }

    func tick(_ t: ToDo) {
        let done = !isDone(t)
        ticked[t.id] = done
        if !sample { Phone.shared.send(["tick": t.id, "done": done]) }
    }

    /// The spoken sentence goes to the phone, which reads it the same way and saves it in the right calendar.
    func add(_ text: String, reply: @escaping (String?) -> Void) {
        guard !sample else { return reply(nil) }
        Phone.shared.send(["add": text], reply: reply)
    }
}

/// The link to the phone. A message when the phone is near, otherwise a queued transfer that arrives when it is.
final class Phone: NSObject, WCSessionDelegate {
    static let shared = Phone()
    func start() { guard WCSession.isSupported() else { return }; WCSession.default.delegate = self; WCSession.default.activate() }
    /// `reply` gets nil when saved (or queued for later), else the phone's error message.
    func send(_ m: [String: Any], reply: ((String?) -> Void)? = nil) {
        let s = WCSession.default
        let done: (String?) -> Void = { r in DispatchQueue.main.async { reply?(r) } }
        guard s.activationState == .activated, s.isReachable else { s.transferUserInfo(m); return done(nil) }
        s.sendMessage(m, replyHandler: { done($0["error"] as? String) }, errorHandler: { _ in s.transferUserInfo(m); done(nil) })
    }
    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {}
}

/// "Fri, Oct 30" in the engine's time zone (the pictures pin Costa Rica; the runner is on UTC).
func dayText(_ d: Date) -> String {
    var f = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
    f.timeZone = cal.timeZone
    return d.formatted(f)
}

/// "in 2 h 21 min", "in 5 min", "now".
func countdown(to d: Date, from now: Date) -> String {
    let m = Int((d.timeIntervalSince(now) / 60).rounded(.up))
    guard m > 0 else { return "now" }
    return m < 60 ? "in \(m) min" : m % 60 == 0 ? "in \(m / 60) h" : "in \(m / 60) h \(m % 60) min"
}

#if DEBUG
// `--sample -demo <screen>` opens one screen on the sample calendars for the cloud pictures. Never asks for calendars,
// reminders or location and never writes saved settings.
@MainActor
enum WatchDemo {
    static let args = ProcessInfo.processInfo.arguments
    /// The phone pictures' "today": Monday Oct 26, 2026, 9:41 in Costa Rica.
    static var today: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))! }

    static func make() -> WatchState? {
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return nil }
        cal.timeZone = TimeZone(identifier: "America/Costa_Rica")!
        sampleToday = today
        let app = WatchState(store: Store(sample: true), sample: true, now: today)
        for it in app.store.between(addDays(today, -1), addDays(today, 2)) where it.geo != nil { app.drive[it.id] = 25 }  // made-up drive times, never Apple Maps
        switch args[i + 1] {
        case "today": app.page = 1
        case "today-ticked": app.page = 1; if let t = app.tasks.first { app.ticked[t.id] = true }
        case "details": if let it = app.coming.first(where: { $0.geo != nil }) ?? app.coming.first { app.path = [it.id] }
        case "details-call": if let it = app.today.first(where: { callLink($0) != nil }) { app.path = [it.id] }
        case "add": app.page = 1; app.addStart = "Dinner with Ana Friday 7pm at Casa Luna"; app.adding = true
        default: break  // "next"
        }
        return app
    }
}
#endif
