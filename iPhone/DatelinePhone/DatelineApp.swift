// The iPhone app (approved phone mockups, John 2026-11-04). Every non-screen part comes from DatelineCore, shared with the Mac.
import SwiftUI
import UIKit
import DatelineCore

/// The app stays upright, except Week, which turns sideways to show the whole week (John 2026-11-06).
final class PhoneDelegate: NSObject, UIApplicationDelegate {
    static var turns = false
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { Self.turns ? .allButUpsideDown : .portrait }
}

@main
struct DatelineApp: App {
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate
    @StateObject private var app: PhoneState

    init() {
        let made: PhoneState = MainActor.assumeIsolated {
            #if DEBUG
            if let demo = Demo.make() { return demo }  // debug builds only: sample calendars for the checks and pictures, never a real calendar
            #endif
            return PhoneState(store: Store(sample: false), today: Date(), sample: false)
        }
        _app = StateObject(wrappedValue: made)
    }

    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { RootView().environmentObject(app).environmentObject(app.store) }
            .onChange(of: phase) { if phase == .active { app.store.refreshSubs() } }  // subscribed calendars whose update time has come (the Mac checks every 5 minutes)
    }
}

struct Toast: Identifiable { let id = UUID(); var text: String }

/// What the screens share: which tab and view are showing, the day in view, and the open sheets.
@MainActor
final class PhoneState: ObservableObject {
    enum Mode: String, CaseIterable { case list = "List", day = "Day", week = "Week", month = "Month", quarter = "Quarter", year = "Year" }
    enum Tab: String, CaseIterable {
        case calendar = "Calendar", tasks = "Tasks", places = "Places", settings = "Settings"
    }

    let store: Store
    let sample: Bool  // sample calendars: tests and pictures
    @Published var today: Date
    @Published var mode: Mode = .list { didSet { listDay = nil; reload(); turnRule() } }  // the list is the main screen (approved mockup, John 2026-11-05)
    @Published var anchor: Date { didSet { listDay = nil; reload() } }
    @Published var listDay: Date?  // the day at the top of the list as it scrolls; the month title and week strip follow it (John 2026-11-06)
    @Published var tab: Tab = .calendar { didSet { turnRule() } }
    @Published var sideways = false { didSet { if sideways != oldValue { reload() } } }  // the phone is turned (only Week allows it)
    @Published var path: [String] = []  // event ids open on the calendar tab
    @Published var adding: String?  // the add sheet's starting text; nil = closed
    @Published var email: EmailFind?
    @Published var searching = false
    var searchStart = ""  // pictures only: the search box's starting text
    @Published var showUnlock = false
    @Published var settingsPath: [String] = []  // the settings pages open, e.g. ["accounts", "iCloud"]
    @Published var look = 0  // bumped when a Look choice changes here or arrives from the Mac, so the screens redraw in it
    var unlockNext = false  // an add refused by the ended trial: the unlock screen opens once the add sheet has closed
    @Published var problem: String?
    // shortcut: only the sample fills this; the phone does not run the shared drive planner (Trips) yet, which also schedules the leave alerts (a later step).
    @Published var drive: [String: Int] = [:]  // minutes of driving before an event with a place
    @Published var emails: [EmailFind] = []  // events found in emails opened in Dateline
    @Published var pickingEmail = false  // the Files picker for an email file
    private var readingEmail = false
    var emailNext = false  // "From an email file" on the add sheet: the picker opens once the sheet has closed
    var opened: [String: Item] = [:]  // events opened from outside the days in view (the map)
    var demoWidgets = false
    var demoScroll = false  // pictures only: the list scrolls halfway down, as a finger would
    var demoEdit = false  // pictures only: open the event's edit sheet
    var demoDrag: DragLive?  // pictures only: an event held mid-drag
    var demoHold = false  // pictures only: the Undo banner stays up
    @Published var addStart: Date?  // a tap on an empty time: the add sheet starts there
    @Published var toast: Toast?  // the Undo banner
    @Published var dragUntil = Date.distantPast  // the day-to-day swipe stays quiet while an event is held and for a moment after
    let undo = UndoStack()
    var demoTask: String?  // pictures only: which task sheet the Tasks tab opens (edit, edit-place, new, lists)

    init(store: Store, today: Date, sample: Bool) {
        self.store = store; self.today = today; self.sample = sample
        anchor = cal.startOfDay(for: today)
        reload()
    }

    /// The days the day and week views show: one, three from the anchor (the phone's week), or the whole week when turned sideways.
    var days: [Date] {
        if mode == .week && sideways { let s = startOfWeek(anchor); return (0..<7).map { addDays(s, $0) } }
        return (0..<(mode == .day ? 1 : 3)).map { addDays(anchor, $0) }
    }

