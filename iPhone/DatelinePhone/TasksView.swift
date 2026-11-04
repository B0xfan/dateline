// The Tasks tab (approved mockup "Tasks"): Reminders grouped like the Mac's task list. Swipe right to finish, left to move to tomorrow.
import SwiftUI
import DatelineCore

struct TasksView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var asking = false
    @State private var newTask = ""

    var body: some View {
        let now = app.today
        let shown = store.todos.filter { !store.hiddenLists.contains($0.listID) }
        let groups = TaskGroup.allCases.map { g in
            (g, shown.filter { taskGroup($0, now: now) == g }.sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture, $0.title) < ($1.done ? 1 : 0, $1.due ?? .distantFuture, $1.title) })
        }.filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
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
                    Section(pair.0.rawValue) { ForEach(pair.1) { TaskRow(t: $0) } }
                }
                Section {} footer: { Text("Swipe right to finish, left to move to tomorrow.") }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
        }
        .background(T.bg)
        .alert("New task", isPresented: $asking) {
            TextField("Call the plumber tomorrow", text: $newTask)
            Button("Cancel", role: .cancel) { newTask = "" }
            Button("Add") { app.addTask(newTask); newTask = "" }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let t: ToDo

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
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).strikethrough(t.done).foregroundStyle(t.done ? T.text2 : T.text)
                Text(subtitle(late)).font(.footnote).foregroundStyle(late ? T.late : T.text2)
            }
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
