// The menu bar: every toolbar button and key is here too, so people can find them. Plain-letter keys stay in the key handler (Model), because a menu key would also fire while typing.
import SwiftUI
import UniformTypeIdentifiers
import DatelineCore

struct AppCommands: Commands {
    let app: AppState
    @ObservedObject var store: Store  // the set list and its keys follow changes; the app only redraws menus for its own
    @ObservedObject var panels: Panels  // Show or Hide Tasks, and what the set editor blocks
    @ObservedObject var fullScreen = FullScreen.shared  // Enter or Exit Full Screen

    func toggle(_ title: String, _ on: Bool, _ pick: @escaping () -> Void) -> Toggle<Text> {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in pick() }))
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesItem() }
        SidebarCommands()
        ToolbarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Event") {
                app.openMain?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { app.addBox.focusAsks += 1 }  // shortcut: a reopened window needs a moment before its add box listens; fine unless the Mac is very slow
            }.keyboardShortcut("n")
            Button("New Set…") { app.newSet() }
            Button("Edit Sets…") { app.openMain?(); app.panels.editingSet = store.activeSet ?? store.sets.first }.disabled(store.sets.isEmpty)
            Divider()
            Button("Subscribe to Calendar…") { app.openMain?(); app.panels.subscribing = true }
            Button("Make Event from Email File…") {
                let o = NSOpenPanel(); o.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]; o.allowsMultipleSelection = true
                guard o.runModal() == .OK else { return }
                o.urls.forEach(app.emails.importFile); app.openMain?()
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Find Event") { app.openMain?(); app.panels.searching = true }  // Command F is in the key handler (Model)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(Mode.allCases.enumerated()), id: \.element) { i, m in
                toggle(m.rawValue, app.mode == m) { app.openMain?(); app.mode = m }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.option, .command])
            }
            Menu("Days in Week") {
                ForEach([3, 5, 7], id: \.self) { d in toggle("\(d) Days", app.days == d) { app.days = d } }
            }
            Menu("Calendar Set") {
                Button("All Calendars") { app.pickSet(1) }.keyboardShortcut("1")
                ForEach(Array(store.sets.prefix(8).enumerated()), id: \.element.id) { i, s in
                    Button(s.name) { app.pickSet(i + 2) }.keyboardShortcut(KeyEquivalent(Character(String(i + 2))))
                }
            }.disabled(app.panels.editingSet != nil)  // the set editor is showing what would change behind it
            Divider()
            Button("Today") { app.openMain?(); app.goToday() }.keyboardShortcut("t")
            Button("Previous") { app.openMain?(); app.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            Button("Next") { app.openMain?(); app.step(1) }.keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            Divider()
            Button(app.panels.tasksOpen ? "Hide Tasks" : "Show Tasks") { app.openMain?(); app.panels.tasksOpen.toggle() }.keyboardShortcut("r", modifiers: [.option, .command])
            Button("Show Map") { app.openMain?(); app.panels.mapOpen = true }.keyboardShortcut("p", modifiers: [.option, .command])
            Divider()
            Button(fullScreen.on ? "Exit Full Screen" : "Enter Full Screen") {
                app.openMain?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fullScreen.toggle() }  // shortcut: a reopened window is handed to FullScreen a moment after it appears; fine unless the Mac is very slow
            }.keyboardShortcut("f", modifiers: [.control, .command])
        }
        CommandMenu("Event") {
            Button("Open Details") { app.openMain?(); app.panels.panelOpen = true }.disabled(app.selected == nil)
            Button("Delete Event…") { app.openMain?(); app.panels.confirmDelete = app.selected }.disabled(app.selected == nil)
            Button("Delete Task") { app.openMain?(); if let t = app.openTask { app.deleteTask(t) } }.disabled(app.openTask == nil || app.openTask?.a4 != nil)
            Divider()
            Button("Previous Event") { app.openMain?(); app.selectNext(-1) }
            Button("Next Event") { app.openMain?(); app.selectNext(1) }
            Button("Move 15 Minutes Earlier") { app.openMain?(); app.nudge(-15) }.disabled(app.selected == nil)
            Button("Move 15 Minutes Later") { app.openMain?(); app.nudge(15) }.disabled(app.selected == nil)
            Divider()
            Button("Undo Last Change") { app.openMain?(); app.undo() }.disabled(!app.canUndo)
        }
        CommandGroup(replacing: .help) {
            Button("Dateline Manual") { NSWorkspace.shared.open(URL(string: "https://dateline.app/manual")!) }
            Button("Keyboard Shortcuts") { app.openMain?(); app.panels.showShortcuts = true }.keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}
