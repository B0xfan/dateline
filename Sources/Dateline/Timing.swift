// --timing <file>: how long the slow calendar reads take on this Mac's real calendars. Only times and counts go in the file, never event text.
// Never asks for access (no permission box) and never starts the app: no window, no settings written, no sign-ins.
import Foundation
import AppKit
import SwiftUI

@MainActor func timingCheck(_ path: String) -> Int32 {
    guard AppleCalendar.hasEventAccess else {
        try? "no calendar access for this copy, nothing timed\n".write(toFile: path, atomically: true, encoding: .utf8)
        return 2
    }
    let source = AppleCalendar(), today = cal.startOfDay(for: Date())
    var out = ""
    func time(_ name: String, _ a: Date, _ b: Date) {
        var runs: [Double] = [], count = 0
        for _ in 0..<5 {
            let t = Date()
            count = source.events(from: a, to: b).count
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

// --timing-file <file.ics>: how long a subscribed calendar's file takes to read and to show. Saves nothing.
func timingFile(_ path: String) -> Int32 {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("Can't read \(path)"); return 1 }
    func ms(_ work: () -> Int) -> String {
        var runs: [Double] = [], n = 0
        for _ in 0..<5 { let t = Date(); n = work(); runs.append(Date().timeIntervalSince(t) * 1000) }
        return "\(Int(runs.sorted()[2])) ms (\(n))"
    }
    let events = parseICS(text), s = Sub(url: "", name: "timing", color: 0), today = cal.startOfDay(for: Date())
    print("Read the file:", ms { parseICS(text).count })
    print("Show a week:", ms { subItems(s, events, from: today, to: addDays(today, 9)).count })
    print("Show 120 days:", ms { subItems(s, events, from: today, to: addDays(today, 120)).count })
    print("Show a year:", ms { subItems(s, events, from: today, to: addDays(today, 365)).count })
    return 0
}

// --timing-ui: how long a window redraw takes on made-up calendars with 600 extra events, in a hidden window behind the desktop. Never touches real calendars or settings.
@MainActor func timingUI() -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    Here.shared.spot = tamarindo  // never the Mac's own location
    WeatherStore.sample = true  // made-up weather, never the network
    Look.reset(); WorkWeek.reset(); Alerts.reset(); Zones.reset(); MenuIcon.reset(); WeatherPrefs.reset()  // never the saved ones
    let store = Store(sample: true), app = AppState(store: store)
    app.taskPanel.openLists = []; app.sidebarOpen = true
    let start = cal.startOfDay(for: Date())
    for i in 0..<600 {  // spread over the months around today
        var p = Parsed(start: addDays(start, i % 200 - 100).addingTimeInterval(Double(i % 9 + 8) * 3600), end: addDays(start, i % 200 - 100).addingTimeInterval(Double(i % 9 + 9) * 3600))
        p.title = "Event \(i)"
        store.add(p, calendarID: "work")
    }
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    w.contentViewController = NSHostingController(rootView: MainView(app: app, store: store, panels: app.panels))
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
        app.addBox.focused = true  // with the preview card, as in real typing
        time("\(m.rawValue): one letter in the add box") { app.addText = String(repeating: "a", count: $0 + 1) }
        app.addText = ""; app.addBox.focused = false
        time("\(m.rawValue): clock tick") { app.now = app.now.addingTimeInterval(30 + Double($0)) }
        time("\(m.rawValue): step forward") { app.step($0 % 2 == 0 ? 1 : -1) }
    }
    w.close()
    return 0
}

// --follow-check: the split state only redraws the screens that watch it, so each part is changed after a hidden window has drawn and the window must follow. Made-up calendars, no screen capture, saves nothing.
@MainActor func followCheck() -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))!  // a fixed Monday: on a Sunday the sample week is not the week shown
    sampleToday = today
    Here.shared.spot = tamarindo
    WeatherStore.sample = true
    Look.reset(); WorkWeek.reset(); Alerts.reset(); Zones.reset(); MenuIcon.reset(); WeatherPrefs.reset()
    let store = Store(sample: true), app = AppState(store: store, today: today)
    app.mode = .week
    func window<V: View>(_ view: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []  // otherwise the window shrinks to its smallest size and a side panel has nowhere to slide
        host.sceneBridgingOptions = [.toolbars, .title]  // as the pictures do: without it there is no toolbar, and the add box lives there at full width
        w.toolbarStyle = .unified
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1380, height: 800))
        w.orderFrontRegardless()
        return w
    }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
    func fields(_ v: NSView?) -> [NSTextField] { guard let v else { return [] }; return (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields) }
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { print((ok ? "ok: " : "FAIL: ") + what); if !ok { fails += 1 } }
    let w = window(MainView(app: app, store: store, panels: app.panels))
    settle()
    func values() -> [String] { fields(w.contentView?.superview).map(\.stringValue) }  // the superview takes in the toolbar

    app.selectedID = store.items.first { $0.title == "Write proposal" }?.id
    expect(app.selectedID != nil, "the sample event is in the week shown")
    app.panels.panelOpen = true
    // Being in the window is not being seen: the panel slides in, so its title must end up inside the window.
    func titleEdge() -> CGFloat? { fields(w.contentView).first { $0.stringValue == "Write proposal" }.map { $0.convert($0.bounds, to: nil).maxX } }
    let began = Date()
    while Date().timeIntervalSince(began) < 8, (titleEdge() ?? .infinity) > w.frame.width - 1 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print("details panel in view after \(String(format: "%.2f", Date().timeIntervalSince(began))) s, title edge \(titleEdge() ?? -1) of \(w.frame.width)")
    settle()
    expect(values().contains("Write proposal"), "event details open")
    expect((titleEdge() ?? .infinity) <= w.frame.width, "event details slide fully into the window")
    app.panels.panelOpen = false; settle()
    expect(!values().contains("Write proposal"), "event details close")
    app.panels.tasksOpen = true; settle()
    app.taskPanel.text = "From the check"; settle()
    expect(values().contains("From the check"), "the task list opens and shows its own text")
    app.taskPanel.text = ""
    app.panels.openTaskID = store.todos.first { $0.title == "Call the plumber" }?.id; settle()
    expect(values().contains("Call the plumber"), "a task's details open from the task list")
    app.panels.openTaskID = nil
    app.panels.tasksOpen = false; settle()  // with a side panel open the add box folds into the toolbar's >> menu
    for (name, open, shut) in [("shortcuts", { app.panels.showShortcuts = true }, { app.panels.showShortcuts = false }),
                               ("map", { app.panels.mapOpen = true }, { app.panels.mapOpen = false }),
                               ("subscribe", { app.panels.subscribing = true }, { app.panels.subscribing = false })] {
        open(); settle()
        expect(w.attachedSheet != nil, "the \(name) sheet opens")
        shut(); settle()
        expect(w.attachedSheet == nil, "the \(name) sheet closes")
    }
    app.addBox.text = "Lunch"; settle()
    if !values().contains("Lunch") { print("in the window: \(values())") }
    expect(values().contains("Lunch"), "the add box shows its text")
    app.addBox.text = ""
    w.close()
    let q = window(QuickAddView(app: app, store: store, quick: app.quick))
    settle()
    app.quick.text = "Quick one"; settle()
    expect(fields(q.contentView).map(\.stringValue).contains("Quick one"), "quick add shows its text")
    q.close()
    print(fails == 0 ? "follow-check: all passed" : "follow-check: \(fails) failed")
    return fails == 0 ? 0 : 1
}
