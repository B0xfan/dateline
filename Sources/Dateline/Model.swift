// What the window is showing and every action on it: views, the add box, selection, undo and the keyboard (B25).
import SwiftUI
import AppKit

enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", quarter = "Quarter", year = "Year" }

// Each of these changes often and few views show it. Apart from AppState, a typed letter, a clock tick or an opened panel doesn't redraw the whole window.
@MainActor final class AddText: ObservableObject {
    @Published var text = ""
    @Published var focused = false
    @Published var calendarID: String?
    @Published var focusAsks = 0  // bumped to put the cursor in the add box
}
@MainActor final class Clock: ObservableObject { @Published var now = Date() }

// What's open around the calendar. MainView, the menus and a task's highlight draw from it; the rest just open and close things.
@MainActor final class Panels: ObservableObject {
    @Published var panelOpen = false { didSet { if panelOpen { openTaskID = nil } } }
    // Phase 4 tasks: the task list (R) and one task's details share the right side with the event details.
    @Published var tasksOpen = false { didSet { if tasksOpen { openTaskID = nil; panelOpen = false } } }
    @Published var openTaskID: String? { didSet { if openTaskID != nil { panelOpen = false } } }
    @Published var showShortcuts = false
    @Published var mapOpen = false  // Phase 5: the map of all places (P)
    @Published var subscribing = false  // Phase 7: the Subscribe window
    @Published var reviewing: String?  // the email open in the review window
    @Published var editingSet: CalSet?  // the set editor is open on this (a new one when it is not in the list yet)
    @Published var confirmDelete: Item?
    @Published var toast: AppState.Toast?
}

// The task list's own controls.
@MainActor final class TaskPanel: ObservableObject {
    @Published var text = ""
    @Published var filter: String?
    @Published var showDone = false
    @Published var hideNoDate = false
    // Reminders lists left unfolded in the task list's No date part; kept across restarts.
    @Published var openLists = Set(UserDefaults.standard.stringArray(forKey: "openTaskLists") ?? []) { didSet { if Look.saves { UserDefaults.standard.set(Array(openLists), forKey: "openTaskLists") } } }
}

// Redraws only what it wraps when `object` changes.
struct Watching<O: ObservableObject, V: View>: View {
    @ObservedObject var object: O
    @ViewBuilder let content: (O) -> V
    var body: some View { content(object) }
}

// For what shows the time of day: redraws on each clock tick, without its surroundings.
struct OnClock<V: View>: View {
    @ObservedObject var clock: Clock
    @ViewBuilder let content: (Date) -> V
    var body: some View { content(clock.now) }
}

@MainActor
final class AppState: ObservableObject {
    let store: Store
    let addBox = AddText(), clock = Clock(), panels = Panels(), taskPanel = TaskPanel(), quick = QuickBox()
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .day { didSet { if store.access != .sample { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }; reload() } }
    @Published var days: Int = { let d = UserDefaults.standard.integer(forKey: "weekDays"); return [3, 5, 7].contains(d) ? d : 7 }() { didSet { if Look.saves { UserDefaults.standard.set(days, forKey: "weekDays") }; reload() } }
    @Published var anchor: Date { didSet { reload(); if Look.saves && store.access != .sample { UserDefaults.standard.set(anchor, forKey: "anchor"); UserDefaults.standard.set(Date(), forKey: "anchorSaved") } } }
    @Published var selectedID: String?
    // The calendars sidebar on the left, hidden with the toolbar's first button or S (John 2026-10-28); kept across restarts.
    @Published var sidebarOpen = UserDefaults.standard.object(forKey: "sidebarOpen") as? Bool ?? true { didSet { if Look.saves { UserDefaults.standard.set(sidebarOpen, forKey: "sidebarOpen") } } }
    var addText: String { get { addBox.text } set { addBox.text = newValue } }
    @Published var drive: [String: Int] = [:]  // Phase 5: minutes of driving before each coming event with a place
    let trips = Trips()
    private var travelTimer: Timer?
    var alertCheck = Date()  // Phase 6: alerts are checked from here on
    private var alertTimer: Timer?
    var openMain: (() -> Void)?  // brings the main window back, also after it was closed
    let emails: EmailInbox  // Phase 9: forwarded emails waiting to become events
    @Published var look = 0  // bumped when a Look setting changes, to redraw everything
    @Published var error: String?
    // A new day changes what most views draw (today's mark, overdue tasks), so it redraws everything; a tick within the day doesn't.
    var now: Date {
        get { clock.now }
        set { if !cal.isDate(newValue, inSameDayAs: clock.now) { objectWillChange.send() }; clock.now = newValue }
    }
    @Published private var undoStack: [() -> Failure?] = []  // published: the Undo menu item greys out from it
    private var monitor: Any?
    private var timer: Timer?