    /// Lets the phone turn only while Week shows; leaving Week turns it back upright.
    private func turnRule() {
        let turns = tab == .calendar && mode == .week
        guard turns != PhoneDelegate.turns else { return }
        PhoneDelegate.turns = turns
        for case let s as UIWindowScene in UIApplication.shared.connectedScenes {
            s.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !turns { s.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        }
    }

    private var range: (Date, Date) {
        switch mode {
        case .list: return (startOfWeek(anchor), addDays(anchor, AgendaView.span))  // the week strip and the list's days
        case .day, .week: return (days[0], addDays(days[days.count - 1], 1))
        case .month: let g = monthGrid(anchor); return (g.first!, addDays(g.last!, 1))
        case .quarter: let q = quarterStart(anchor); return (monthGrid(q).first!, addDays(monthGrid(cal.date(byAdding: .month, value: 2, to: q)!).last!, 1))
        case .year: let y = cal.dateInterval(of: .year, for: anchor)!; return (y.start, y.end)
        }
    }

    func lookChanged() { look += 1 }

    func reload() { let r = range; store.show(from: addDays(r.0, -7), to: addDays(r.1, 7)) }

    func step(_ n: Int) {
        switch mode {
        case .list: anchor = addDays(anchor, 7 * n)
        case .day: anchor = addDays(anchor, n)
        case .week: anchor = addDays(anchor, (sideways ? 7 : 3) * n)
        case .month: anchor = cal.date(byAdding: .month, value: n, to: anchor)!
        case .quarter: anchor = cal.date(byAdding: .month, value: 3 * n, to: quarterStart(anchor))!
        case .year: anchor = cal.date(byAdding: .year, value: n, to: anchor)!
        }
    }

    func goToday() { anchor = cal.startOfDay(for: today) }

    func open(_ it: Item) { opened[it.id] = it; path.append(it.id) }
    func item(_ id: String) -> Item? { store.items.first { $0.id == id } ?? opened[id] }

    /// After a sheet closes: the unlock screen, when the ended trial refused what the sheet tried.
    func sheetClosed() { addStart = nil; if unlockNext { unlockNext = false; showUnlock = true }; if emailNext { emailNext = false; pickingEmail = true } }

    /// An email file opened in Dateline (from Files, "Open in", or the add sheet): read on the phone with Apple Intelligence,
    /// as on the Mac, then shown in the email sheet to check before adding. Nothing leaves the phone.
    // shortcut: the Mac's orange "guessed" outlines and its time note aren't shown in the phone sheet; add them if a guessed time slips through.
    func readEmail(_ url: URL) async {
        guard !readingEmail else { problem = "Dateline is still reading the last email. Try again in a moment."; return }  // one at a time, as on the Mac
        readingEmail = true; defer { readingEmail = false }
        say("Reading the email…"); defer { if toast?.text == "Reading the email…" { toast = nil } }  // cleared on every way out, failures too
        // Off the main thread: a big email's file and its parts take a moment. A copy iOS made for Dateline (its Inbox folder) is removed once read.
        let read = await Task.detached { () -> (Int, Mail?) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = size < 30_000_000 ? try? Data(contentsOf: url) : nil
            let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox").standardizedFileURL.path + "/"
            if url.standardizedFileURL.path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }  // only Dateline's own copy, never the user's file
            return (size, data.map(readMail))
        }.value
        guard let m = read.1 else { problem = read.0 >= 30_000_000 ? "This email is too big to read (over 30 MB)." : "Dateline couldn't open that email file."; return }
        let d = await readEvent(m, now: today)
        guard d.problem.isEmpty, let s = d.start else { problem = d.problem.isEmpty ? "Dateline couldn't find a date in that email." : d.problem; return }
        let f = EmailFind(from: m.fromName.isEmpty ? m.subject : m.fromName, quote: d.quotes.first ?? m.subject,
                          parsed: Parsed(title: d.title, start: s, end: d.end ?? s.addingTimeInterval(3600), allDay: d.allDay, place: d.place, lengthGiven: true, dateGiven: true, notes: d.notes))
        emails.insert(f, at: 0)
        // Opens over the calendar; an add or search sheet closes first. If another sheet is up, the envelope at the top keeps it.
        adding = nil; searching = false
        if email == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in if self?.email == nil { self?.email = f } } }
    }

    /// Where a new event goes: a typed /code, else the shown set's calendar, else the phone's default (as on the Mac).
    func calendarFor(_ p: Parsed, pick: String? = nil) -> CalInfo? {
        let writable = store.calendars.filter(\.writable)
        if let code = p.calendarCode, let c = matchCalendar(code, in: writable, hidden: store.hidden) { return c }  // a typed /code beats the menu
        if let pick, let c = writable.first(where: { $0.id == pick }) { return c }
        if let s = store.activeSet, let c = writable.first(where: { $0.id == s.defaultCalendar }) { return c }
        return writable.first { $0.id == store.defaultCalendarID } ?? writable.first
    }

    @discardableResult
    func add(_ p: Parsed, emoji: String = "", pick: String? = nil) -> Result<Item, Failure> {
        var r = store.add(p, calendarID: calendarFor(p, pick: pick)?.id)
        if case .success(var it) = r, !emoji.isEmpty {
            it.emoji = emoji
            if store.update(it) == nil { r = .success(it) }
        }
        if case .success(let it) = r {
            undo.push { [weak self] in self?.store.delete(it, series: true) }  // like the Mac: a repeating one goes whole
            say("Added \(it.shownTitle)")
        }
        return r
    }

    /// A saved change to an event (drag, stretch, edit): Undo puts `old` back.
    @discardableResult
    func change(_ new: Item, from old: Item, _ what: String) -> Failure? {
        if let f = store.update(new) { return f }
        undo.push { [weak self] in self?.store.update(old) }
        say("\(what) \(old.shownTitle)")
        return nil
    }

    /// Deletes one event; Undo puts it back as a copy. (A whole series has no undo, as on the Mac.)
    @discardableResult
    func delete(_ it: Item, series: Bool) -> Failure? {
        if let f = store.delete(it, series: series) { return f }
        guard !series else { return nil }
        undo.push { [weak self] in self?.store.restore(it) == nil ? Failure("Couldn't put the event back.") : nil }
        say("Deleted \(it.shownTitle)")
        return nil
    }

    func say(_ text: String) {
        let t = Toast(text: text)
        toast = t
        UIAccessibility.post(notification: .announcement, argument: text)
        guard !demoHold else { return }
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if toast?.id == t.id { toast = nil } }
    }

    /// The Undo button and shake to undo.
    func undoLast() {
        toast = nil
        if let f = undo.undo() { problem = f.message }
    }

    func toggle(_ t: ToDo) { var n = t; n.done.toggle(); save(n) }

    /// Left swipe on a task: the same time, `days` after today.
    func moveTask(_ t: ToDo, days: Int) {
        var n = t
        let day = addDays(cal.startOfDay(for: today), days)
        n.due = t.due.map { t.timed ? sameClock($0, on: day) : day } ?? day
        save(n)
    }

    /// A task dropped on an hour (as on the Mac): it gets that day and time. A repeating A4 task's time belongs to its rule, so it takes only the day.
    @discardableResult func drop(taskID: String, at time: Date) -> Bool {
        guard let t = store.todos.first(where: { $0.id == taskID }) else { return false }
        var n = t
        if t.a4?.repeating == true { n.due = t.timed ? sameClock(t.due!, on: time) : cal.startOfDay(for: time) } else { if !t.timed { n.a4?.ring = true }; n.due = time; n.timed = true }
        guard n != t else { return false }
        if let f = store.updateTask(n) { if store.trialOver { showUnlock = true } else { problem = f.message }; return false }
        undo.push { [weak self] in self?.store.updateTask(t) }
        say("Moved \(t.title) to \(n.timed ? timeText(n.due!) : dateText(n.due!, "EEEE, MMM d"))")
        return true
    }

    private func save(_ t: ToDo) { if let f = store.updateTask(t) { problem = f.message } }

    /// The Mac's quick-add rules for a task: a day or time in the sentence becomes its due date.
    func addTask(_ text: String, listID: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let p = parseSentence(text, now: today)
        let title = !p.dateGiven || p.title.isEmpty ? text : p.place.isEmpty ? p.title : "\(p.title) at \(p.place)"
        var t = ToDo(id: "", listID: "", title: title)
        if p.dateGiven { t.due = p.allDay ? cal.startOfDay(for: p.start) : p.start; t.timed = !p.allDay }
        if case .failure(let f) = store.addTask(t, listID: listID) { problem = f.message }
    }

    // Weather and sun for a day header, where Settings says (the town, else where the phone is).
    func wx(_ d: Date) -> WxDay? { WeatherPrefs.on ? headerSpot().flatMap { WeatherStore.shared.forecast($0)?.days[wxDayKey(d)] } : nil }
    func sun(_ d: Date) -> (rise: Date, set: Date)? { WorkWeek.sun ? headerSpot().flatMap { sunTimes(d, at: $0) } : nil }
}

/// An event read out of an email file opened in Dateline.
struct EmailFind: Identifiable {
    let id = UUID()
    var from: String, quote: String
    var parsed: Parsed, emoji = "", alert = ""
}
