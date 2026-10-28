// What the window is showing and every action on it: views, the add box, selection, undo and the keyboard (B25).
import SwiftUI
import AppKit
import Carbon.HIToolbox

enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", quarter = "Quarter", year = "Year" }

@MainActor
final class AppState: ObservableObject {
    let store: Store
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .day { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode"); reload() } }
    @Published var days: Int = { let d = UserDefaults.standard.integer(forKey: "weekDays"); return [3, 5, 7].contains(d) ? d : 7 }() { didSet { if Look.saves { UserDefaults.standard.set(days, forKey: "weekDays") }; reload() } }
    @Published var anchor: Date { didSet { reload() } }
    @Published var selectedID: String?
    @Published var panelOpen = false { didSet { if panelOpen { openTaskID = nil } } }
    // Phase 4 tasks: the task list (R) and one task's details share the right side with the event details.
    @Published var tasksOpen = false { didSet { if tasksOpen { openTaskID = nil; panelOpen = false } } }
    @Published var openTaskID: String? { didSet { if openTaskID != nil { panelOpen = false } } }
    @Published var taskText = ""
    @Published var taskListFilter: String?
    @Published var showDone = false
    @Published var hideNoDate = false
    // The calendars sidebar on the left, hidden with the toolbar's first button or S (John 2026-10-28); kept across restarts.
    @Published var sidebarOpen = UserDefaults.standard.object(forKey: "sidebarOpen") as? Bool ?? true { didSet { if Look.saves { UserDefaults.standard.set(sidebarOpen, forKey: "sidebarOpen") } } }
    // Reminders lists left unfolded in the task list's No date part; kept across restarts.
    @Published var openTaskLists = Set(UserDefaults.standard.stringArray(forKey: "openTaskLists") ?? []) { didSet { if Look.saves { UserDefaults.standard.set(Array(openTaskLists), forKey: "openTaskLists") } } }
    @Published var addText = ""
    @Published var addFocused = false
    @Published var addCalendarID: String?
    @Published var showShortcuts = false
    @Published var mapOpen = false  // Phase 5: the map of all places (P)
    @Published var drive: [String: Int] = [:]  // Phase 5: minutes of driving before each coming event with a place
    let trips = Trips()
    private var travelTimer: Timer?
    var alertCheck = Date()  // Phase 6: alerts are checked from here on
    private var alertTimer: Timer?
    var openMain: (() -> Void)?  // brings the main window back, also after it was closed
    @Published var subscribing = false  // Phase 7: the Subscribe window
    @Published var editingSet: CalSet?  // the set editor is open on this (a new one when it is not in the list yet)
    @Published var look = 0  // bumped when a Look setting changes, to redraw everything
    @Published var confirmDelete: Item?
    @Published var toast: Toast?
    @Published var error: String?
    @Published var now = Date()
    @Published var focusAdd = 0  // bumped to put the cursor in the add box
    // Quick add from any app (Phase 2): its own text, the past event Tab picked, the highlighted suggestion.
    @Published var quickText = "" { didSet { if quickText != oldValue { quickPick = nil; quickSel = 0 } } }
    @Published var quickPick: Item?
    @Published var quickSel = 0
    @Published var quickFocus = 0
    @Published var quickName = UserDefaults.standard.string(forKey: "quickName") ?? "Control Option Space"
    @Published var quickError: String?  // why the last quick add failed, shown in the quick box
    @Published var quickTaken = false  // another app already uses the shortcut
    @Published var keyRefused = false  // the shortcut just picked in Settings was taken, so the old one stays
    @Published var recordingKey = false  // Settings is waiting for a new shortcut
    private var undoStack: [() -> Failure?] = []
    private var monitor: Any?
    private var timer: Timer?

    struct Toast: Equatable { let text: String; let calendar: String; let id = UUID() }

    init(store: Store, today: Date = Date()) {
        self.store = store
        anchor = cal.startOfDay(for: today)
        now = today
        reload()
    }

    // The days the day or week view shows. A 7 day week starts on the first day of the week, a 5 day week is that week's working days, a 3 day week starts on the day you are on.
    var visibleDays: [Date] {
        switch mode {
        case .day: return [anchor]
        case .week:
            if days == 3 { return (0..<3).map { addDays(anchor, $0) } }
            let s = startOfWeek(anchor), week = (0..<7).map { addDays(s, $0) }, work = week.filter(WorkWeek.isWorkDay)
            return days == 5 && !work.isEmpty ? work : week  // no working days ticked: the whole week
        case .month: return monthGrid(anchor)
        case .quarter:
            let q = quarterStart(anchor), a = startOfWeek(q), b = monthGrid(cal.date(byAdding: .month, value: 2, to: q)!).last!
            return (0...cal.dateComponents([.day], from: a, to: b).day!).map { addDays(a, $0) }
        case .year: let y = cal.dateInterval(of: .year, for: anchor)!; return (0..<cal.range(of: .day, in: .year, for: anchor)!.count).map { addDays(y.start, $0) }
        }
    }

    var title: String {
        switch mode {
        case .day: return dateText(anchor, "EEEE, MMMM d, yyyy")
        case .week:
            let d = visibleDays, a = d.first!, b = d.last!
            if a == b { return dateText(a, "EEEE, MMMM d, yyyy") }  // one working day
            if cal.isDate(a, equalTo: b, toGranularity: .month) { return dateText(a, "MMMM d") + " to " + dateText(b, "d, yyyy") }
            return dateText(a, "MMM d") + " to " + dateText(b, "MMM d, yyyy")
        case .month: return dateText(anchor, "MMMM yyyy")
        case .quarter: let q = quarterStart(anchor); return dateText(q, "MMMM") + " to " + dateText(cal.date(byAdding: .month, value: 2, to: q)!, "MMMM yyyy")
        case .year: return dateText(anchor, "yyyy")
        }
    }

    // For a narrow window: no year, short month names.
    var shortTitle: String {
        switch mode {
        case .day: return dateText(anchor, "EEE, MMM d")
        case .week: let d = visibleDays; return d.count == 1 ? dateText(d[0], "EEE, MMM d") : dateText(d.first!, "MMM d") + " to " + dateText(d.last!, "MMM d")
        case .month: return dateText(anchor, "MMM yyyy")
        case .quarter: let q = quarterStart(anchor); return dateText(q, "MMM") + " to " + dateText(cal.date(byAdding: .month, value: 2, to: q)!, "MMM yyyy")
        case .year: return dateText(anchor, "yyyy")
        }
    }

    var weekLabel: String {
        let d = visibleDays
        let a = weekNumber(d.first!), b = weekNumber(mode == .month ? addDays(d.last!, -1) : d.last!)
        return a == b ? "Week \(a)" : "Weeks \(a) to \(b)"
    }

    func reload() {
        let d = visibleDays
        store.show(from: addDays(d.first!, -1), to: addDays(d.last!, 2))
    }

    var shownItems: [Item] { store.items.filter { !store.hidden.contains($0.calendarID) } }
    var selected: Item? { selectedID.flatMap { id in store.items.first { $0.id == id } } }
    var openTask: ToDo? { openTaskID.flatMap { id in store.todos.first { $0.id == id } } }
    var sideOpen: Bool { panelOpen || tasksOpen || openTaskID != nil }
    // Tasks in lists that are ticked in the sidebar: for the list (done ones only with "Show done") and for the calendar (ticked ones stay, struck through).
    var calendarTodos: [ToDo] { store.todos.filter { !store.hiddenLists.contains($0.listID) } }
    var shownTodos: [ToDo] { calendarTodos.filter { showDone || !$0.done } }

    func step(_ n: Int) {
        switch mode {
        case .day: anchor = addDays(anchor, n)
        case .week: anchor = addDays(anchor, n * (days == 3 ? 3 : 7))
        case .month: anchor = cal.date(byAdding: .month, value: n, to: cal.date(from: cal.dateComponents([.year, .month], from: anchor))!)!
        case .quarter: anchor = cal.date(byAdding: .month, value: 3 * n, to: quarterStart(anchor))!
        case .year: anchor = cal.date(byAdding: .year, value: n, to: cal.dateInterval(of: .year, for: anchor)!.start)!
        }
    }

    // Command 1 = all calendars, Command 2 to 9 = the sets in list order.
    func pickSet(_ n: Int) {
        if n == 1 { store.use(nil) } else if store.sets.indices.contains(n - 2) { store.use(store.sets[n - 2]) } else { NSSound.beep() }
    }

    func goToday() { anchor = cal.startOfDay(for: Date()) }

    func open(day: Date) { anchor = cal.startOfDay(for: day); mode = .day }

    // MARK: changes, each one undoable with Command Z

    var preview: Parsed { parseSentence(addText, now: Date()) }
    var addCalendar: CalInfo? { calendar(for: preview, pick: nil).0 }

    var quickPreview: Parsed { let p = parseSentence(quickText, now: Date()); return quickPick.map { applying($0, to: p) } ?? p }
    var quickSuggestions: [Item] { quickPick == nil ? suggestions(parseSentence(quickText, now: Date()).title, in: store.past()) : [] }

    // The calendar a new event goes to, and why: a typed /code, then the picked past event, then the menu choice, then the Mac's default.
    func calendar(for p: Parsed, pick: Item?) -> (CalInfo?, String) {
        let writable = store.calendars.filter(\.writable)
        if let code = p.calendarCode {
            if let c = matchCalendar(code, in: writable, hidden: store.hidden) { return (c, "(from /\(code))") }
            return (calendar(for: Parsed(start: p.start, end: p.end), pick: pick).0, "(no calendar matches /\(code))")
        }
        if let pick, let c = store.calendar(pick.calendarID), c.writable { return (c, "(from past event)") }
        if addCalendarID == nil, let s = store.activeSet, let c = writable.first(where: { $0.id == s.defaultCalendar }) { return (c, "(\(s.name) set)") }
        let c = store.calendar(addCalendarID ?? store.defaultCalendarID ?? "") ?? writable.first
        return (c, c?.id == store.defaultCalendarID ? "(your default)" : "")
    }

    // Saves a new event and shows it selected. Nil when it could not be saved (the error is shown).
    @discardableResult
    func add(_ p: Parsed, calendar: CalInfo?) -> Item? {
        switch store.add(p, calendarID: calendar?.id) {
        case .failure(let f): error = f.message; return nil
        case .success(let it):
            undoStack.append { [weak self] in self?.store.delete(it, series: true) }
            anchor = cal.startOfDay(for: it.start)
            reload()
            selectedID = store.items.first { $0.title == it.title && $0.start == it.start }?.id ?? it.id
            return it
        }
    }

    // Return in the add box. `edit`: Tab, which adds it and opens its details.
    func commitAdd(edit: Bool = false) {
        guard !addText.trimmingCharacters(in: .whitespaces).isEmpty, add(preview, calendar: addCalendar) != nil else { return }
        addText = ""; addFocused = false
        panelOpen = edit
    }

    // Return in the quick add box.
    func commitQuick() {
        guard !quickText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard add(quickPreview, calendar: calendar(for: quickPreview, pick: quickPick).0) != nil else { quickError = error; error = nil; return }
        quickText = ""; quickError = nil
        QuickPanel.shared?.orderOut(nil)
    }

    // Option drag: `it` is the moved copy; the original stays where it was.
    func copy(_ it: Item) {
        guard let c = store.duplicate(it) else { error = "Couldn't copy the event."; return }
        undoStack.append { [weak self] in self?.store.delete(c) }
        selectedID = store.items.first { $0.title == c.title && $0.start == c.start }?.id ?? c.id
    }

    func newEvent(at start: Date) {
        var p = Parsed(start: start, end: start.addingTimeInterval(3600)); p.title = "New event"
        guard case .success(let it) = store.add(p, calendarID: calendar(for: p, pick: nil).0?.id) else { return }
        undoStack.append { [weak self] in self?.store.delete(it) }
        selectedID = store.items.first { $0.title == it.title && $0.start == it.start }?.id ?? it.id
        panelOpen = true
    }

    func save(_ new: Item) {
        guard let old = store.items.first(where: { $0.id == new.id }), old != new else { return }
        if let f = store.update(new) { error = f.message; return }
        undoStack.append { [weak self] in self?.store.update(old) }
    }

    func delete(_ it: Item) {
        if let f = store.delete(it) { error = f.message; return }
        if selectedID == it.id { selectedID = nil; panelOpen = false }
        undoStack.append { [weak self] in
            guard let self, let back = self.store.restore(it) else { return Failure("Couldn't put the event back.") }
            self.selectedID = back.id
            return nil
        }
        toast = Toast(text: it.title, calendar: store.calendar(it.calendarID)?.title ?? "")
        let t = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.toast == t { self?.toast = nil } }
    }

