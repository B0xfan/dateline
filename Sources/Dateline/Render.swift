// Off-screen pictures of the window on sample calendars, for checking the look against the approved mockups.
import SwiftUI
import AppKit
import ScreenCaptureKit

// A real window, so the system toolbar, sidebar and glass draw as in use. It sits behind the desktop picture, never in sight: the system will not capture a window off every screen.
private final class ShotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
}

// `change`: done once the window has drawn, to prove the window follows it (--late).
@MainActor private func saveWindow<V: View>(_ view: V, dark: Bool, wait: Double, width: CGFloat, to path: String, change: (() -> Void)? = nil) -> Bool {
    let vc = NSHostingController(rootView: view)
    vc.sceneBridgingOptions = [.toolbars, .title]
    let w = ShotWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.toolbarStyle = .unified
    w.contentViewController = vc
    w.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: true)
    w.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(max(wait, 1)))
    if let change { change(); RunLoop.main.run(until: Date().addingTimeInterval(4)) }  // side panels slide in slowly in a hidden window
    defer { w.close() }
    var picture: CGImage?, done = false
    Task {
        defer { done = true }
        do {
            let found = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = found.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { print("window not listed"); return }
            let c = SCStreamConfiguration(); c.width = Int(width * 2); c.height = 1600; c.showsCursor = false
            picture = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: c)
        } catch { print("capture failed: \(error)") }
    }
    let giveUp = Date().addingTimeInterval(30)
    while !done && Date() < giveUp { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let picture, let data = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { print("no picture: \(path)"); return false }
    print(path)
    return true
}

