// Off-screen pictures of the window on sample calendars, for checking the look against the approved mockups.
import SwiftUI
import AppKit

@MainActor func renderAll(to dir: String) -> Bool {
    _ = NSApplication.shared
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
        func shot(_ name: String, wait: Double = 0.2, width: CGFloat = 1380, _ setup: (AppState) -> Void) {
            let app = AppState(store: Store(sample: true), today: today)
            app.openTaskLists = []; app.sidebarOpen = true  // never the folds or sidebar saved on this Mac
            setup(app)
            // A sheet (the places map) does not draw off-screen, so it is drawn on its own.
            let view = app.mapOpen ? AnyView(PlacesMap(app: app, store: app.store)) : AnyView(MainView(app: app, store: app.store))
            ok = save(view.frame(width: width, height: 800), dark: dark, wait: wait, width: width, to: "\(dir)/\(name)-\(tag).png") && ok
        }
        shot("day") { $0.mode = .day }
        shot("week") { $0.mode = .week; $0.days = 7 }
        shot("week5") { $0.mode = .week; $0.days = 5 }
        shot("month") { $0.mode = .month }
        shot("year") { $0.mode = .year }
        shot("quarter") { $0.mode = .quarter }
        shot("add-preview") { $0.mode = .week; $0.days = 7; $0.addText = "Dinner with Ana Friday 7pm at Casa Luna"; $0.addFocused = true }
        shot("details") { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Write proposal" }?.id; a.panelOpen = true }
        shot("details-extras") { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Christian at the condo" }?.id; a.panelOpen = true }
        shot("set-family") { a in a.pickSet(3) }
        shot("tasks-week") { $0.mode = .week; $0.days = 5 }
        // Pictures cannot scroll (they show midnight to 9 AM), so move the electrician into view to check the dashed block.
        shot("task-timed") { a in a.mode = .week; a.days = 5
            if let i = a.store.todos.firstIndex(where: { $0.title == "Electrician" }) { a.store.todos[i].due = cal.date(byAdding: .hour, value: 7, to: addDays(cal.startOfDay(for: today), 1)) } }
        // Phase 5 (approved mockups): the event map, drive time block, sun and moon. The map picture loads from Apple Maps, so it waits longer.
        shot("place-details", wait: 4) { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Dinner with Ana" }?.id; a.panelOpen = true }
        shot("sun-week5") { $0.mode = .week; $0.days = 5 }
        // A set's name in the toolbar at the smallest window: nothing may spill past the window's edges (John's 2026-10-28 bug).
        shot("set-narrow", width: 980) { a in a.mode = .week; a.days = 7; a.pickSet(3) }
        // The calendars sidebar hidden with the toolbar's first button (John 2026-10-28), at full and smallest width.
        shot("no-sidebar") { a in a.mode = .week; a.days = 7; a.sidebarOpen = false }
        shot("no-sidebar-narrow", width: 980) { a in a.mode = .week; a.days = 7; a.sidebarOpen = false; a.tasksOpen = true }
        shot("places-map", wait: 4) { $0.mode = .week; $0.days = 7; $0.mapOpen = true }
        shot("task-list") { $0.mode = .week; $0.days = 5; $0.tasksOpen = true }
        // Folded no-date lists (approved mockup): Groceries open past 20 tasks, so "Show all" shows; the others folded.
        shot("task-folded") { a in a.mode = .week; a.days = 5; a.tasksOpen = true; a.openTaskLists = ["r-groc"]
            for i in 1...22 { a.store.todos.append(ToDo(id: "g\(i)", listID: "r-groc", title: "Grocery item \(i)")) }
            for t in ["Fix the gate", "Paint the balcony"] { a.store.todos.append(ToDo(id: t, listID: "r-condo", title: t)) } }
        shot("task-one-list") { a in a.mode = .week; a.days = 5; a.tasksOpen = true; a.taskListFilter = "r-condo"
            for t in ["Fix the gate", "Paint the balcony"] { a.store.todos.append(ToDo(id: t, listID: "r-condo", title: t)) } }
        shot("task-details") { a in a.mode = .week; a.days = 5; a.openTaskID = a.store.todos.first { $0.title == "Buy AC filter" }?.id }
        // A task with a time: no "no time" link next to the time (John 2026-10-28), and the notes box with its resize grip.
        shot("task-details-timed") { a in a.mode = .week; a.days = 5; a.openTaskID = a.store.todos.first { $0.title == "Electrician" }?.id }
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
            a.store.accounts = []
            ok = save(UpdateSettings().background(Palette.pop).frame(width: 1380, height: 800).background(Palette.side), dark: dark, to: "\(dir)/update-settings-\(tag).png") && ok
            let soon = a.store.soon.filter { cal.isDate($0.start, inSameDayAs: today) && !$0.allDay }.sorted { $0.start < $1.start }
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
            a.mode = .week; a.days = 7; a.sidebarOpen = true; a.openTaskLists = []
            if let call = a.store.items.first(where: { $0.title == "Client call" }) {
                a.selectedID = call.id; a.panelOpen = true
                ok = save(MainView(app: a, store: a.store).frame(width: 1380, height: 800), dark: dark, width: 1380, to: "\(dir)/call-\(tag).png") && ok
                ok = save(EventBlock(item: call, color: a.store.color(call), selected: false, height: 60, now: t).frame(width: 220, height: 58).padding(20).background(Palette.win), dark: dark, to: "\(dir)/call-block-\(tag).png") && ok
                ok = save(FullAlertView(items: [call], store: a.store, now: t, next: nil, close: {}, snooze: {}, open: { _ in }).frame(width: 1380, height: 800), dark: dark, to: "\(dir)/call-alert-\(tag).png") && ok
            } else { ok = false }
        }
        let app = AppState(store: Store(sample: true), today: today)
        app.quickText = "Lunch with Sam tomorrow 1pm /Personal -a15m -r1w"
        ok = save(QuickAddView(app: app, store: app.store).padding(40).frame(width: 1380, height: 800, alignment: .top).background(Color(red: 0.45, green: 0.5, blue: 0.7)), dark: dark, to: "\(dir)/quick-add-\(tag).png") && ok
        app.quickPick = app.quickSuggestions.first
        ok = save(QuickAddView(app: app, store: app.store).padding(40).frame(width: 1380, height: 800, alignment: .top).background(Color(red: 0.45, green: 0.5, blue: 0.7)), dark: dark, to: "\(dir)/quick-add-picked-\(tag).png") && ok
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