    // MARK: tasks

    func saveTask(_ new: ToDo) {
        guard let old = store.todos.first(where: { $0.id == new.id }), old != new else { return }
        if let f = store.updateTask(new) { error = f.message; return }
        undoStack.append { [weak self] in self?.store.updateTask(old) }
    }

    func toggle(_ t: ToDo) { var n = t; n.done.toggle(); saveTask(n) }

    // Return in the task list's add box: "Call the bank Friday 3pm" is due Friday at 3; no day or time means no due date.
    func commitTask() {
        let text = taskText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let p = parseSentence(text, now: Date())
        // shortcut: with a day or time, the parser's title plus "at <place>" is kept, so short codes like /List are dropped; keep the whole text when that bites.
        let title = !p.dateGiven || p.title.isEmpty ? text : p.place.isEmpty ? p.title : "\(p.title) at \(p.place)"
        var t = ToDo(id: "", listID: "", title: title)
        if p.dateGiven { t.due = p.allDay ? cal.startOfDay(for: p.start) : p.start; t.timed = !p.allDay }
        switch store.addTask(t, listID: taskListFilter) {
        case .failure(let f): error = f.message
        case .success(let added):
            taskText = ""; undoStack.append { [weak self] in self?.store.deleteTask(added) }
            if added.due == nil { openTaskLists.insert(added.listID) }  // so a new no-date task is not hidden in a folded list
        }
    }