@MainActor func renderAll(to dir: String, only: Set<String> = []) -> Bool {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    cal.timeZone = TimeZone(identifier: "America/Costa_Rica")!
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))!  // the mockup's "today"
    sampleToday = today
    Here.shared.spot = tamarindo  // the mockups' sunrise and sunset; never the Mac's own location
    WeatherStore.sample = true  // made-up weather, never the network
    Look.reset(); WorkWeek.reset(); Alerts.reset(); Zones.reset(); MenuIcon.reset(); WeatherPrefs.reset()  // pictures always use the normal look and the mockup's week, and never change the saved ones
    var ok = true
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        func shot(_ name: String, wait: Double = 0.2, width: CGFloat = 1380, a4: Bool = false, _ setup: @escaping (AppState) -> Void) {
            if !only.isEmpty && !only.contains(name) { return }
            License.shared.test = nil  // the bought look unless the picture is about the trial
            let app = AppState(store: a4 ? .sampleWithA4() : Store(sample: true), today: today)
            app.taskPanel.openLists = []; app.sidebarOpen = true  // never the folds or sidebar saved on this Mac
            // shortcut: --late can't check the map and email pictures, sheets don't draw off-screen; they come out as the plain calendar.
            let late = CommandLine.arguments.contains("--late")
            if !late { setup(app) }
            // A sheet (the places map) does not draw off-screen, so it is drawn on its own.
            let p = app.emails.items.first { $0.id == app.panels.reviewing }
            if app.panels.mapOpen || p != nil {
                let view = app.panels.mapOpen ? AnyView(PlacesMap(app: app, store: app.store)) : AnyView(EmailReview(app: app, p: p!).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.side))
                ok = save(view.frame(width: width, height: 800), dark: dark, wait: wait, width: width, to: "\(dir)/\(name)-\(tag).png") && ok
            } else {
                ok = saveWindow(MainView(app: app, store: app.store, panels: app.panels), dark: dark, wait: wait, width: width, to: "\(dir)/\(name)-\(tag).png", change: late ? { setup(app) } : nil) && ok
            }
        }
        // The free trial (approved mockup trial-mockups.html): days left, the last day, and ended (calendar to look at only).
        shot("trial-days") { $0.mode = .week; $0.days = 7; License.shared.test = .trial(daysLeft: 5) }
        shot("trial-last") { $0.mode = .week; $0.days = 7; License.shared.test = .trial(daysLeft: 1) }
        shot("trial-ended") { $0.mode = .week; $0.days = 7; License.shared.test = .ended }
        for (n, st) in [("trial", License.Status.trial(daysLeft: 5)), ("ended", .ended), ("bought", .bought(serial: 586300))] where only.isEmpty || only.contains("license-\(n)") {
            License.shared.test = st
            ok = save(LicenseSettings().background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/license-\(n)-\(tag).png") && ok
        }
        License.shared.test = nil
        shot("day") { $0.mode = .day }
        // shortcut: a pop-up does not draw off-screen, so this is its list on the pop-up colour, without the system frame and arrow; check the real one in the app.
        if only.isEmpty || only.contains("more") {  // the "N more" pop-up, on the busiest sample day
            let st = Store(sample: true), app = AppState(store: st, today: today)
            let d = (0..<35).map { cal.date(byAdding: .day, value: $0 - 14, to: cal.startOfDay(for: today))! }.max { st.shown(on: $0).count < st.shown(on: $1).count }!
            ok = save(MoreList(app: app, store: st, day: d, list: st.shown(on: d)) {}.background(Palette.pop).frame(width: 300, height: 420).background(Palette.side), dark: dark, to: "\(dir)/more-\(tag).png") && ok
        }
        shot("week") { $0.mode = .week; $0.days = 7 }
        shot("week5") { $0.mode = .week; $0.days = 5 }
        shot("month") { $0.mode = .month }
        shot("year") { $0.mode = .year }
        shot("quarter") { $0.mode = .quarter }
        shot("add-preview") { $0.mode = .week; $0.days = 7; $0.addText = "Dinner with Ana Friday 7pm at Casa Luna"; $0.addBox.focused = true }
        shot("details") { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Write proposal" }?.id; a.panels.panelOpen = true }
        shot("details-extras") { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Christian at the condo" }?.id; a.panels.panelOpen = true }
        shot("set-family") { a in a.pickSet(3) }
        shot("tasks-week") { $0.mode = .week; $0.days = 5 }
        // Moved into the working day, to check the dashed block.
        shot("task-timed") { a in a.mode = .week; a.days = 5
            if let i = a.store.todos.firstIndex(where: { $0.title == "Electrician" }) { a.store.todos[i].due = cal.date(byAdding: .hour, value: 7, to: addDays(cal.startOfDay(for: today), 1)) } }
        // Phase 5 (approved mockups): the event map, drive time block, sun and moon. The map picture loads from Apple Maps, so it waits longer.
        shot("place-details", wait: 4) { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Dinner with Ana" }?.id; a.panels.panelOpen = true }
        shot("sun-week5") { $0.mode = .week; $0.days = 5 }
        // A set's name in the toolbar at the smallest window: nothing may spill past the window's edges (John's 2026-10-28 bug).
        shot("set-narrow", width: 980) { a in a.mode = .week; a.days = 7; a.pickSet(3) }
        // The calendars sidebar hidden with the toolbar's first button (John 2026-10-28), at full and smallest width.
        shot("no-sidebar") { a in a.mode = .week; a.days = 7; a.sidebarOpen = false }
        shot("no-sidebar-narrow", width: 980) { a in a.mode = .week; a.days = 7; a.sidebarOpen = false; a.panels.tasksOpen = true }
        // The 7-day week at the smallest window with a side panel open: its left edge must stay in the window (John's 2026-10-28 bug).
        shot("week-narrow-tasks", width: 980) { a in a.mode = .week; a.days = 7; a.panels.tasksOpen = true }
        shot("week-narrow-details", width: 980) { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Write proposal" }?.id; a.panels.panelOpen = true }
        for m in [Mode.day, .month, .quarter, .year] { shot("narrow-\(m.rawValue.lowercased())", width: 980) { a in a.mode = m; a.panels.tasksOpen = true } }
        // Week views start on the day you are on: from a Wednesday, the 5-day view skips the weekend.
        shot("week3-midweek") { a in a.mode = .week; a.days = 3; a.anchor = addDays(a.anchor, 2) }
        shot("week5-midweek") { a in a.mode = .week; a.days = 5; a.anchor = addDays(a.anchor, 2) }
        shot("week7-midweek") { a in a.mode = .week; a.days = 7; a.anchor = addDays(a.anchor, 2) }
        // Phase 9 email to event (approved mockup section 1): the waiting emails in the sidebar, and the review window.
        shot("from-email") { $0.mode = .week; $0.days = 7 }
        shot("email-review") { $0.panels.reviewing = "s1" }
        shot("email-review-nodate") { $0.panels.reviewing = "s3" }
        shot("places-map", wait: 4) { $0.mode = .week; $0.days = 7; $0.panels.mapOpen = true }
        shot("task-list") { $0.mode = .week; $0.days = 5; $0.panels.tasksOpen = true }
        shot("a4-list", a4: true) { $0.mode = .week; $0.days = 5; $0.panels.tasksOpen = true; $0.taskPanel.openLists = ["a4-launch"] }
        shot("a4-timed", a4: true) { a in a.mode = .week; a.days = 5; a.panels.openTaskID = "a4-Vet appointment" }
        shot("a4-details", a4: true) { a in a.mode = .week; a.days = 5; a.panels.openTaskID = "a4-Choose a license for Dateline" }
        ok = save(A4Settings(store: .sampleWithA4()).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/a4-settings-\(tag).png") && ok
        // Folded no-date lists (approved mockup): Groceries open past 20 tasks, so "Show all" shows; the others folded.
        shot("task-folded") { a in a.mode = .week; a.days = 5; a.panels.tasksOpen = true; a.taskPanel.openLists = ["r-groc"]
            for i in 1...22 { a.store.todos.append(ToDo(id: "g\(i)", listID: "r-groc", title: "Grocery item \(i)")) }
            for t in ["Fix the gate", "Paint the balcony"] { a.store.todos.append(ToDo(id: t, listID: "r-condo", title: t)) } }
        shot("task-one-list") { a in a.mode = .week; a.days = 5; a.panels.tasksOpen = true; a.taskPanel.filter = "r-condo"
            for t in ["Fix the gate", "Paint the balcony"] { a.store.todos.append(ToDo(id: t, listID: "r-condo", title: t)) } }
        shot("task-details") { a in a.mode = .week; a.days = 5; a.panels.openTaskID = a.store.todos.first { $0.title == "Buy AC filter" }?.id }
        // A task with a time: no "no time" link next to the time (John 2026-10-28), and the notes box with its resize grip.
        shot("task-details-timed") { a in a.mode = .week; a.days = 5; a.panels.openTaskID = a.store.todos.first { $0.title == "Electrician" }?.id }
        do {
            let a = AppState(store: Store(sample: true), today: today)
            ok = save(SetEditor(app: a, store: a.store, draft: a.store.sets[1]).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/set-editor-\(tag).png") && ok
            ok = save(LookSettings(app: a).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/look-\(tag).png") && ok
            ok = save(WeekSettings(app: a).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/week-settings-\(tag).png") && ok
            ok = save(AlertSettings(app: a, store: a.store).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/alert-settings-\(tag).png") && ok
            ok = save(ZoneSettings(app: a).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/zone-settings-\(tag).png") && ok
            ok = save(MenuBarSettings(app: a).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/menubar-settings-\(tag).png") && ok
            ok = save(WeatherSettings(app: a).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/weather-settings-\(tag).png") && ok
            ok = save(WeatherSettings(app: a, town: "Tamar", found: [Town(label: "Tamarindo, Guanacaste, Costa Rica", geo: tamarindo), Town(label: "Tamarac, Florida, United States", geo: Geo(lat: 26.2, lon: -80.25))]).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/weather-town-search-\(tag).png") && ok
            ok = save(AccountSettings(store: a.store).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/accounts-\(tag).png") && ok
            a.store.accounts = [Account(kind: "icloud", email: "john@icloud.com", cals: [AccCal(id: "acc-x-1", remote: "", title: "Home", color: "#FF2968", writable: true), AccCal(id: "acc-x-2", remote: "", title: "Family", color: "#34C759", writable: false)], synced: today)]
            ok = save(AccountSettings(store: a.store, picked: a.store.accounts[0].id).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/accounts-icloud-\(tag).png") && ok
            ok = save(AccountSettings(store: a.store, picked: "mac").background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/accounts-mac-\(tag).png") && ok
            ok = save(AccountSettings(store: a.store, adding: "icloud").background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/accounts-add-\(tag).png") && ok
            // Phase 8 attachments (approved mockup section 2): files on an iCloud event, and the hint on a calendar from the Mac's settings.
            let macCals = a.store.calendars
            a.store.calendars = a.store.accInfos + macCals
            let rental = Item(id: "acc-x-1/r", calendarID: "acc-x-1", title: "Casa Luna", start: today, end: today, allDay: true, place: "", notes: "", showAs: .busy,
                              files: [Attach(name: "Rental agreement.pdf", url: "https://p1.example/a/1", size: 240_000, id: "1", type: "application/pdf"),
                                      Attach(name: "Casa Luna gate code.jpg", url: "https://p1.example/a/2", size: 1_100_000, id: "2", type: "image/jpeg")])
            if let fam = a.store.items.first(where: { $0.calendarID == "family" }) {
                ok = save(HStack(alignment: .top, spacing: 40) { AttachmentsBox(store: a.store, item: rental).frame(width: 288); AttachmentsBox(store: a.store, item: fam).frame(width: 288) }
                    .font(.ui(13)).padding(24).frame(width: 1380, height: 800, alignment: .topLeading).background(Palette.win), dark: dark, to: "\(dir)/attachments-\(tag).png") && ok
            } else { ok = false }
            a.store.accounts = []; a.store.calendars = macCals
            ok = save(UpdateSettings().background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/update-settings-\(tag).png") && ok
            let soon = a.store.soon.filter { $0.end > today && cal.isDate($0.start, inSameDayAs: today) && !$0.allDay }  // what's still ahead, as in the mockups.sorted { $0.start < $1.start }
            if let first = soon.first {
                ok = save(FullAlertView(items: [first], store: a.store, now: first.start, next: soon.dropFirst().first, close: {}, snooze: {}, open: { _ in }).frame(width: 1380, height: 800), dark: dark, to: "\(dir)/full-alert-\(tag).png") && ok
            }
            ok = save(MenuDrop(app: a, store: a.store, now: today, items: soon, close: {}).background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/menu-drop-\(tag).png") && ok
            // Phase 7 (approved mockup): the Subscribe window's two tabs, drawn on their own like the set editor.
            let addr = "https://calendar.example-school.cr/grade5/schedule.ics"
            ok = save(SubscribeSheet(app: a, store: a.store, address: addr, name: "Grade 5 schedule", found: (sampleICS, parseICS(sampleICS)), checked: addr).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/subscribe-\(tag).png") && ok
            ok = save(SubscribeSheet(app: a, store: a.store, tab: 1).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/ready-made-\(tag).png") && ok
            ok = save(EmojiPicker(recent: ["🏠", "🦷"]) { _ in }.background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/emoji-\(tag).png") && ok
        }
        do {  // Phase 8: five minutes before the Zoom call, its Join button on the event, in the panel and on the full alert.
            let t = cal.date(byAdding: .minute, value: 24 * 60 + 74, to: today)!
            let a = AppState(store: Store(sample: true), today: t)
            a.mode = .week; a.days = 7; a.sidebarOpen = true; a.taskPanel.openLists = []
            if let call = a.store.items.first(where: { $0.title == "Client call" }) {
                a.selectedID = call.id; a.panels.panelOpen = true
                ok = saveWindow(MainView(app: a, store: a.store, panels: a.panels), dark: dark, wait: 1, width: 1380, to: "\(dir)/call-\(tag).png") && ok
                ok = save(EventBlock(item: call, color: a.store.color(call), selected: false, height: 60, now: t).frame(width: 220, height: 58).padding(20).background(Palette.win), dark: dark, to: "\(dir)/call-block-\(tag).png") && ok
                ok = save(FullAlertView(items: [call], store: a.store, now: t, next: nil, close: {}, snooze: {}, open: { _ in }).frame(width: 1380, height: 800), dark: dark, to: "\(dir)/call-alert-\(tag).png") && ok
            } else { ok = false }
        }
        do {  // Phase 9 (approved mockup section 4): Settings, Assistant, with two things Claude did, the newest one undoable.
            let a = AppState(store: Store(sample: true), today: today), ai = Assistant.test(a)
            ai.on = true
            let moved = Assistant.Line(when: today.addingTimeInterval(-25 * 60), text: "Moved \"Dentist\" to Thu 4:00 PM")
            ai.log = [moved, Assistant.Line(when: today.addingTimeInterval(-40 * 60), text: "Looked at Nov 2 to Nov 8")]
            ai.undos[moved.id] = { nil }
            ok = save(AssistantSettings(app: a, a: ai, claudeHere: true, connected: true).frame(width: 760, alignment: .top).background(Palette.win), dark: dark, width: 760, to: "\(dir)/assistant-\(tag).png") && ok
        }
        let app = AppState(store: Store(sample: true), today: today)
        app.quick.text = "Lunch with Sam tomorrow 1pm /Personal -a15m -r1w"
        ok = save(QuickAddView(app: app, store: app.store, quick: app.quick).padding(40).frame(width: 1380, height: 800, alignment: .top).background(Color(red: 0.45, green: 0.5, blue: 0.7)), dark: dark, to: "\(dir)/quick-add-\(tag).png") && ok
        app.quick.pick = app.quickSuggestions.first
        ok = save(QuickAddView(app: app, store: app.store, quick: app.quick).padding(40).frame(width: 1380, height: 800, alignment: .top).background(Color(red: 0.45, green: 0.5, blue: 0.7)), dark: dark, to: "\(dir)/quick-add-picked-\(tag).png") && ok
    }
    return ok
}

@MainActor private func save<V: View>(_ view: V, dark: Bool, wait: Double = 0.2, width: CGFloat = 1380, to path: String) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(wait))  // let onAppear and the first layout pass run
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
    print(path)
    return true
}
