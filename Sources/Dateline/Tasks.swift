// Phase 4: Apple Reminders on the calendar (approved Phase 4 mockups). Everything is saved in Reminders, so the phone sees each change.
// Sample mode keeps made-up tasks in memory and never asks for Reminders access.
import SwiftUI
import EventKit
import CoreLocation
import Contacts

struct ToDo: Identifiable, Equatable {
    var id: String
    var listID: String
    var title: String
    var due: Date? = nil  // the start of the day when there is no time
    var timed = false
    var done = false
    var notes = ""
    var remind = Remind.time
    var place: Spot? = nil
}

enum Remind: String, CaseIterable { case time = "At a time", arriving = "Arriving", leaving = "Leaving" }

struct Spot: Equatable {
    var name: String
    var lat: Double, lon: Double
    var radius: Double = 150
}

enum TaskGroup: String, CaseIterable { case overdue = "Overdue", today = "Today", week = "Next 7 days", later = "Later", none = "No date" }

// Where a task sits in the task list.
func taskGroup(_ t: ToDo, now: Date) -> TaskGroup {
    guard let d = t.due else { return .none }
    let today = cal.startOfDay(for: now), day = cal.startOfDay(for: d)
    if day < today { return t.done ? .today : .overdue }  // a done task is never overdue; it shows with today's until it drops off
    if day == today { return .today }
    return day <= addDays(today, 7) ? .week : .later
}

func isOverdue(_ t: ToDo, now: Date) -> Bool { !t.done && t.due.map { cal.startOfDay(for: $0) < cal.startOfDay(for: now) } == true }

// The day a task shows on in the calendar's Tasks row; nil when it has no date or shows in the grid at its time instead.
// Anything not done moves to today and stays there until it is ticked.
func taskRowDay(_ t: ToDo, now: Date) -> Date? {
    guard let d = t.due else { return nil }
    if isOverdue(t, now: now) { return cal.startOfDay(for: now) }
    return t.timed ? nil : cal.startOfDay(for: d)
}

// "Fri", or "Oct 3" when it is more than a week away from today.
func shortDay(_ d: Date, now: Date) -> String {
    abs(cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99) < 7 ? dateText(d, "EEE") : dateText(d, "MMM d")
}

