// A4 tasks in Dateline: notes in John's vault shown beside Apple Reminders. Design pictures only so far: sample tasks, nothing reads or writes the vault yet.
import SwiftUI

struct A4Task: Equatable {
    var status = "open"
    var priority = "normal"
    var file = ""
    static let statuses = [("open", "Open"), ("in-progress", "In progress"), ("blocked", "Blocked"), ("done", "Done")]
    static let priorities = ["low", "normal", "high"]
}

let a4Color = Color(red: 0.49, green: 0.36, blue: 0.82)

// Task details for an A4 task: Due, Status and Priority change here. The title and the note's text stay in Obsidian, because renaming the file from here would break the links to it.
struct A4TaskDetail: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var task: ToDo
    var body: some View {
        let info = task.a4 ?? A4Task()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("A4 TASK").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                    Spacer()
                    Button { app.openTaskID = nil } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 10)
                HStack(alignment: .top, spacing: 8) {
                    TaskCircle(done: task.done, color: a4Color, size: 16) { task.done.toggle(); task.a4?.status = task.done ? "done" : "open"; app.saveTask(task) }.padding(.top, 3)
                    Text(task.title).font(.ui(17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                row("Project") { HStack(spacing: 6) { Circle().fill(a4Color).frame(width: 8, height: 8); Text((store.taskList(task.listID)?.title ?? "").replacingOccurrences(of: "A4: ", with: "")) } }
                row("Due") {
                    if let d = task.due {
                        DatePicker("", selection: Binding(get: { d }, set: { task.due = cal.startOfDay(for: $0); app.saveTask(task) }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        Button { task.due = nil; app.saveTask(task) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.text3).help("Clear the Due property")
                    } else {
                        Button("Add a date") { task.due = cal.startOfDay(for: app.now); app.saveTask(task) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                }
                row("Status") {
                    Menu {
                        ForEach(A4Task.statuses, id: \.0) { s in Button(s.1) { task.a4?.status = s.0; task.done = s.0 == "done"; app.saveTask(task) } }
                    } label: { Text(A4Task.statuses.first { $0.0 == info.status }?.1 ?? info.status) }.menuStyle(.borderlessButton).fixedSize()
                }
                row("Priority") {
                    Menu {
                        ForEach(A4Task.priorities, id: \.self) { p in Button(p.capitalized) { task.a4?.priority = p; app.saveTask(task) } }
                    } label: { Text(info.priority.capitalized) }.menuStyle(.borderlessButton).fixedSize()
                }
                Text("NOTE").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 18).padding(.bottom, 6)
                Text(task.notes.isEmpty ? "No text in this note." : task.notes).font(.ui(13)).foregroundStyle(task.notes.isEmpty ? Palette.text3 : Palette.text2)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                Button("Open in Obsidian") {}.padding(.top, 12)
                Text("Saved in your A4 vault, so Obsidian sees each change. Change the title and the note's text in Obsidian.")
                    .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            .padding(16)
        }
        .background(Palette.win)
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 52, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 10)
    }
}

struct A4Settings: View {
    @State var on = true
    var folder = "~/Projects/A4/02 Planner/TaskNotes/Tasks"
    var count = 251
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show A4 tasks on the calendar", isOn: $on).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tasks folder").font(.ui(13, weight: .semibold))
                HStack(spacing: 8) {
                    Text(folder).lineLimit(1).truncationMode(.middle).help(folder)
                    Button("Choose\u{2026}") {}
                }
                Text("Found \(count) tasks that aren't done. Tasks with a Due property show on the calendar; the rest sit under No date, by project.")
                    .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 480, alignment: .leading)
    }
}

extension Store {
    // Made-up A4 tasks for the pictures (Monday `mon`).
    func loadSampleA4(_ mon: Date) {
        let projects = [("a4-launch", "A4: Dateline launch"), ("a4-home", "A4: Home"), ("a4-reading", "A4: Reading Vault")]
        lists += projects.map { CalInfo(id: $0.0, title: $0.1, account: "A4", color: a4Color, writable: true) }
        func t(_ list: String, _ title: String, _ day: Int?, status: String = "open", priority: String = "normal", notes: String = "") {
            todos.append(ToDo(id: "a4-\(title)", listID: list, title: title, due: day.map { addDays(mon, $0) }, notes: notes, a4: A4Task(status: status, priority: priority, file: title + ".md")))
        }
        t("a4-launch", "Choose a license for Dateline", 0, priority: "high", notes: "Compare MIT and GPL, then add the file to the repo.")
        t("a4-home", "Pay the water bill", -2, status: "in-progress")
        t("a4-reading", "Answer buyer questions", 1)
        t("a4-launch", "Bring the GitHub page up to date", 3)
        for s in ["Sign the app", "Check the code is safe to share"] { t("a4-launch", s, nil) }
        for s in ["Fix the gate latch", "Sort the garage", "Renew the car papers"] { t("a4-home", s, nil) }
    }
}