    // A task dropped on the day grid takes that day and time.
    func drop(taskID: String, at time: Date) {
        guard var t = store.todos.first(where: { $0.id == taskID }) else { return }
        t.due = time; t.timed = true
        saveTask(t)
    }

    func undo() {
        guard let u = undoStack.popLast() else { NSSound.beep(); return }
        toast = nil
        if let f = u() { error = f.message }
    }

    // Option Up / Down: 15 minutes earlier or later.
    func nudge(_ minutes: Int) {
        guard var it = selected, !it.allDay, store.calendar(it.calendarID)?.writable == true else { return }
        let len = it.end.timeIntervalSince(it.start)
        it.start = snapped(it.start, by: minutes); it.end = it.start.addingTimeInterval(len)
        save(it)
    }

    // Up / Down: the previous or next event on screen, by start time.
    func selectNext(_ dir: Int) {
        let d = visibleDays
        let list = shownItems.filter { $0.end > d.first! && $0.start < addDays(d.last!, 1) }
        guard !list.isEmpty else { return }
        if let i = list.firstIndex(where: { $0.id == selectedID }) {
            selectedID = list[max(0, min(list.count - 1, i + dir))].id
        } else {
            selectedID = (dir > 0 ? list.first(where: { $0.end > Date() }) ?? list.first : list.last)!.id
        }
    }

