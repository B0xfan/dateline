// What the window is showing and every action on it: views, the add box, selection, undo and the keyboard (B25).
import SwiftUI
import AppKit

enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", year = "Year" }

@MainActor
final class AppState: ObservableObject {
    let store: Store
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .day { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode"); reload() } }
    @Published var days: Int = { let d = UserDefaults.standard.integer(forKey: "weekDays"); return [3, 5, 7].contains(d) ? d : 7 }() { didSet { UserDefaults.standard.set(days, forKey: "weekDays"); reload() } }
    @Published var anchor: Date { didSet { reload() } }
    @Published var selectedID: String?
    @Published var panelOpen = false
    @Published var addText = ""
    @Published var addFocused = false
    @Published var addCalendarID: String?
    @Published var showShortcuts = false
    @Published var confirmDelete: Item?
    @Published var toast: Toast?
    @Published var error: String?
    @Published var now = Date()
    @Published var focusAdd = 0  // bumped to put the cursor in the add box
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

    // The days the day or week view shows. A 7 day week starts on Monday; a 3 or 5 day week starts on the day you are on.
    var visibleDays: [Date] {
        switch mode {
        case .day: return [anchor]
        case .week:
            if days == 7 { let m = startOfWeek(anchor); return (0..<7).map { addDays(m, $0) } }
            return (0..<days).map { addDays(anchor, $0) }
        case .month: return monthGrid(anchor)
        case .year: let y = cal.dateInterval(of: .year, for: anchor)!; return (0..<cal.range(of: .day, in: .year, for: anchor)!.count).map { addDays(y.start, $0) }
        }
    }

    var title: String {
        switch mode {
        case .day: return dateText(anchor, "EEEE, MMMM d, yyyy")
        case .week:
            let d = visibleDays, a = d.first!, b = d.last!
            if cal.isDate(a, equalTo: b, toGranularity: .month) { return dateText(a, "MMMM d") + " to " + dateText(b, "d, yyyy") }
            return dateText(a, "MMM d") + " to " + dateText(b, "MMM d, yyyy")
        case .month: return dateText(anchor, "MMMM yyyy")
        case .year: return dateText(anchor, "yyyy")
        }
    }

    // For a narrow window: no year, short month names.
    var shortTitle: String {
        switch mode {
        case .day: return dateText(anchor, "EEE, MMM d")
        case .week: return dateText(visibleDays.first!, "MMM d") + " to " + dateText(visibleDays.last!, "MMM d")
        case .month: return dateText(anchor, "MMM yyyy")
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

    func step(_ n: Int) {
        switch mode {
        case .day: anchor = addDays(anchor, n)
        case .week: anchor = addDays(anchor, n * days)
        case .month: anchor = cal.date(byAdding: .month, value: n, to: cal.date(from: cal.dateComponents([.year, .month], from: anchor))!)!
        case .year: anchor = cal.date(byAdding: .year, value: n, to: cal.dateInterval(of: .year, for: anchor)!.start)!
        }
    }

    func goToday() { anchor = cal.startOfDay(for: Date()) }

    func open(day: Date) { anchor = cal.startOfDay(for: day); mode = .day }

    // MARK: changes, each one undoable with Command Z

    var preview: Parsed { parseSentence(addText, now: Date()) }
    var addCalendar: CalInfo? { store.calendar(addCalendarID ?? store.defaultCalendarID ?? "") ?? store.calendars.first(where: \.writable) }

    // Return in the add box. `edit`: Tab, which adds it and opens its details.
    func commitAdd(edit: Bool = false) {
        guard !addText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        switch store.add(preview, calendarID: addCalendar?.id) {
        case .failure(let f): error = f.message
        case .success(let it):
            addText = ""; addFocused = false
            undoStack.append { [weak self] in self?.store.delete(it) }
            anchor = cal.startOfDay(for: it.start)
            reload()
            selectedID = store.items.first { $0.title == it.title && $0.start == it.start }?.id ?? it.id
            panelOpen = edit
        }
    }

    func newEvent(at start: Date) {
        var p = Parsed(start: start, end: start.addingTimeInterval(3600)); p.title = "New event"
        guard case .success(let it) = store.add(p, calendarID: addCalendar?.id) else { return }
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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.now = Date() } }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.key(e) ? nil : e
        }
    }

    // Returns true when the key was used. Letters are left alone while typing in a field.
    func key(_ e: NSEvent) -> Bool {
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
            if selectedID != nil { selectedID = nil; return true }
            return false
        }
        if typing || confirmDelete != nil || showShortcuts || error != nil { return false }
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
        case "1": mode = .day
        case "2": mode = .week
        case "3": mode = .month
        case "4": mode = .year
        case "?", "/": showShortcuts.toggle()
        default: return false
        }
        return true
    }
}
