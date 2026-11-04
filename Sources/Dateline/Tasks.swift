// Phase 4: Apple Reminders on the calendar (approved Phase 4 mockups). Everything is saved in Reminders, so the phone sees each change.
import SwiftUI
import CoreLocation
import Contacts
import DatelineCore

// The Tasks row under the all-day row, one cell per day (approved mockup 1).
struct TaskRow: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let days: [Date]
    var body: some View {
        let list = app.calendarTodos
        HStack(alignment: .top, spacing: 0) {
            Text("tasks").font(.ui(11)).foregroundStyle(Palette.text3).frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8).padding(.top, 8)
            ForEach(days, id: \.self) { d in
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(list.filter { taskRowDay($0, now: app.now) == d }) { t in TaskChip(app: app, store: store, task: t) }
                }
                .padding(.horizontal, 8).padding(.vertical, 4).frame(minWidth: 0, maxWidth: .infinity, minHeight: 28, alignment: .topLeading).clipped()
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
        HStack(spacing: 4) {
            TaskCircle(done: task.done, color: late ? Palette.now : store.taskList(task.listID)?.color ?? .gray) { app.toggle(task) }
            Text(task.title).strikethrough(task.done).foregroundStyle(task.done ? Palette.text3 : late ? Palette.now : Palette.text).lineLimit(1)
            if task.place != nil && task.remind != .time { Text("📍").font(.ui(10)) }
            if late, let d = task.due { Text("from " + shortDay(d, now: app.now)).font(.ui(11)).foregroundStyle(Palette.now.opacity(0.8)).lineLimit(1).layoutPriority(-1) }
            Spacer(minLength: 0)
        }
        .font(.ui(12))
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(Watching(object: app.panels) { p in RoundedRectangle(cornerRadius: 4).fill(p.openTaskID == task.id ? Palette.accentSoft : .clear) })
        .contentShape(Rectangle())
        .onTapGesture { app.panels.openTaskID = task.id }
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
        HStack(spacing: 4) {
            TaskCircle(done: task.done, color: c, size: 11) { app.toggle(task) }
            Text(task.due.map { timeText($0, short: true) } ?? "").foregroundStyle(Palette.text2)
            Text(task.title).fontWeight(.medium).strikethrough(task.done).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.ui(12)).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.win))
        .overlay(Watching(object: app.panels) { p in RoundedRectangle(cornerRadius: 8).strokeBorder(c, style: StrokeStyle(lineWidth: p.openTaskID == task.id ? 2 : 1.2, dash: [4, 3])) })
        .contentShape(Rectangle())
        .onTapGesture { app.panels.openTaskID = task.id }
        .draggable("task:" + task.id)
    }
}