    // MARK: keyboard

    func startKeys() {
        guard monitor == nil else { return }  // the window can appear again after being closed
        registerQuick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.now = Date(); if let self { MenuBar.shared.update(self) } } }
        if store.access != .sample { Here.shared.start() }
        travelTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in Here.shared.refresh(); self?.planTravel(); self?.store.refreshSubs() } }
        alertTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkAlerts() } }
        MenuBar.shared.update(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.key(e) ? nil : e
        }
    }

    // Returns true when the key was used. Letters are left alone while typing in a field.
    func key(_ e: NSEvent) -> Bool {
        if recordingKey { return false }
        if e.window is QuickPanel { return quickKey(e) }
        if e.keyCode == 53 && showShortcuts { showShortcuts = false; return true }  // Esc on the shortcut list, which is its own window
        // The map is its own window too: Esc or a plain P closes it.
        if mapOpen, e.keyCode == 53 || (e.charactersIgnoringModifiers == "p" && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty) { mapOpen = false; return true }
        if e.window?.title != "Dateline" { return false }  // Settings, or the main window is closed
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let responder = NSApp.keyWindow?.firstResponder
        let typing = responder is NSText || responder is NSDatePicker
        if e.keyCode == 48, addFocused, mods.isEmpty || mods == .shift { commitAdd(edit: true); return true }  // Tab in the add box
        if mods == .command && e.charactersIgnoringModifiers == "z" && !typing { undo(); return true }
        if e.keyCode == 53 {  // Escape
            if showShortcuts { showShortcuts = false; return true }
            if confirmDelete != nil { confirmDelete = nil; return true }
            if addFocused || !addText.isEmpty { addText = ""; addFocused = false; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            if panelOpen { panelOpen = false; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            if openTaskID != nil { openTaskID = nil; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            if tasksOpen { tasksOpen = false; return true }
            if selectedID != nil { selectedID = nil; return true }
            return false
        }
        if typing || confirmDelete != nil || showShortcuts || mapOpen || error != nil { return false }
        if mods == .command, let n = Int(e.charactersIgnoringModifiers ?? ""), (1...9).contains(n) { pickSet(n); return true }
        switch (e.keyCode, mods) {
        case (123, []): step(-1); return true
        case (124, []): step(1); return true
        case (126, []): selectNext(-1); return true
        case (125, []): selectNext(1); return true
        case (126, .option): nudge(-15); return true
        case (125, .option): nudge(15); return true
        case (36, []), (76, []): if selectedID != nil { panelOpen = true; return true }; return false
        case (51, []), (117, []): if let s = selected { confirmDelete = s; return true }; return false
        default: break
        }
        guard mods.subtracting(.shift).isEmpty else { return false }
        switch e.charactersIgnoringModifiers {
        case "n": focusAdd += 1
        case "t": goToday()
        case "r": tasksOpen.toggle()
        case "p": mapOpen = true
        case "s": sidebarOpen.toggle()
        case "1": mode = .day
        case "2": mode = .week
        case "3": mode = .month
        case "4": mode = .quarter
        case "5": mode = .year
        case "?", "/": showShortcuts.toggle()
        default: return false
        }
        return true
    }

    // Keys in the quick add box: Esc closes, Tab uses the highlighted past event, Up / Down move between past events.
    func quickKey(_ e: NSEvent) -> Bool {
        let list = quickSuggestions
        switch e.keyCode {
        case 53: QuickPanel.shared?.orderOut(nil)
        case 48: if list.indices.contains(quickSel) { quickPick = list[quickSel] }
        case 125, 126: if !list.isEmpty { quickSel = (quickSel + (e.keyCode == 125 ? 1 : list.count - 1)) % list.count }
        default: return false
        }
        return true
    }

    // The quick add shortcut, Control Option Space unless changed in Settings. Works while any app is in front.
    func registerQuick() {
        let d = UserDefaults.standard
        let code = d.object(forKey: "quickCode") as? Int ?? kVK_Space, mods = d.object(forKey: "quickMods") as? Int ?? (controlKey | optionKey)
        HotKey.action = { [weak self] in if let self { QuickPanel.toggle(self) } }
        quickTaken = !HotKey.register(code: UInt32(code), mods: UInt32(mods))
    }

    func setQuickKey(_ e: NSEvent) {
        let f = e.modifierFlags
        let parts: [(Bool, String, Int)] = [(f.contains(.control), "Control", controlKey), (f.contains(.option), "Option", optionKey),
                                            (f.contains(.shift), "Shift", shiftKey), (f.contains(.command), "Command", cmdKey)]
        let on = parts.filter(\.0)
        let key = e.keyCode == kVK_Space ? "Space" : (e.charactersIgnoringModifiers ?? "").uppercased()
        let d = UserDefaults.standard, keys = ["quickCode", "quickMods", "quickName"], old = keys.map { d.object(forKey: $0) }
        let name = (on.map(\.1) + [key]).joined(separator: " ")
        zip(keys, [Int(e.keyCode), on.reduce(0) { $0 | $1.2 }, name] as [Any]).forEach { d.set($1, forKey: $0) }
        registerQuick()
        if quickTaken {
            zip(keys, old).forEach { d.set($1, forKey: $0) }
            registerQuick()
            keyRefused = true  // Settings says so; the old shortcut still works
        } else { quickName = name; keyRefused = false }
    }
}

// A system-wide shortcut through the Carbon hot key call: no Accessibility permission needed.
@MainActor
enum HotKey {
    static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false

    static func register(code: UInt32, mods: UInt32) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        return RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x444C4E45, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// The floating quick add box. It takes typing without bringing Dateline to the front, and hides when you click elsewhere.
final class QuickPanel: NSPanel {
    static var shared: QuickPanel?

    static func toggle(_ app: AppState) {
        let p = shared ?? QuickPanel(app)
        shared = p
        if p.isVisible { p.orderOut(nil); return }
        if let s = NSScreen.main { p.setFrameTopLeftPoint(NSPoint(x: s.frame.midX - p.frame.width / 2, y: s.visibleFrame.maxY - s.frame.height * 0.22)) }
        app.quickText = ""; app.quickError = nil
        app.quickFocus += 1
        p.makeKeyAndOrderFront(nil)
    }

    init(_ app: AppState) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the box draws its own
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: QuickAddView(app: app, store: app.store).frame(width: 700, height: 560, alignment: .top))
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }
}
