// The Tasks tab (approved mockup "Tasks"): Reminders grouped like the Mac's task list. Swipe right to finish, left to move to tomorrow.
import SwiftUI
import DatelineCore

struct TasksView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var asking = false
    @State private var choosing = false
    @State private var editing: ToDo?

    var body: some View {
        let now = app.today
        let shown = store.todos.filter { !store.hiddenLists.contains($0.listID) }
        let groups = TaskGroup.allCases.map { g in
            (g, shown.filter { taskGroup($0, now: now) == g }.sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture, $0.title) < ($1.done ? 1 : 0, $1.due ?? .distantFuture, $1.title) })
        }.filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                Button { choosing = true } label: {
                    Image(systemName: "list.bullet").font(.title3.weight(.semibold)).foregroundStyle(T.tint).frame(width: 44, height: 44).background(T.bg2, in: Circle())
                }
                .accessibilityLabel("Show or hide lists")
                Button { asking = true } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(T.tint).frame(width: 44, height: 44).background(T.bg2, in: Circle())
                }
                .accessibilityLabel("Add a task")
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Text("Tasks").font(.title.bold()).padding(.horizontal, 16)
            Text("From your Reminders lists").font(.footnote).foregroundStyle(T.text2).padding(.horizontal, 16)
            List {
                if store.taskAccess == .denied {
                    Text("Dateline can't see Reminders. Turn it on in Settings, Privacy & Security, Reminders.").foregroundStyle(T.text2).listRowBackground(T.bg2)
                } else if groups.isEmpty {
                    Text("No tasks.").foregroundStyle(T.text2).listRowBackground(T.bg2)
                }
                ForEach(groups, id: \.0) { pair in
                    Section(pair.0.rawValue) { ForEach(pair.1) { t in TaskRow(t: t) { editing = t } } }
                }
                Section {} footer: { Text("Swipe right to finish, left to move to tomorrow.") }
            }
            .listStyle(.insetGrouped).listSectionSpacing(.compact).scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
        }
        .background(T.bg)
        .sheet(isPresented: $asking) { NewTaskSheet().environmentObject(app).environmentObject(store) }
        .sheet(isPresented: $choosing) { ListsSheet().environmentObject(store) }
        .sheet(item: $editing) { TaskEditSheet($0).environmentObject(app).environmentObject(store) }
        .onAppear {
            guard let d = app.demoTask else { return }
            app.demoTask = nil
            switch d {
            case "new": asking = true
            case "lists": choosing = true
            default: editing = store.todos.first { $0.title == (d == "edit" ? "Call the plumber" : "Buy AC filter") }
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let t: ToDo
    var edit: () -> Void = {}

    var body: some View {
        let c = store.taskList(t.listID)?.color ?? T.tint
        let late = isOverdue(t, now: app.today)
        HStack(spacing: 12) {
            Button { app.toggle(t) } label: {
                Circle().strokeBorder(c, lineWidth: 2).background(Circle().fill(t.done ? c : .clear)).frame(width: 22, height: 22)
                    .frame(width: 30, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.done ? "Not done: \(t.title)" : "Finish \(t.title)")
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).strikethrough(t.done).foregroundStyle(t.done ? T.text2 : T.text)
                    Text(subtitle(late)).font(.footnote).foregroundStyle(late ? T.late : T.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("Opens the task")
        }
        .font(.callout).frame(minHeight: 48)
        .listRowBackground(T.bg2)
        .swipeActions(edge: .leading) { Button(t.done ? "Not done" : "Done") { app.toggle(t) }.tint(.green) }
        .swipeActions(edge: .trailing) { Button("Tomorrow") { app.moveTask(t, days: 1) }.tint(.orange) }
    }

    private func subtitle(_ late: Bool) -> String {
        var parts: [String] = []
        if late, let d = t.due { parts.append(shortDay(d, now: app.today)) }
        parts.append(store.taskList(t.listID)?.title ?? "")
        if let p = t.place { parts.append("\(t.remind == .leaving ? "leaving" : "at") \(p.name)") }
        if t.timed, let d = t.due { parts.append(timeText(d, short: true)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The Mac task panel's rules for the due date and time, kept apart so the self-check can run them.
enum TaskEdit {
    /// The switch for a due date: on gives today; off clears the time too.
    static func hasDue(_ t: ToDo, _ on: Bool, now: Date) -> ToDo {
        var n = t
        if on { n.due = cal.startOfDay(for: now) } else { n.due = nil; n.timed = false }
        return n
    }
    /// A new day keeps the clock time of a timed task.
    static func date(_ t: ToDo, _ v: Date) -> ToDo {
        var n = t
        n.due = t.timed ? sameClock(t.due ?? v, on: v) : cal.startOfDay(for: v)
        return n
    }
    /// The time switch: on gives 9 AM on the due day; off goes back to the whole day.
    static func hasTime(_ t: ToDo, _ on: Bool) -> ToDo {
        var n = t
        guard let d = t.due else { return n }
        n.timed = on
        n.due = on ? cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) : cal.startOfDay(for: d)
        return n
    }
}

struct TaskEditSheet: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let original: ToDo
    @State private var task: ToDo
    @State private var placeText: String
    @State private var finding = false
    @State private var problem: String?
    @State private var confirmDelete = false

    init(_ t: ToDo) { original = t; _task = State(initialValue: t); _placeText = State(initialValue: t.place?.name ?? "") }

    private var writable: [CalInfo] { store.lists.filter(\.writable) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $task.title, axis: .vertical).font(.title3.weight(.semibold))
                    Picker("List", selection: $task.listID) {
                        ForEach(Array(Set(writable.map(\.account))).sorted(), id: \.self) { acct in
                            Section(acct) { ForEach(writable.filter { $0.account == acct }) { k in Text(k.title).tag(k.id) } }
                        }
                    }
                }
                Section("Due") {
                    Toggle("Due date", isOn: Binding(get: { task.due != nil }, set: { task = TaskEdit.hasDue(task, $0, now: app.today) }))
                    if let d = task.due {
                        DatePicker("Date", selection: Binding(get: { d }, set: { task = TaskEdit.date(task, $0) }), displayedComponents: .date)
                        Toggle("Time", isOn: Binding(get: { task.timed }, set: { task = TaskEdit.hasTime(task, $0) }))
                        if task.timed { DatePicker("At", selection: Binding(get: { d }, set: { task.due = $0 }), displayedComponents: .hourAndMinute) }
                    }
                }
                Section {
                    Picker("Remind me", selection: $task.remind) { ForEach(Remind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    if task.remind == .time {
                        Text(task.timed ? "Your iPhone and Mac remind you at the due time." : "Add a time to the due date to get a reminder then.").font(.footnote).foregroundStyle(T.text2)
                    } else {
                        TextField("Type a place or address", text: $placeText).submitLabel(.search).onSubmit { Task { _ = await find() } }
                        if finding { ProgressView() }
                        Picker("Within", selection: Binding(get: { task.place?.radius ?? 150 }, set: { task.place?.radius = $0 })) {
                            ForEach([100.0, 150, 300, 500, 1000], id: \.self) { Text($0 >= 1000 ? "\(Int($0 / 1000)) km" : "\(Int($0)) m").tag($0) }
                        }.disabled(task.place == nil)
                        HStack(spacing: 10) {
                            Button("Home") { mine(work: false) }.buttonStyle(.bordered)
                            Button("Work") { mine(work: true) }.buttonStyle(.bordered)
                        }.buttonStyle(.borderless)
                    }
                } header: { Text("Remind me") } footer: {
                    Text("Saved in Apple Reminders, so your Mac sees it too. A place reminder goes off on your iPhone when you get there.")
                }
                Section("Notes") { TextEditor(text: $task.notes).frame(minHeight: 110).accessibilityLabel("Notes") }
                Section { Button("Delete task", role: .destructive) { confirmDelete = true } }
            }
            .navigationTitle("Edit task").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { Task { await save() } }.fontWeight(.semibold) }
            }
            .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
            .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete task", role: .destructive) {
                    if let f = store.deleteTask(original) { problem = f.message } else { dismiss() }
                }
            }
        }
    }

    /// Looks up the typed place; one that can't be found leaves the old place and says so.
    private func find() async -> Bool {
        let text = placeText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != task.place?.name else { return true }
        finding = true; defer { finding = false }
        guard var s = await store.locate(text) else { problem = "Couldn't find \"\(text)\" on the map. Try adding the town."; return false }
        s.radius = task.place?.radius ?? 150; task.place = s
        return true
    }

    private func mine(work: Bool) {
        finding = true
        Task {
            defer { finding = false }
            switch await store.meAddress(work: work) {
            case .failure(let f): problem = f.message
            case .success(var s): s.radius = task.place?.radius ?? 150; task.place = s; placeText = s.name
            }
        }
    }

    private func save() async {
        if task.remind != .time, !(await find()) { return }
        var n = task
        n.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.title : task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if n != original, let f = store.updateTask(n) { problem = f.message; return }
        dismiss()
    }
}

