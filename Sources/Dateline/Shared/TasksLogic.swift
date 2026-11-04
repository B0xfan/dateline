// Phase 4: Apple Reminders on the calendar (approved Phase 4 mockups). Everything is saved in Reminders, so the phone sees each change.
import SwiftUI
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
    var a4: A4Task? = nil  // set on a task that lives in the A4 vault, not Reminders
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

// The No date part of the task list: one folded list per Reminders list, biggest first (approved folded-lists mockup).
func noDateLists(_ ts: [ToDo], title: (String) -> String) -> [(id: String, rows: [ToDo])] {
    Dictionary(grouping: ts, by: \.listID)
        .map { (id: $0.key, rows: $0.value.sorted { $0.done != $1.done ? !$0.done : $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
        .sorted { a, b in
            if a.rows.count != b.rows.count { return a.rows.count > b.rows.count }
            let o = title(a.id).localizedStandardCompare(title(b.id))
            return o == .orderedSame ? a.id < b.id : o == .orderedAscending  // two lists with one name keep a steady order
        }
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
    var canReadTasks: Bool { taskAccess == .granted || taskAccess == .sample }

    func requestReminders() {
        source.askForReminders { ok in
            self.taskAccess = ok ? .granted : .denied
            guard ok else { return }
            self.reloadReminders()
        }
    }

    func reloadReminders() {
        guard canReadTasks else { return }
        let known = source.reminderLists()
        // A4's reminders job copies timed tasks into a Reminders list; with A4 tasks showing, that list would show each one twice.
        let mirrored = a4On && FileManager.default.fileExists(atPath: a4Folder) ? Set(known.filter { $0.title == "A4 Tasks" }.map(\.id)) : []
        lists = known.filter { !mirrored.contains($0.id) } + lists.filter { $0.account == a4Account }
        taskFetch += 1
        let n = taskFetch
        source.readReminders { all in
            if n == self.taskFetch { self.todos = all.filter { !mirrored.contains($0.listID) } + self.todos.filter { $0.a4 != nil } }
        }
    }

    func taskList(_ id: String) -> CalInfo? { lists.first { $0.id == id } }

    // Adds a task to `listID` (nil = the Mac's default Reminders list).
    @discardableResult
    func addTask(_ t: ToDo, listID: String?) -> Result<ToDo, Failure> {
        if taskList(listID ?? "")?.account == a4Account { return .failure(Failure("New A4 tasks are added in Obsidian.")) }
        guard canReadTasks else { return .failure(Failure("Dateline can't see Reminders. Turn it on in System Settings, Privacy & Security, Reminders.")) }
        let saved = source.addReminder(t, listID: listID)
        if case .success(let t) = saved { todos.append(t) }  // shows at once; the change notification reloads
        return saved
    }

    // Saves a changed task (tick, edits in the task details, a drop on the calendar).
    @discardableResult
    func updateTask(_ t: ToDo) -> Failure? {
        let old = todos.first { $0.id == t.id }
        if t.a4 != nil { return updateA4(t, old: old) }
        if let f = source.updateReminder(t, old: old) { reloadReminders(); return f }
        taskFetch += 1  // a read already running has the old copy; the change notification reads again
        if let i = todos.firstIndex(where: { $0.id == t.id }) { todos[i] = t }  // shows at once; the reload that follows confirms it
        return nil
    }

    // The task for undo of an add.
    @discardableResult
    func deleteTask(_ t: ToDo) -> Failure? {
        if let f = source.deleteReminder(t) { return f }
        todos.removeAll { $0.id == t.id }
        return nil
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
}