extension Store {
    func requestReminders() {
        ek.requestFullAccessToReminders { ok, _ in
            Task { @MainActor in
                self.taskAccess = ok ? .granted : .denied
                guard ok else { return }
                self.reloadReminders()
                self.taskObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.ek, queue: .main) { _ in
                    Task { @MainActor in self.reloadReminders() }
                }
            }
        }
    }

    // Every unfinished reminder, plus the ones finished in the last week (for "Show done tasks" and ticked ones on the calendar).
    func reloadReminders() {
        guard taskAccess == .granted else { return }
        lists = ek.calendars(for: .reminder).sorted { $0.title < $1.title }
            .map { CalInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(nsColor: $0.color), writable: $0.allowsContentModifications) }
        taskFetch += 1
        let n = taskFetch, ek = ek
        let open = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let done = ek.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-7 * 86400), ending: nil, calendars: nil)
        ek.fetchReminders(matching: open) { a in
            let first = (a ?? []).map(Store.todo)
            ek.fetchReminders(matching: done) { b in
                let all = first + (b ?? []).map(Store.todo)
                DispatchQueue.main.async { MainActor.assumeIsolated { if n == self.taskFetch { self.todos = all } } }
            }
        }
    }

    nonisolated static func todo(_ r: EKReminder) -> ToDo {
        let c = r.dueDateComponents
        var t = ToDo(id: r.calendarItemIdentifier, listID: r.calendar.calendarIdentifier, title: r.title ?? "",
                     due: c.flatMap { cal.date(from: $0) }, timed: c?.hour != nil, done: r.isCompleted, notes: r.notes ?? "")
        if let a = r.alarms?.first(where: { $0.proximity != .none }), let l = a.structuredLocation, let g = l.geoLocation {
            t.remind = a.proximity == .enter ? .arriving : .leaving
            t.place = Spot(name: l.title ?? "", lat: g.coordinate.latitude, lon: g.coordinate.longitude, radius: l.radius == 0 ? 150 : l.radius)
        }
        return t
    }

    func taskList(_ id: String) -> CalInfo? { lists.first { $0.id == id } }

    // Adds a task to `listID` (nil = the Mac's default Reminders list).
    @discardableResult
    func addTask(_ t: ToDo, listID: String?) -> Result<ToDo, Failure> {
        var t = t
        if access == .sample || taskAccess == .sample {
            t.id = UUID().uuidString; t.listID = listID ?? lists.first?.id ?? ""
            todos.append(t); return .success(t)
        }
        guard taskAccess == .granted else { return .failure(Failure("Dateline can't see Reminders. Turn it on in System Settings, Privacy & Security, Reminders.")) }
        guard let c = listID.flatMap(ek.calendar(withIdentifier:)) ?? ek.defaultCalendarForNewReminders() else { return .failure(Failure("No Reminders list on this Mac can take new tasks.")) }
        let r = EKReminder(eventStore: ek)
        r.calendar = c
        apply(t, old: nil, to: r)
        do { try ek.save(r, commit: true) } catch { return .failure(Failure(error.localizedDescription)) }
        t = Store.todo(r)
        todos.append(t)  // shows at once; the change notification reloads
        return .success(t)
    }

    // Saves a changed task (tick, edits in the task details, a drop on the calendar).
    @discardableResult
    func updateTask(_ t: ToDo) -> Failure? {
        let old = todos.first { $0.id == t.id }
        if taskAccess == .sample {
            guard let i = todos.firstIndex(where: { $0.id == t.id }) else { return Failure("That task is gone.") }
            todos[i] = t; return nil
        }
        guard let r = ek.calendarItem(withIdentifier: t.id) as? EKReminder else { return Failure("That task is gone.") }
        if r.calendar.calendarIdentifier != t.listID, let c = ek.calendar(withIdentifier: t.listID) { r.calendar = c }
        apply(t, old: old, to: r)
        do { try ek.save(r, commit: true) } catch { reloadReminders(); return Failure(error.localizedDescription) }
        taskFetch += 1  // a read already running has the old copy; the change notification reads again
        if let i = todos.firstIndex(where: { $0.id == t.id }) { todos[i] = t }  // shows at once; the reload that follows confirms it
        return nil
    }

    // The task for undo of an add.
    @discardableResult
    func deleteTask(_ t: ToDo) -> Failure? {
        if taskAccess == .sample { todos.removeAll { $0.id == t.id }; return nil }
        guard let r = ek.calendarItem(withIdentifier: t.id) as? EKReminder else { return Failure("That task is gone.") }
        do { try ek.remove(r, commit: true) } catch { return Failure(error.localizedDescription) }
        todos.removeAll { $0.id == t.id }
        return nil
    }

    private func apply(_ t: ToDo, old: ToDo?, to r: EKReminder) {
        r.title = t.title
        r.notes = t.notes.isEmpty ? nil : t.notes
        if r.isCompleted != t.done { r.isCompleted = t.done }
        r.dueDateComponents = t.due.map { cal.dateComponents(t.timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: $0) }
        // Alerts are rewritten only when what they hang on changed, so alerts set on the phone (e.g. "1 day before") are kept otherwise.
        guard old.map({ ($0.due, $0.timed, $0.remind, $0.place) != (t.due, t.timed, t.remind, t.place) }) ?? true,
              t.remind == .time || t.place != nil else { return }  // Arriving/Leaving with no place yet: wait for the place
        (r.alarms ?? []).filter { ($0.proximity != .none && $0.structuredLocation?.geoLocation != nil) || $0.absoluteDate != nil }.forEach(r.removeAlarm)
        if t.remind == .time, t.timed, let d = t.due { r.addAlarm(EKAlarm(absoluteDate: d)) }
        if t.remind != .time, let p = t.place {
            let l = EKStructuredLocation(title: p.name)
            l.geoLocation = CLLocation(latitude: p.lat, longitude: p.lon)
            l.radius = p.radius
            let a = EKAlarm()
            a.structuredLocation = l
            a.proximity = t.remind == .arriving ? .enter : .leave
            r.addAlarm(a)
        }
    }

    // A typed place, found on the map (no location permission needed for this).
    func locate(_ text: String) async -> Spot? {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let l = try? await CLGeocoder().geocodeAddressString(q).first?.location else { return nil }
        return Spot(name: q, lat: l.coordinate.latitude, lon: l.coordinate.longitude)
    }

    // Home or Work from the "me" card in Contacts (asks for Contacts access the first time).
    func meAddress(work: Bool) async -> Result<Spot, Failure> {
        let cs = CNContactStore()
        guard (try? await cs.requestAccess(for: .contacts)) == true else { return .failure(Failure("Dateline can't see Contacts. Turn it on in System Settings, Privacy & Security, Contacts.")) }
        let keys = [CNContactPostalAddressesKey as CNKeyDescriptor]
        guard let me = try? cs.unifiedMeContactWithKeys(toFetch: keys) else { return .failure(Failure("No card is set as yours in Contacts (Card, Make This My Card).")) }
        guard let a = me.postalAddresses.first(where: { $0.label == (work ? CNLabelWork : CNLabelHome) })?.value else {
            return .failure(Failure("Your card in Contacts has no \(work ? "work" : "home") address."))
        }
        let text = CNPostalAddressFormatter.string(from: a, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
        guard var s = await locate(text) else { return .failure(Failure("Couldn't find your \(work ? "work" : "home") address on the map.")) }
        s.name = work ? "Work" : "Home"
        return .success(s)
    }

    // Made-up lists and tasks for the mockup's week (Monday `mon`).
    func loadSampleTasks(_ mon: Date) {
        taskAccess = .sample
        lists = [CalInfo(id: "r-main", title: "Reminders", account: "iCloud (sample)", color: Palette.work, writable: true),
                 CalInfo(id: "r-condo", title: "Condo", account: "iCloud (sample)", color: Palette.family, writable: true),
                 CalInfo(id: "r-groc", title: "Groceries", account: "iCloud (sample)", color: Palette.personal, writable: true)]
        func on(_ d: Int, _ h: Int? = nil) -> Date { h.map { cal.date(byAdding: .hour, value: $0, to: addDays(mon, d))! } ?? addDays(mon, d) }
        var n = 0
        func t(_ list: String, _ title: String, _ due: Date?, timed: Bool = false, done: Bool = false, remind: Remind = .time, place: Spot? = nil, notes: String = "") {
            n += 1
            todos.append(ToDo(id: "t\(n)", listID: list, title: title, due: due, timed: timed, done: done, notes: notes, remind: remind, place: place))
        }
        t("r-condo", "Pay condo fee", on(-3))
        t("r-main", "Renew car marchamo", on(-4))
        t("r-main", "Call the plumber", on(0))
        t("r-main", "Take out recycling", on(0, 11), timed: true)
        t("r-main", "Send invoice", on(0), done: true)
        t("r-condo", "Buy AC filter", on(1), remind: .arriving, place: Spot(name: "Ferretería Brenes, Tamarindo", lat: 10.299, lon: -85.839), notes: "Size 16 x 25 x 1, two of them")
        t("r-main", "Electrician", on(1, 10), timed: true)
        t("r-main", "Book dentist follow-up", on(2))
        t("r-condo", "Water plants at the condo", on(4))
        for g in ["Eggs", "Coffee", "Rice", "Limes"] { t("r-groc", g, nil) }
    }
}

