// The Apple Watch app (approved watch mockups, John 2026-11-09): next up, today, details, the leave-now alert and add by voice.
// It runs the shared DatelineCore engine and reads the watch's own calendars and reminders, so it works with the phone in another room.
// The watch may not save to calendars or reminders, so ticks and new events go to the phone (WatchLink there) to save.
import SwiftUI
import Combine
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
    @Published var ticked: [String: Bool] = [:]  // ticks sent to the phone, shown at once until Reminders agrees
    private var keep: Set<String> = []  // tasks ticked here today stay in the list, struck through, after Reminders has them
    @Published var page = 0  // 0 = Next up, 1 = Today
    @Published var path: [String] = []  // event ids open
    @Published var adding = false
    var addStart = ""  // pictures only: the add screen's spoken sentence
    private let trips = Trips()
    private var clock: Timer?
    private var lastWake = Date.distantPast
    private var watching: AnyCancellable?

    init(store: Store, sample: Bool, now: Date = Date()) {
        self.store = store; self.sample = sample; self.now = now
        load()
        guard !sample else { return }
        LeaveAlerts.shared.install()  // the leave alert's Directions button
        Here.shared.start()
        Phone.shared.start()
        // Reminders read back: a tick it now agrees with is no longer the watch's to show (a later change on the phone or Mac wins).
        watching = store.$todos.sink { [weak self] list in
            guard let self, !self.ticked.isEmpty else { return }
            let agree = Set(list.filter { self.ticked[$0.id] == $0.done }.map(\.id))
            if !agree.isEmpty { self.ticked = self.ticked.filter { !agree.contains($0.key) } }
        }
        // The countdowns move on each minute; the calendars follow their own change notice, the rest is read again every 5 minutes.
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.now = Date(); if self.now.timeIntervalSince(self.lastWake) >= 300 { self.wake() } }
        }
    }

    /// Back on the wrist, and every 5 minutes while open: reminders, location and drive times are read again.
    /// The watch plans its own leave alerts; the phone does not plan any yet (PhoneState.drive), so there is one alert per event.
    func wake() {
        guard !sample else { return }
        now = Date(); lastWake = now
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
        store.todos.filter { [.overdue, .today].contains(taskGroup($0, now: now)) && (!$0.done || ticked[$0.id] != nil || keep.contains($0.id)) }
            .sorted { (isOverdue($0, now: now) ? 0 : 1, $0.due ?? now) < (isOverdue($1, now: now) ? 0 : 1, $1.due ?? now) }
    }
    func isDone(_ t: ToDo) -> Bool { ticked[t.id] ?? t.done }
    func item(_ id: String) -> Item? { store.items.first { $0.id == id } }  // the days load() read

    func tick(_ t: ToDo) {
        let done = !isDone(t)
        ticked[t.id] = done; keep.insert(t.id)
        guard !sample else { return }
        Phone.shared.send(["tick": t.id, "done": done], queue: true) { err in if err != nil { self.ticked[t.id] = nil } }  // not saved: back as it was
    }

    /// The spoken sentence goes to the phone, which reads it the same way and saves it in the right calendar.
    func add(_ text: String, reply: @escaping (String?) -> Void) {
        guard !sample else { return reply(nil) }
        Phone.shared.send(["add": text], queue: false, reply: reply)
    }
}

/// The link to the phone. A message when the phone is near, otherwise a queued transfer that arrives when it is.
final class Phone: NSObject, WCSessionDelegate {
    static let shared = Phone()
    private var waiting: [[String: Any]] = []  // queued before the link was up; sent once it is (main thread only)
    func start() { guard WCSession.isSupported() else { return }; WCSession.default.delegate = self; WCSession.default.activate() }
    /// `reply` gets nil when saved (or queued for later), else an error message. Only `queue` messages wait for a phone out of reach:
    /// a failed send may still have arrived, which is harmless for a tick but would add an event twice.
    func send(_ m: [String: Any], queue: Bool, reply: ((String?) -> Void)? = nil) {
        let s = WCSession.default, away = "Couldn't reach your iPhone. Try again near it."
        let done: (String?) -> Void = { r in DispatchQueue.main.async { reply?(r) } }
        guard s.activationState == .activated, s.isReachable else {
            if queue { if s.activationState == .activated { s.transferUserInfo(m) } else { waiting.append(m) } }
            return done(queue ? nil : away)
        }
        s.sendMessage(m, replyHandler: { done($0["error"] as? String) }, errorHandler: { _ in if queue { s.transferUserInfo(m) }; done(queue ? nil : away) })
    }
    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {
        guard st == .activated else { return }
        DispatchQueue.main.async { self.waiting.forEach { s.transferUserInfo($0) }; self.waiting = [] }
    }
}

/// "Fri, Oct 30" in the engine's time zone (the pictures pin Costa Rica; the runner is on UTC).
func dayText(_ d: Date, month: Bool = true) -> String {
    var f = month ? Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day() : Date.FormatStyle.dateTime.weekday(.abbreviated).day()
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
        // the first sample event today or tomorrow with a place on the map, and with a video call
        case "details": if let it = soon(app).first(where: { $0.geo != nil }) { app.path = [it.id] }
        case "details-call": if let it = soon(app).first(where: { callLink($0) != nil }) { app.path = [it.id] }
        case "add": app.page = 1; app.addStart = "Dinner with Ana Friday 7pm at Casa Luna"; app.adding = true
        default: break  // "next"
        }
        return app
    }
    static func soon(_ app: WatchState) -> [Item] { app.store.between(today, addDays(cal.startOfDay(for: today), 2)).sorted { $0.start < $1.start } }
}
#endif
