// Keeps the desktop widgets (Widgets/) up to date: writes their copy when the calendars, tasks, sets or drive times change,
// and saves the ticks made in the Tasks widget through the same code as a click on a task's circle.
import Foundation
import Combine
import WidgetKit
import DatelineCore

@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()
    private weak var app: AppState?
    private var watch: AnyCancellable?, timer: Timer?

    func attach(_ app: AppState) {
        self.app = app
        Delegate.openLinks = { [weak app] in app?.open(link: $0) }  // set here, not when the window opens: Dateline runs with it closed
        let s = app.store
        // A sync sends bursts of changes: one write two seconds after the last.
        watch = Publishers.MergeMany(s.$soon.map { _ in () }.eraseToAnyPublisher(), s.$todos.map { _ in () }.eraseToAnyPublisher(),
                                     s.$sets.map { _ in () }.eraseToAnyPublisher(), app.$drive.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.takeTicks(); self?.write() }
        // The weather and a new day change nothing above; an unchanged copy is not written (WidgetShare.write).
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in MainActor.assumeIsolated { WidgetFeed.shared.write() } }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { WidgetFeed.shared.takeTicks() } }
        }, WidgetShare.tickNote as CFString, nil, .deliverImmediately)
    }

    func write() {
        guard let app else { return }
        let s = app.store
        let snap = s.widgetSnap(drive: app.drive) { d in
            WeatherPrefs.on ? headerSpot().flatMap { WeatherStore.shared.forecast($0)?.days[wxDayKey(d)] } : nil
        }
        if WidgetShare.write(snap) { WidgetCenter.shared.reloadAllTimelines() }
    }

    // A save that fails shows its error in the window, and the task comes back in the widget with the next write.
    func takeTicks() {
        guard let app else { return }
        WidgetShare.takeTick(todos: app.store.todos, loaded: app.store.taskAccess != .unknown, save: app.toggle)
    }
}

extension AppState {
    /// A widget's link: dateline://day/2026-11-27, dateline://event/<id>?day=2026-11-27, dateline://add.
    func open(link: URL) {
        let day = WidgetShare.day(of: link)
        openMain?()
        switch link.host {
        case "add": DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.addBox.focusAsks += 1 }  // as New Event (Menus.swift): a reopened window needs a moment
        case "event": if let day { anchor = day }; selectedID = URLComponents(url: link, resolvingAgainstBaseURL: false).flatMap { String($0.percentEncodedPath.dropFirst()).removingPercentEncoding }
        default: if let day { anchor = day }
        }
    }
}