// The task list on the right, opened with R (approved mockup 2).
struct TaskList: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @ObservedObject var panel: TaskPanel
    @FocusState private var adding: Bool
    @State private var showAll: Set<String> = []  // open lists showing past their first 20 tasks
    var body: some View {
        let filter = panel.filter.flatMap(store.taskList)
        let list = app.shownTodos.filter { filter == nil || $0.listID == filter!.id }
        let groups = Dictionary(grouping: list) { taskGroup($0, now: app.now) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks").font(.ui(15, weight: .semibold))
                Spacer()
                Menu {
                    Button("All lists") { panel.filter = nil }
                    ForEach(store.lists) { l in Button(l.title) { panel.filter = l.id } }
                } label: { Text(filter?.title ?? "All lists") }.menuStyle(.borderlessButton).fixedSize()
                Button { app.panels.tasksOpen = false } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.accessibilityLabel("Close").buttonStyle(.plain).foregroundStyle(Palette.text3)
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            if store.taskAccess == .denied && !store.todos.contains(where: { $0.a4 != nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dateline can't see Reminders yet").font(.ui(13, weight: .semibold))
                    Text("Turn on Dateline under Privacy & Security, Reminders, in System Settings, then reopen it.").foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!) }
                }.padding(16)
                Spacer()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.accent)
                    TextField("Add a task: Call the bank Friday 3pm", text: $panel.text).textFieldStyle(.plain).focused($adding).onSubmit { app.commitTask() }
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(adding ? Palette.accent : Palette.line, lineWidth: adding ? 1.5 : 1))
                .padding(.horizontal, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(TaskGroup.allCases, id: \.self) { g in
                            if let rows = groups[g], !(g == .none && panel.hideNoDate) {
                                HStack(spacing: 8) {
                                    Text(g.rawValue.uppercased()).font(.ui(11, weight: .semibold)).foregroundStyle(g == .overdue ? Palette.now : Palette.text3)
                                    Text("\(rows.count)").font(.ui(11)).foregroundStyle(Palette.text3)
                                }.padding(.top, 12).padding(.bottom, 4)
                                if g == .none && filter == nil {
                                    folded(rows)
                                } else {
                                    ForEach(rows.sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture, $0.title) < ($1.done ? 1 : 0, $1.due ?? .distantFuture, $1.title) }) { t in
                                        row(t, late: g == .overdue, showList: filter == nil)
                                    }
                                }
                            }
                        }
                        if list.isEmpty { Text("Nothing to do.").foregroundStyle(Palette.text3).padding(.top, 16) }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }
                HStack(spacing: 4) {
                    Button(panel.showDone ? "Hide done tasks" : "Show done tasks") { panel.showDone.toggle() }
                    Text("·")
                    Button(panel.hideNoDate ? "Show no-date tasks" : "Hide no-date tasks") { panel.hideNoDate.toggle() }
                }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Palette.line.frame(height: 1) }
            }
        }
        .background(Palette.win)
    }

    // No-date tasks with every list shown: each list folds, and remembers whether it was left open.
    func folded(_ rows: [ToDo]) -> some View {
        ForEach(noDateLists(rows) { store.taskList($0)?.title ?? "Other" }, id: \.id) { l in
            let info = store.taskList(l.id), open = panel.openLists.contains(l.id), all = showAll.contains(l.id)
            Button {
                if open { panel.openLists.remove(l.id); showAll.remove(l.id) } else { panel.openLists.insert(l.id) }
            } label: { HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.ui(10, weight: .semibold)).foregroundStyle(Palette.text3)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                RoundedRectangle(cornerRadius: 4).fill(info?.color ?? .gray).frame(width: 12, height: 12)
                Text(info?.title ?? "Other").lineLimit(1)
                Spacer(minLength: 4)
                Text("\(l.rows.count)").font(.ui(12)).foregroundStyle(Palette.text3)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityValue(open ? "open" : "folded")
            .help(open ? "Fold this list" : "Show this list's tasks")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(all ? l.rows : Array(l.rows.prefix(20))) { t in row(t, late: false, showList: false) }
                    if l.rows.count > 20 && !all {
                        Button("Show all \(l.rows.count)") { showAll.insert(l.id) }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Palette.accent).padding(.vertical, 4)
                    }
                }.padding(.leading, 24).padding(.bottom, 4)
            }
        }
    }

    func row(_ t: ToDo, late: Bool, showList: Bool = true) -> some View {
        let l = store.taskList(t.listID)
        let sub = [showList ? l?.title ?? "" : "", t.place.map { (t.remind == .arriving ? "when I arrive at " : t.remind == .leaving ? "when I leave " : "") + $0.name } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let right = t.due.map { taskGroup(t, now: app.now) == .today ? (t.timed ? timeText($0, short: true) : "") : shortDay($0, now: app.now) } ?? ""
        return HStack(alignment: .top, spacing: 8) {
            TaskCircle(done: t.done, color: late ? Palette.now : l?.color ?? .gray, size: 15) { app.toggle(t) }.padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(t.title).strikethrough(t.done).foregroundStyle(t.done ? Palette.text3 : Palette.text)
                    if t.place != nil && t.remind != .time { Text("📍").font(.ui(10)) }
                }
                if !sub.isEmpty { Text(sub).font(.ui(12)).foregroundStyle(Palette.text3).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Text(right).font(.ui(12)).foregroundStyle(late ? Palette.now : Palette.text3)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(Watching(object: app.panels) { p in RoundedRectangle(cornerRadius: 8).fill(p.openTaskID == t.id ? Palette.accentSoft : .clear) })
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onTapGesture { app.panels.openTaskID = t.id }
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
    @AppStorage("taskNotesHeight") private var notesHeight = 100.0  // set by dragging the grip under the notes; kept across restarts
    @State private var dragHeight: Double?  // the height while the grip is being dragged; saved once on letting go

    var body: some View {
        let l = store.taskList(task.listID)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("TASK").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                    Spacer()
                    Button { commit(); app.panels.openTaskID = nil } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.accessibilityLabel("Close").buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 8)
                HStack(alignment: .top, spacing: 8) {
                    TaskCircle(done: task.done, color: l?.color ?? .gray, size: 16) { task.done.toggle(); commit() }.padding(.top, 4)
                    TextField("Title", text: $task.title, axis: .vertical).textFieldStyle(.plain).font(.ui(17, weight: .semibold))
                        .focused($field, equals: "title").onSubmit { commit() }
                }
                row("List") {
                    Menu {
                        ForEach(store.lists.filter(\.writable)) { k in Button(k.title) { task.listID = k.id; commit() } }
                    } label: { HStack(spacing: 8) { Circle().fill(l?.color ?? .gray).frame(width: 8, height: 8); Text(l?.title ?? "") } }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                row("Due") {
                    if let d = task.due {
                        DatePicker("", selection: Binding(get: { d }, set: { v in
                            task.due = task.timed ? sameClock(d, on: v) : cal.startOfDay(for: v); commit()
                        }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        if task.timed {
                            DatePicker("", selection: Binding(get: { d }, set: { task.due = $0; commit() }), displayedComponents: .hourAndMinute).labelsHidden()
                        } else {
                            Button("add time") { task.timed = true; task.due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d); commit() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }
                        Button { task.due = nil; task.timed = false; commit() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear due").buttonStyle(.plain).foregroundStyle(Palette.text3).help("No due date")
                    } else {
                        Button("Add a date") { task.due = cal.startOfDay(for: app.now); commit() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                }
                section("REMIND ME")
                Seg(options: Remind.allCases.map(\.rawValue), selected: task.remind.rawValue, small: true) { task.remind = Remind(rawValue: $0)!; commit() }
                if task.remind == .time {
                    Text(task.timed ? "Your iPhone and Mac remind you at the due time." : "Add a time to the due date to get a reminder then.")
                        .font(.ui(12)).foregroundStyle(Palette.text3).padding(.top, 8)
                } else {
                    Text("Place").foregroundStyle(Palette.text3).padding(.top, 12).padding(.bottom, 4)
                    HStack(spacing: 8) {
                        Text("📍")
                        TextField("Type a place or address", text: $placeText).textFieldStyle(.plain).focused($field, equals: "place").onSubmit { find() }
                        if finding { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                    if let e = placeError { Text(e).font(.ui(12)).foregroundStyle(Palette.now).padding(.top, 4).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 8) {
                        Text("Within").foregroundStyle(Palette.text3)
                        Menu {
                            ForEach([100.0, 150, 300, 500, 1000], id: \.self) { m in Button(distance(m)) { task.place?.radius = m; commit() } }
                        } label: { Text(distance(task.place?.radius ?? 150)) }.menuStyle(.borderlessButton).fixedSize().disabled(task.place == nil)
                    }.padding(.top, 8)
                    HStack(spacing: 8) {
                        chip("🏠 Home") { mine(work: false) }
                        chip("💼 Work") { mine(work: true) }
                    }.padding(.top, 8)
                }
                section("NOTES")
                TextEditor(text: $task.notes).font(.ui(13)).scrollContentBackground(.hidden).padding(.horizontal, 4).padding(.vertical, 4)
                    .focused($field, equals: "notes")
                    .frame(height: dragHeight ?? notesHeight)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(field == "notes" ? Palette.accent : Palette.line, lineWidth: field == "notes" ? 1.5 : 1))
                    .overlay(alignment: .topLeading) {
                        if task.notes.isEmpty { Text("Add notes").font(.ui(13)).foregroundStyle(Palette.text3).padding(.leading, 8).padding(.top, 4).allowsHitTesting(false) }
                    }
                // The grip sits under the box, not on it, so a drag never lands in the text. Drag down for taller notes, up to shrink them.
                Capsule().fill(Palette.text3.opacity(0.5)).frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 16).contentShape(Rectangle())
                    .onHover { h in if dragHeight == nil { (h ? NSCursor.resizeUpDown : NSCursor.arrow).set() } }  // set, not push/pop, as in the grid
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)  // global: the grip moves with the box, so its own space would jitter
                        .onChanged { v in dragHeight = min(max(notesHeight + v.translation.height, 50), 600) }
                        .onEnded { _ in if let h = dragHeight { notesHeight = h }; dragHeight = nil; NSCursor.arrow.set() })
                    .help("Drag to resize the notes")
                Text("Saved in Apple Reminders, so your iPhone sees it too. A place reminder goes off on your iPhone when you get there, even with the Mac closed.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
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
            Text(t).font(.ui(12)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Palette.lineSoft)).overlay(Capsule().strokeBorder(Palette.line))
        }.buttonStyle(.plain)
    }

    func section(_ t: String) -> some View {
        Text(t).font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 16).padding(.bottom, 4)
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 44, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 8)
    }
}

