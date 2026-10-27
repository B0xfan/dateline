// Off-screen pictures of the window on sample calendars, for checking the look against the approved mockups.
import SwiftUI
import AppKit

@MainActor func renderAll(to dir: String) -> Bool {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    cal.timeZone = TimeZone(identifier: "America/Costa_Rica")!
    let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))!  // the mockup's "today"
    sampleToday = today
    var ok = true
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        func shot(_ name: String, _ setup: (AppState) -> Void) {
            let app = AppState(store: Store(sample: true), today: today)
            setup(app)
            ok = save(MainView(app: app, store: app.store).frame(width: 1380, height: 800), dark: dark, to: "\(dir)/\(name)-\(tag).png") && ok
        }
        shot("day") { $0.mode = .day }
        shot("week") { $0.mode = .week; $0.days = 7 }
        shot("week5") { $0.mode = .week; $0.days = 5 }
        shot("month") { $0.mode = .month }
        shot("year") { $0.mode = .year }
        shot("add-preview") { $0.mode = .week; $0.days = 7; $0.addText = "Dinner with Ana Friday 7pm at Casa Luna"; $0.addFocused = true }
        shot("details") { a in a.mode = .week; a.days = 7; a.selectedID = a.store.items.first { $0.title == "Write proposal" }?.id; a.panelOpen = true }
    }
    return ok
}

@MainActor private func save<V: View>(_ view: V, dark: Bool, to path: String) -> Bool {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 1380, height: 800)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))  // let onAppear and the first layout pass run
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
    print(path)
    return true
}
