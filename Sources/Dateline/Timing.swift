// --timing <file>: how long the slow calendar reads take on this Mac's real calendars. Only times and counts go in the file, never event text.
// Never asks for access (no permission box) and never starts the app: no window, no settings written, no sign-ins.
import Foundation
import EventKit
import AppKit
import SwiftUI

func timingCheck(_ path: String) -> Int32 {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
        try? "no calendar access for this copy, nothing timed\n".write(toFile: path, atomically: true, encoding: .utf8)
        return 2
    }
    let ek = EKEventStore(), today = cal.startOfDay(for: Date())
    var out = ""
    func time(_ name: String, _ a: Date, _ b: Date) {
        var runs: [Double] = [], count = 0
        for _ in 0..<5 {
            let t = Date()
            count = ek.events(matching: ek.predicateForEvents(withStart: a, end: b, calendars: nil)).map(Store.item).count
            runs.append(Date().timeIntervalSince(t) * 1000)
        }
        out += "\(name): \(Int(runs.sorted()[2])) ms (\(count) events; worst \(Int(runs.max()!)) ms)\n"
    }
    time("Week step, the days shown", addDays(today, -1), addDays(today, 9))
    time("Coming up, 120 days", addDays(today, -1), addDays(today, 120))
    let y = cal.dateInterval(of: .year, for: today)!
    time("Year view, whole year", addDays(y.start, -1), addDays(y.end, 2))
    time("Quick add past events, one year", addDays(today, -365), today)
    return (try? out.write(toFile: path, atomically: true, encoding: .utf8)) == nil ? 1 : 0
}

// --timing-ui: how long a window redraw takes on made-up calendars with 600 extra events, in a hidden window behind the desktop. Never touches real calendars or settings.
@MainActor func timingUI() -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    Here.shared.spot = tamarindo  // never the Mac's own location
    WeatherStore.sample = true  // made-up weather, never the network
    Look.reset(); WorkWeek.reset(); Alerts.reset(); Zones.reset(); MenuIcon.reset(); WeatherPrefs.reset()  // never the saved ones
    let store = Store(sample: true), app = AppState(store: store)
    app.openTaskLists = []; app.sidebarOpen = true
    let start = cal.startOfDay(for: Date())
    for i in 0..<600 {  // spread over the months around today
        var p = Parsed(start: addDays(start, i % 200 - 100).addingTimeInterval(Double(i % 9 + 8) * 3600), end: addDays(start, i % 200 - 100).addingTimeInterval(Double(i % 9 + 9) * 3600))
        p.title = "Event \(i)"
        store.add(p, calendarID: "work")
    }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    w.contentViewController = NSHostingController(rootView: MainView(app: app, store: store))
    w.orderFrontRegardless()
    func settle(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    func time(_ name: String, _ change: (Int) -> Void) {
        settle(0.5)
        var runs: [Double] = []
        for i in 0..<21 {
            let t = Date()
            change(i)
            CATransaction.flush(); RunLoop.main.run(mode: .default, before: Date()); w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded()
            runs.append(Date().timeIntervalSince(t) * 1000)
            settle()
        }
        print("\(name): \(Int(runs.sorted()[10])) ms (worst \(Int(runs.max()!)) ms)")
    }
    for m in [Mode.week, .month, .quarter, .year] {
        app.mode = m
        settle(0.5)
        app.addFocused = true  // with the preview card, as in real typing
        time("\(m.rawValue): one letter in the add box") { app.addText = String(repeating: "a", count: $0 + 1) }
        app.addText = ""; app.addFocused = false
        time("\(m.rawValue): clock tick") { app.now = app.now.addingTimeInterval(30 + Double($0)) }
        time("\(m.rawValue): step forward") { app.step($0 % 2 == 0 ? 1 : -1) }
    }
    w.close()
    return 0
}
