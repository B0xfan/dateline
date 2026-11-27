// Keeps the Home Screen widgets (Widgets/DatelineWidgets.swift) up to date, as WidgetFeed.swift does on the Mac: writes their copy
// when the calendars, tasks, sets or drive times change, and saves the ticks made in the Tasks widget like a tap on the task.
import Foundation
import Combine
import WidgetKit
import DatelineCore

@MainActor
final class PhoneWidgetFeed {
    static let shared = PhoneWidgetFeed()
    private weak var app: PhoneState?
    private var watch: AnyCancellable?

    func attach(_ app: PhoneState) {
        self.app = app
        let s = app.store
        // A sync sends bursts of changes: one write two seconds after the last.
        watch = Publishers.MergeMany(s.$soon.map { _ in () }.eraseToAnyPublisher(), s.$todos.map { _ in () }.eraseToAnyPublisher(),
                                     s.$sets.map { _ in () }.eraseToAnyPublisher(), app.$drive.map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.takeTicks(); self?.write() }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PhoneWidgetFeed.shared.takeTicks() } }
        }, WidgetShare.tickNote as CFString, nil, .deliverImmediately)
    }

    func write() {
        guard let app else { return }
        if WidgetShare.write(app.store.widgetSnap(drive: app.drive, weather: app.wx)) { WidgetCenter.shared.reloadAllTimelines() }
    }

    // Ticks made while the app was closed wait in the app group; DatelineApp calls this again whenever the app comes to the front.
    func takeTicks() {
        guard let app else { return }
        if WidgetShare.takeAsk() == "add", let link = URL(string: "dateline://add") { app.open(link: link) }  // the Up next widget's Add button
        WidgetShare.takeTick(todos: app.store.todos, loaded: app.store.taskAccess != .unknown, save: app.toggle)
    }
}

extension PhoneState {
    /// A widget's link: dateline://day/2026-11-27, dateline://event/<id>?day=2026-11-27, dateline://add.
    /// shortcut: an event link opens its day, not the event itself; open the event too if John asks.
    func open(link: URL) {
        tab = .calendar
        if link.host == "add" { adding = ""; return }
        let day = WidgetShare.day(of: link)
        if let day { anchor = day }
    }
}