    struct Toast: Equatable { let text: String; let calendar: String; let id = UUID() }

    init(store: Store, today: Date = Date()) {
        self.store = store
        emails = EmailInbox(sample: store.access == .sample)
        // Back to the date you were on, that same day; a new day opens on today, the view stays.
        let saved = store.access == .sample || !Look.saves ? nil : UserDefaults.standard.object(forKey: "anchorSaved") as? Date
        anchor = cal.startOfDay(for: saved.map { cal.isDate($0, inSameDayAs: today) } == true ? UserDefaults.standard.object(forKey: "anchor") as? Date ?? today : today)  // saved in another time zone, it isn't midnight here
        store.onError = { [weak self] in self?.error = $0 }
        now = today
        reload()
        if store.access != .sample { Assistant.shared.attach(self) }  // here, not when the window opens: Dateline also runs with its window closed
    }

    // The days the day or week view shows. Week views start on the day you are on, today unless you moved (John 2026-10-30). A 5 day week then skips days off.
    var visibleDays: [Date] {
        switch mode {
        case .day: return [anchor]
        case .week:
            let work = workDaysFromAnchor(1)
            if days == 5 && !work.isEmpty { return [anchor] + work.dropLast() }
            return (0..<(days == 3 ? 3 : 7)).map { addDays(anchor, $0) }  // no working days ticked: the 5 day week shows all 7
        case .month: return monthGrid(anchor)
        case .quarter:
            let q = quarterStart(anchor), a = startOfWeek(q), b = monthGrid(cal.date(byAdding: .month, value: 2, to: q)!).last!
            return (0...cal.dateComponents([.day], from: a, to: b).day!).map { addDays(a, $0) }
        case .year: let y = cal.dateInterval(of: .year, for: anchor)!; return (0..<cal.range(of: .day, in: .year, for: anchor)!.count).map { addDays(y.start, $0) }
        }
    }

    // The working days in the 7 days after (or, going back, before) the anchor, nearest first, so one of each.
    private func workDaysFromAnchor(_ direction: Int) -> [Date] { (1...7).map { addDays(anchor, direction * $0) }.filter(WorkWeek.isWorkDay) }

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
    var openTask: ToDo? { panels.openTaskID.flatMap { id in store.todos.first { $0.id == id } } }
    var sideOpen: Bool { panels.panelOpen || panels.tasksOpen || panels.openTaskID != nil }
    func closeSide() { panels.panelOpen = false; panels.tasksOpen = false; panels.openTaskID = nil }
    // Always has words: a toolbar subtitle that comes and goes changes the bar's height.
    var subtitle: String {
        let shown = store.calendars.allSatisfy { !store.hidden.contains($0.id) } ? "All calendars" : store.activeSet.map { $0.name + " set" } ?? "Some calendars"
        return ((mode == .year ? [] : [weekLabel]) + [shown]).joined(separator: " · ")
    }
    func newSet() { openMain?(); panels.editingSet = CalSet(name: "", calendars: store.calendars.map(\.id).filter { !store.hidden.contains($0) }) }
    var canUndo: Bool { !undoStack.isEmpty }
    // Tasks in lists that are ticked in the sidebar: for the list (done ones only with "Show done") and for the calendar (ticked ones stay, struck through).
    var calendarTodos: [ToDo] { store.todos.filter { !store.hiddenLists.contains($0.listID) } }
    var shownTodos: [ToDo] { calendarTodos.filter { taskPanel.showDone || !$0.done } }

