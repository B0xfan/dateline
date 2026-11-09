// The phone side of the watch link: the watch may not save to calendars or reminders, so it sends ticks and spoken events here to save.
import Foundation
import WatchConnectivity
import DatelineCore

@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private weak var app: PhoneState?
    private var ticks: [String: Bool] = [:]  // ticks for tasks not read from Reminders yet (the app was woken in the background)

    func start(_ app: PhoneState) {
        guard !app.sample, WCSession.isSupported() else { return }
        self.app = app
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Returns the error message to show on the watch, or nil when saved.
    private func handle(_ m: [String: Any]) -> String? {
        guard let app else { return "Open Dateline on your iPhone once." }
        if let id = m["tick"] as? String, let done = m["done"] as? Bool {
            ticks[id] = done
            return applyTicks()
        }
        if let text = m["add"] as? String {
            let p = parseSentence(text, now: Date())
            if case .failure(let f) = app.store.add(p, calendarID: app.calendarFor(p)?.id) { return f.message }
        }
        return nil
    }

    @discardableResult private func applyTicks(retry: Bool = true) -> String? {
        guard let store = app?.store else { return nil }
        var problem: String?
        for (id, done) in ticks {
            guard var t = store.todos.first(where: { $0.id == id }) else { continue }
            ticks[id] = nil
            if t.done != done { t.done = done; problem = store.updateTask(t)?.message ?? problem }
        }
        // shortcut: one retry, 2 s after a fresh Reminders read; a tick still unmatched then (task deleted) is dropped.
        if retry, !ticks.isEmpty { store.reloadReminders(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.applyTicks(retry: false) } }
        if !retry { ticks = [:] }
        return problem
    }

    nonisolated func session(_ s: WCSession, didReceiveMessage m: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let m = m as [String: Any]
        Task { @MainActor in replyHandler(handle(m).map { ["error": $0] } ?? [:]) }
    }
    nonisolated func session(_ s: WCSession, didReceiveUserInfo u: [String: Any]) { Task { @MainActor in _ = handle(u) } }
    nonisolated func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ s: WCSession) {}
    nonisolated func sessionDidDeactivate(_ s: WCSession) { s.activate() }  // a new watch was paired
}