// The Tasks row under the all-day row, one cell per day (approved mockup 1).
struct TaskRow: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let days: [Date]
    var body: some View {
        let list = app.calendarTodos
        HStack(alignment: .top, spacing: 0) {
            Text("tasks").font(.ui(11)).foregroundStyle(Palette.text3).frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8).padding(.top, 7)
            ForEach(days, id: \.self) { d in
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(list.filter { taskRowDay($0, now: app.now) == d }) { t in TaskChip(app: app, store: store, task: t) }
                }
                .padding(.horizontal, 6).padding(.vertical, 4).frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
            }
        }
        .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
    }
}

struct TaskChip: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let task: ToDo
    var body: some View {
        let late = isOverdue(task, now: app.now)
        HStack(spacing: 5) {
            TaskCircle(done: task.done, color: late ? Palette.now : store.taskList(task.listID)?.color ?? .gray) { app.toggle(task) }
            Text(task.title).strikethrough(task.done).foregroundStyle(task.done ? Palette.text3 : late ? Palette.now : Palette.text).lineLimit(1)
            if task.place != nil && task.remind != .time { Text("📍").font(.ui(10)) }
            if late, let d = task.due { Text("from " + shortDay(d, now: app.now)).font(.ui(10.5)).foregroundStyle(Palette.now.opacity(0.8)).lineLimit(1).layoutPriority(-1) }
            Spacer(minLength: 0)
        }
        .font(.ui(12))
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(app.openTaskID == task.id ? Palette.accentSoft : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.openTaskID = task.id }
        .draggable("task:" + task.id)
    }
}