    func step(_ n: Int) {
        switch mode {
        case .day: anchor = addDays(anchor, n)
        case .week:
            if days == 5, let next = workDaysFromAnchor(n).last { anchor = next }  // a whole page of working days, none skipped
            else { anchor = addDays(anchor, n * (days == 3 ? 3 : 7)) }
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

    // Past midnight, a view on today moves on with it, even if the app stayed open or the Mac slept for days. A view you paged elsewhere stays.
    func tick(_ date: Date) {
        let newDay = !cal.isDate(date, inSameDayAs: now)
        if newDay, anchor == cal.startOfDay(for: now) { anchor = cal.startOfDay(for: date) }
        now = date
        if newDay { store.refreshSoon() }  // "coming up" counts from today, and moving the view no longer rereads it
    }

    func open(day: Date) { anchor = cal.startOfDay(for: day); mode = .day }

    // MARK: changes, each one undoable with Command Z

    var preview: Parsed { parseSentence(addText, now: Date()) }
    var addCalendar: CalInfo? { calendar(for: preview, pick: nil).0 }

    var quickPreview: Parsed { let p = parseSentence(quick.text, now: Date()); return quick.pick.map { applying($0, to: p) } ?? p }
    var quickSuggestions: [Item] { quick.pick == nil ? suggestions(parseSentence(quick.text, now: Date()).title, in: store.past()) : [] }

    // The calendar a new event goes to, and why: a typed /code, then the picked past event, then the menu choice, then the Mac's default.
    func calendar(for p: Parsed, pick: Item?) -> (CalInfo?, String) {
        let writable = store.calendars.filter(\.writable)
        if let code = p.calendarCode {
            if let c = matchCalendar(code, in: writable, hidden: store.hidden) { return (c, "(from /\(code))") }
            return (calendar(for: Parsed(start: p.start, end: p.end), pick: pick).0, "(no calendar matches /\(code))")
        }
        if let pick, let c = store.calendar(pick.calendarID), c.writable { return (c, "(from past event)") }
        if addBox.calendarID == nil, let s = store.activeSet, let c = writable.first(where: { $0.id == s.defaultCalendar }) { return (c, "(\(s.name) set)") }
        let c = store.calendar(addBox.calendarID ?? store.defaultCalendarID ?? "") ?? writable.first
        return (c, c?.id == store.defaultCalendarID ? "(your default)" : "")
    }

    // Undo for something that isn't a calendar change (an email thrown away).
    func onUndo(_ f: @escaping () -> Void) { undoStack.append { f(); return nil } }

    // Something more for the last Undo to put back, once its own undo worked.
    func alsoOnUndo(_ f: @escaping () -> Void) {
        guard let u = undoStack.popLast() else { return }
        undoStack.append { let r = u(); if r == nil { f() }; return r }
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
        addText = ""; addBox.focused = false
        panels.panelOpen = edit
    }

    // Return in the quick add box.
    func commitQuick() {
        guard !quick.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard add(quickPreview, calendar: calendar(for: quickPreview, pick: quick.pick).0) != nil else { quick.error = error; error = nil; return }
        quick.text = ""; quick.error = nil
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
        panels.panelOpen = true
    }

    func save(_ new: Item) {
        guard let old = store.items.first(where: { $0.id == new.id }), old != new else { return }
        if let f = store.update(new) { error = f.message; return }
        undoStack.append { [weak self] in self?.store.update(old) }
    }

    func delete(_ it: Item) {
        if let f = store.delete(it) { error = f.message; return }
        if selectedID == it.id { selectedID = nil; panels.panelOpen = false }
        undoStack.append { [weak self] in
            guard let self, let back = self.store.restore(it) else { return Failure("Couldn't put the event back.") }
            self.selectedID = back.id
            return nil
        }
        panels.toast = Toast(text: it.title, calendar: store.calendar(it.calendarID)?.title ?? "")
        let t = panels.toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.panels.toast == t { self?.panels.toast = nil } }
    }

    // MARK: tasks

    func saveTask(_ new: ToDo) {
        guard let old = store.todos.first(where: { $0.id == new.id }), old != new else { return }
        if new.a4?.repeating == true, new.done != old.done {
            // The engine's tick is a toggle, and undo is offered only once it worked.
            if let f = store.a4Tick(old, then: { [weak self] in self?.undoStack.append { [weak self] in self?.store.a4Tick(old) } }) { error = f.message }
            return
        }
        if let f = store.updateTask(new) { error = f.message; return }
        undoStack.append { [weak self] in self?.store.updateTask(old) }
    }

    func toggle(_ t: ToDo) { var n = t; n.done.toggle(); saveTask(n) }

    // Return in the task list's add box: "Call the bank Friday 3pm" is due Friday at 3; no day or time means no due date.
    func commitTask() {
        let text = taskPanel.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let p = parseSentence(text, now: Date())
        // shortcut: with a day or time, the parser's title plus "at <place>" is kept, so short codes like /List are dropped; keep the whole text when that bites.
        let title = !p.dateGiven || p.title.isEmpty ? text : p.place.isEmpty ? p.title : "\(p.title) at \(p.place)"
        var t = ToDo(id: "", listID: "", title: title)
        if p.dateGiven { t.due = p.allDay ? cal.startOfDay(for: p.start) : p.start; t.timed = !p.allDay }
        switch store.addTask(t, listID: taskPanel.filter) {
        case .failure(let f): error = f.message
        case .success(let added):
            taskPanel.text = ""; undoStack.append { [weak self] in self?.store.deleteTask(added) }
            if added.due == nil { taskPanel.openLists.insert(added.listID) }  // so a new no-date task is not hidden in a folded list
        }
    }

    // A task dropped on the day grid takes that day and time.
    func drop(taskID: String, at time: Date) {
        guard var t = store.todos.first(where: { $0.id == taskID }) else { return }
        // A repeating A4 task's time belongs to its rule in A4, so here it takes only the day.
        if t.a4?.repeating == true { t.due = t.timed ? sameClock(t.due!, on: time) : cal.startOfDay(for: time) } else { if !t.timed { t.a4?.ring = true }; t.due = time; t.timed = true }
        saveTask(t)
    }

    func undo() {
        guard let u = undoStack.popLast() else { NSSound.beep(); return }
        panels.toast = nil
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
        let list = shownItems.filter { it in d.contains { it.end > $0 && it.start < addDays($0, 1) } }  // a 5 day week can skip days off
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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in if let self { self.tick(Date()); MenuBar.shared.update(self); self.store.reloadA4() } } }
        timer?.tolerance = 5  // slack lets the Mac bundle wake-ups
        if store.access != .sample { Here.shared.start() }
        travelTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in Here.shared.refresh(); self?.planTravel(); self?.store.refreshSubs(); self?.store.refreshAccounts() } }
        travelTimer?.tolerance = 30
        alertTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkAlerts() } }
        alertTimer?.tolerance = 2
        MenuBar.shared.update(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.key(e) ? nil : e
        }
    }

    // Returns true when the key was used. Letters are left alone while typing in a field.
    func key(_ e: NSEvent) -> Bool {
        if quick.recordingKey { return false }
        if e.window is QuickPanel { return quickKey(e) }
        if e.keyCode == 53 && panels.showShortcuts { panels.showShortcuts = false; return true }  // Esc on the shortcut list, which is its own window
        // The map is its own window too: Esc or a plain P closes it.
        if panels.mapOpen, e.keyCode == 53 || (e.charactersIgnoringModifiers == "p" && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty) { panels.mapOpen = false; return true }
        if e.window?.identifier?.rawValue.hasPrefix("main") != true { return false }  // Settings, or the main window is closed
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let responder = NSApp.keyWindow?.firstResponder
        let typing = responder is NSText || responder is NSDatePicker
        if e.keyCode == 48, addBox.focused, mods.isEmpty || mods == .shift { commitAdd(edit: true); return true }  // Tab in the add box
        if mods == .command && e.charactersIgnoringModifiers == "z" && !typing { undo(); return true }
        if e.keyCode == 53 {  // Escape
            if panels.showShortcuts { panels.showShortcuts = false; return true }
            if panels.confirmDelete != nil { panels.confirmDelete = nil; return true }
            if addBox.focused || !addText.isEmpty { addText = ""; addBox.focused = false; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            if panels.panelOpen { panels.panelOpen = false; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            if panels.openTaskID != nil { panels.openTaskID = nil; NSApp.keyWindow?.makeFirstResponder(nil); return true }
            if panels.tasksOpen { panels.tasksOpen = false; return true }
            if selectedID != nil { selectedID = nil; return true }
            return false
        }
        if typing || panels.confirmDelete != nil || panels.showShortcuts || panels.mapOpen || error != nil { return false }
        if mods == .command, let n = Int(e.charactersIgnoringModifiers ?? ""), (1...9).contains(n) { pickSet(n); return true }
        switch (e.keyCode, mods) {
        case (123, []): step(-1); return true
        case (124, []): step(1); return true
        case (126, []): selectNext(-1); return true
        case (125, []): selectNext(1); return true
        case (126, .option): nudge(-15); return true
        case (125, .option): nudge(15); return true
        case (36, []), (76, []): if selectedID != nil { panels.panelOpen = true; return true }; return false
        case (51, []), (117, []): if let s = selected { panels.confirmDelete = s; return true }; return false
        default: break
        }
        guard mods.subtracting(.shift).isEmpty else { return false }
        switch e.charactersIgnoringModifiers {
        case "n": addBox.focusAsks += 1
        case "t": goToday()
        case "r": panels.tasksOpen.toggle()
        case "p": panels.mapOpen = true
        case "s": sidebarOpen.toggle()
        case "1": mode = .day
        case "2": mode = .week
        case "3": mode = .month
        case "4": mode = .quarter
        case "5": mode = .year
        case "?", "/": panels.showShortcuts.toggle()
        default: return false
        }
        return true
    }

    // Keys in the quick add box: Esc closes, Tab uses the highlighted past event, Up / Down move between past events.
    func quickKey(_ e: NSEvent) -> Bool {
        let list = quickSuggestions
        switch e.keyCode {
        case 53: QuickPanel.shared?.orderOut(nil)
        case 48: if list.indices.contains(quick.sel) { quick.pick = list[quick.sel] }
        case 125, 126: if !list.isEmpty { quick.sel = (quick.sel + (e.keyCode == 125 ? 1 : list.count - 1)) % list.count }
        default: return false
        }
        return true
    }
}