/// A new task: typed the way you'd say it, with the list to put it in.
struct NewTaskSheet: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pick: String?  // nil = the phone's default list, as on the Mac
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Call the plumber tomorrow", text: $text).focused($focused).submitLabel(.done).onSubmit(add)
                } footer: { Text("Type it the way you'd say it. A day or time becomes the due date.") }
                Section {
                    Picker("List", selection: $pick) {
                        Text("Default").tag(String?.none)
                        ForEach(store.lists.filter(\.writable)) { k in Text(k.title).tag(Optional(k.id)) }
                    }
                }
            }
            .navigationTitle("New task").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add).fontWeight(.semibold).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear { focused = app.demoTask == nil && !app.sample }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() { app.addTask(text, listID: pick); dismiss() }
}

/// Which Reminders lists show in the Tasks tab and on the calendar (the Mac's sidebar ticks).
struct ListsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(Set(store.lists.map(\.account))).sorted(), id: \.self) { acct in
                    Section(acct) {
                        ForEach(store.lists.filter { $0.account == acct }) { l in
                            Toggle(isOn: Binding(get: { !store.hiddenLists.contains(l.id) }, set: { if $0 { store.hiddenLists.remove(l.id) } else { store.hiddenLists.insert(l.id) } })) {
                                HStack { Dot(color: l.color); Text(l.title); Spacer(); Text("\(store.todos.filter { $0.listID == l.id && !$0.done }.count)").foregroundStyle(T.text2) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lists").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
        }
        .presentationDetents([.medium, .large])
    }
}