struct TaskCircle: View {
    let done: Bool, color: Color
    var size: CGFloat = 13
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Circle().strokeBorder(color, lineWidth: 1.5).background(Circle().fill(done ? color : .clear))
                .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white).opacity(done ? 1 : 0))
                .frame(width: size, height: size).contentShape(Circle())
        }.buttonStyle(.plain).help(done ? "Mark as not done" : "Mark as done")
    }
}

// A reminder with a time, in the grid at that time. The dashed edge keeps it from looking like a meeting.
struct TaskBlock: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let task: ToDo
    var body: some View {
        let c = store.taskList(task.listID)?.color ?? .gray
        HStack(spacing: 5) {
            TaskCircle(done: task.done, color: c, size: 11) { app.toggle(task) }
            Text(task.due.map { timeText($0, short: true) } ?? "").foregroundStyle(Palette.text2)
            Text(task.title).fontWeight(.medium).strikethrough(task.done).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.ui(11.5)).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.win))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c, style: StrokeStyle(lineWidth: app.openTaskID == task.id ? 2 : 1.2, dash: [4, 3])))
        .contentShape(Rectangle())
        .onTapGesture { app.openTaskID = task.id }
        .draggable("task:" + task.id)
    }
}

// The task list on the right, opened with R (approved mockup 2).
struct TaskList: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @FocusState private var adding: Bool
    var body: some View {
        let filter = app.taskListFilter.flatMap(store.taskList)
        let list = app.shownTodos.filter { filter == nil || $0.listID == filter!.id }
        let groups = Dictionary(grouping: list) { taskGroup($0, now: app.now) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks").font(.ui(15, weight: .semibold))
                Spacer()
                Menu {
                    Button("All lists") { app.taskListFilter = nil }
                    ForEach(store.lists) { l in Button(l.title) { app.taskListFilter = l.id } }
                } label: { Text(filter?.title ?? "All lists") }.menuStyle(.borderlessButton).fixedSize()
                Button { app.tasksOpen = false } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Palette.text3)
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            if store.taskAccess == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dateline can't see Reminders yet").font(.ui(13, weight: .semibold))
                    Text("Turn on Dateline under Privacy & Security, Reminders, in System Settings, then reopen it.").foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!) }
                }.padding(16)
                Spacer()
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.accent)
                    TextField("Add a task: Call the bank Friday 3pm", text: $app.taskText).textFieldStyle(.plain).focused($adding).onSubmit { app.commitTask() }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(adding ? Palette.accent : Palette.line, lineWidth: adding ? 1.5 : 1))
                .padding(.horizontal, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(TaskGroup.allCases, id: \.self) { g in
                            if let rows = groups[g], !(g == .none && app.hideNoDate) {
                                HStack(spacing: 6) {
                                    Text(g.rawValue.uppercased()).font(.ui(11, weight: .semibold)).foregroundStyle(g == .overdue ? Palette.now : Palette.text3)
                                    Text("\(rows.count)").font(.ui(11)).foregroundStyle(Palette.text3)
                                }.padding(.top, 14).padding(.bottom, 4)
                                ForEach(rows.sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture, $0.title) < ($1.done ? 1 : 0, $1.due ?? .distantFuture, $1.title) }) { t in
                                    row(t, late: g == .overdue)
                                }
                            }
                        }
                        if list.isEmpty { Text("Nothing to do.").foregroundStyle(Palette.text3).padding(.top, 16) }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }
                HStack(spacing: 4) {
                    Button(app.showDone ? "Hide done tasks" : "Show done tasks") { app.showDone.toggle() }
                    Text("·")
                    Button(app.hideNoDate ? "Show no-date tasks" : "Hide no-date tasks") { app.hideNoDate.toggle() }
                }.buttonStyle(.plain).font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Palette.line.frame(height: 1) }
            }
        }
        .background(Palette.win)
    }

    func row(_ t: ToDo, late: Bool) -> some View {
        let l = store.taskList(t.listID)
        let sub = [l?.title ?? "", t.place.map { (t.remind == .arriving ? "when I arrive at " : t.remind == .leaving ? "when I leave " : "") + $0.name } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let right = t.due.map { taskGroup(t, now: app.now) == .today ? (t.timed ? timeText($0, short: true) : "") : shortDay($0, now: app.now) } ?? ""
        return HStack(alignment: .top, spacing: 8) {
            TaskCircle(done: t.done, color: late ? Palette.now : l?.color ?? .gray, size: 15) { app.toggle(t) }.padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(t.title).strikethrough(t.done).foregroundStyle(t.done ? Palette.text3 : Palette.text)
                    if t.place != nil && t.remind != .time { Text("📍").font(.ui(10)) }
                }
                Text(sub).font(.ui(11.5)).foregroundStyle(Palette.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(right).font(.ui(11.5)).foregroundStyle(late ? Palette.now : Palette.text3)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(app.openTaskID == t.id ? Palette.accentSoft : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture { app.openTaskID = t.id }
        .draggable("task:" + t.id)
    }
}

// Task details, with a reminder by place (approved mockup 3). Changes save when you leave a field.
struct TaskDetail: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var task: ToDo
    @State private var placeText = ""
    @State private var placeError: String?
    @State private var finding = false
    @FocusState private var field: String?

    var body: some View {
        let l = store.taskList(task.listID)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("TASK").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                    Spacer()
                    Button { commit(); app.openTaskID = nil } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 10)
                HStack(alignment: .top, spacing: 8) {
                    TaskCircle(done: task.done, color: l?.color ?? .gray, size: 16) { task.done.toggle(); commit() }.padding(.top, 3)
                    TextField("Title", text: $task.title, axis: .vertical).textFieldStyle(.plain).font(.ui(17, weight: .semibold))
                        .focused($field, equals: "title").onSubmit { commit() }
                }
                row("List") {
                    Menu {
                        ForEach(store.lists.filter(\.writable)) { k in Button(k.title) { task.listID = k.id; commit() } }
                    } label: { HStack(spacing: 6) { Circle().fill(l?.color ?? .gray).frame(width: 8, height: 8); Text(l?.title ?? "") } }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                row("Due") {
                    if let d = task.due {
                        DatePicker("", selection: Binding(get: { d }, set: { v in
                            task.due = task.timed ? cal.date(byAdding: cal.dateComponents([.hour, .minute], from: d), to: cal.startOfDay(for: v)) : cal.startOfDay(for: v); commit()
                        }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        if task.timed {
                            DatePicker("", selection: Binding(get: { d }, set: { task.due = $0; commit() }), displayedComponents: .hourAndMinute).labelsHidden()
                            Button("no time") { task.timed = false; task.due = cal.startOfDay(for: d); commit() }.buttonStyle(.plain).foregroundStyle(Palette.text3)
                        } else {
                            Button("add time") { task.timed = true; task.due = cal.date(byAdding: .hour, value: 9, to: cal.startOfDay(for: d)); commit() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }
                        Button { task.due = nil; task.timed = false; commit() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.text3).help("No due date")
                    } else {
                        Button("Add a date") { task.due = cal.startOfDay(for: app.now); commit() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                }
                section("REMIND ME")
                Seg(options: Remind.allCases.map(\.rawValue), selected: task.remind.rawValue, small: true) { task.remind = Remind(rawValue: $0)!; commit() }
                if task.remind == .time {
                    Text(task.timed ? "Your iPhone and Mac remind you at the due time." : "Add a time to the due date to get a reminder then.")
                        .font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.top, 8)
                } else {
                    Text("Place").foregroundStyle(Palette.text3).padding(.top, 12).padding(.bottom, 4)
                    HStack(spacing: 6) {
                        Text("📍")
                        TextField("Type a place or address", text: $placeText).textFieldStyle(.plain).focused($field, equals: "place").onSubmit { find() }
                        if finding { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
                    if let e = placeError { Text(e).font(.ui(11.5)).foregroundStyle(Palette.now).padding(.top, 4).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 6) {
                        Text("Within").foregroundStyle(Palette.text3)
                        Menu {
                            ForEach([100.0, 150, 300, 500, 1000], id: \.self) { m in Button(distance(m)) { task.place?.radius = m; commit() } }
                        } label: { Text(distance(task.place?.radius ?? 150)) }.menuStyle(.borderlessButton).fixedSize().disabled(task.place == nil)
                    }.padding(.top, 8)
                    HStack(spacing: 6) {
                        chip("🏠 Home") { mine(work: false) }
                        chip("💼 Work") { mine(work: true) }
                    }.padding(.top, 8)
                }
                section("NOTES")
                TextField("Add notes", text: $task.notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...10)
                    .focused($field, equals: "notes")
                Text("Saved in Apple Reminders, so your iPhone sees it too. A place reminder goes off on your iPhone when you get there, even with the Mac closed.")
                    .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
            .padding(16)
        }
        .background(Palette.win)
        .onAppear { placeText = task.place?.name ?? "" }
        .onChange(of: field) { old, _ in if old == "place" { find() } else { commit() } }
        .onDisappear { commit() }
        .onChange(of: store.todos) { _, list in
            // Changed elsewhere (the phone, a tick in the calendar, undo) while open.
            if field == nil, !finding, task.remind == .time || task.place != nil, let fresh = list.first(where: { $0.id == task.id }), fresh != task { task = fresh; placeText = fresh.place?.name ?? "" }
        }
    }

    func commit() { app.saveTask(task) }

    // Looks up the typed place; a place that can't be found leaves the old one in place.
    func find() {
        let text = placeText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != task.place?.name else { placeError = nil; return }
        finding = true
        Task {
            let s = await store.locate(text)
            finding = false
            guard var s else { placeError = "Couldn't find \"\(text)\" on the map. Try adding the town."; return }
            placeError = nil
            s.radius = task.place?.radius ?? 150
            task.place = s; commit()
        }
    }

    func mine(work: Bool) {
        finding = true
        Task {
            let r = await store.meAddress(work: work)
            finding = false
            switch r {
            case .failure(let f): placeError = f.message
            case .success(var s): placeError = nil; s.radius = task.place?.radius ?? 150; task.place = s; placeText = s.name; commit()
            }
        }
    }

    func distance(_ m: Double) -> String { m >= 1000 ? "\(Int(m / 1000)) km" : "\(Int(m)) m" }

    func chip(_ t: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(t).font(.ui(12)).padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Palette.lineSoft)).overlay(Capsule().strokeBorder(Palette.line))
        }.buttonStyle(.plain)
    }

    func section(_ t: String) -> some View {
        Text(t).font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 18).padding(.bottom, 6)
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 44, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 10)
    }
}
