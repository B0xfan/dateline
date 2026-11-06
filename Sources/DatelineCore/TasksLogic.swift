// Phase 4: Apple Reminders on the calendar (approved Phase 4 mockups). Everything is saved in Reminders, so the phone sees each change.
import SwiftUI
import CoreLocation
import Contacts

public struct ToDo: Identifiable, Equatable {
    public var id: String
    public var listID: String
    public var title: String
    public var due: Date? = nil  // the start of the day when there is no time
    public var timed = false
    public var done = false
    public var notes = ""
    public var remind = Remind.time
    public var place: Spot? = nil
    public var a4: A4Task? = nil  // set on a task that lives in the A4 vault, not Reminders
    public init(id: String, listID: String, title: String, due: Date? = nil, timed: Bool = false, done: Bool = false, notes: String = "", remind: Remind = Remind.time, place: Spot? = nil, a4: A4Task? = nil) { self.id = id; self.listID = listID; self.title = title; self.due = due; self.timed = timed; self.done = done; self.notes = notes; self.remind = remind; self.place = place; self.a4 = a4 }
}

/// A task dropped on an hour (both apps) gets that day and time. A repeating A4 task's time belongs to its rule in A4, so it takes only the day.
public func dropped(_ t: ToDo, at time: Date) -> ToDo {
    var n = t
    if t.a4?.repeating == true { n.due = t.timed ? t.due.map { sameClock($0, on: time) } ?? time : cal.startOfDay(for: time) } else { if !t.timed { n.a4?.ring = true }; n.due = time; n.timed = true }
    return n
}

public enum Remind: String, CaseIterable { case time = "At a time", arriving = "Arriving", leaving = "Leaving" }

public struct Spot: Equatable {
    public var name: String
    public var lat: Double, lon: Double
    public var radius: Double = 150
    public init(name: String, lat: Double, lon: Double, radius: Double = 150) { self.name = name; self.lat = lat; self.lon = lon; self.radius = radius }
}

public enum TaskGroup: String, CaseIterable { case overdue = "Overdue", today = "Today", week = "Next 7 days", later = "Later", none = "No date" }

// Where a task sits in the task list.
public func taskGroup(_ t: ToDo, now: Date) -> TaskGroup {
    guard let d = t.due else { return .none }
    let today = cal.startOfDay(for: now), day = cal.startOfDay(for: d)
    if day < today { return t.done ? .today : .overdue }  // a done task is never overdue; it shows with today's until it drops off
    if day == today { return .today }
    return day <= addDays(today, 7) ? .week : .later
}

// The No date part of the task list: one folded list per Reminders list, biggest first (approved folded-lists mockup).
public func noDateLists(_ ts: [ToDo], title: (String) -> String) -> [(id: String, rows: [ToDo])] {
    Dictionary(grouping: ts, by: \.listID)
        .map { (id: $0.key, rows: $0.value.sorted { $0.done != $1.done ? !$0.done : $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
        .sorted { a, b in
            if a.rows.count != b.rows.count { return a.rows.count > b.rows.count }
            let o = title(a.id).localizedStandardCompare(title(b.id))
            return o == .orderedSame ? a.id < b.id : o == .orderedAscending  // two lists with one name keep a steady order
        }
}

public func isOverdue(_ t: ToDo, now: Date) -> Bool { !t.done && t.due.map { cal.startOfDay(for: $0) < cal.startOfDay(for: now) } == true }

// The day a task shows on in the calendar's Tasks row; nil when it has no date or shows in the grid at its time instead.
// Anything not done moves to today and stays there until it is ticked.
public func taskRowDay(_ t: ToDo, now: Date) -> Date? {
    guard let d = t.due else { return nil }
    if isOverdue(t, now: now) { return cal.startOfDay(for: now) }
    return t.timed ? nil : cal.startOfDay(for: d)
}

// "Fri", or "Oct 3" when it is more than a week away from today.
public func shortDay(_ d: Date, now: Date) -> String {
    abs(cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99) < 7 ? dateText(d, "EEE") : dateText(d, "MMM d")
}

extension Store {
    public var canReadTasks: Bool { taskAccess == .granted || taskAccess == .sample }

    public func requestReminders() {
        source.askForReminders { ok in
            self.taskAccess = ok ? .granted : .denied
            guard ok else { return }
            self.reloadReminders()
        }
    }

    public func reloadReminders() {
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

    public func taskList(_ id: String) -> CalInfo? { lists.first { $0.id == id } }

    // Adds a task to `listID` (nil = the Mac's default Reminders list).
    @discardableResult
    public func addTask(_ t: ToDo, listID: String?) -> Result<ToDo, Failure> {
        if taskList(listID ?? "")?.account == a4Account { return .failure(Failure("New A4 tasks are added in Obsidian.")) }
        guard canReadTasks else { return .failure(Failure("Dateline can't see Reminders. Turn it on in System Settings, Privacy & Security, Reminders.")) }
        let saved = source.addReminder(t, listID: listID)
        if case .success(let new) = saved {
            taskFetch += 1  // a read already running has the old list
            todos.append(new)
            if new.id != t.id, !t.id.isEmpty { renamed[t.id] = new.id }  // Undo of a delete: older Undo steps still name the old id
        }  // shows at once; the change notification reloads
        return saved
    }

    // Saves a changed task (tick, edits in the task details, a drop on the calendar).
    @discardableResult
    public func updateTask(_ t: ToDo) -> Failure? {
        var t = t; t.id = current(t.id)
        let old = todos.first { $0.id == t.id }
        if t.a4 != nil { return updateA4(t, old: old) }
        if let f = source.updateReminder(t, old: old) { reloadReminders(); return f }
        taskFetch += 1  // a read already running has the old copy; the change notification reads again
        if let i = todos.firstIndex(where: { $0.id == t.id }) { todos[i] = t }  // shows at once; the reload that follows confirms it
        return nil
    }

    // The task for undo of an add.
    @discardableResult
    public func deleteTask(_ t: ToDo) -> Failure? {
        var t = t; t.id = current(t.id)
        if let f = source.deleteReminder(t) { return f }
        taskFetch += 1  // a read already running would bring it back
        todos.removeAll { $0.id == t.id }
        return nil
    }

    // A task deleted and put back by Undo has a new id; follow the chain.
    func current(_ id: String) -> String { var id = id; while let n = renamed[id] { id = n }; return id }

    // A typed place, found on the map (no location permission needed for this).
    public func locate(_ text: String) async -> Spot? {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let l = try? await CLGeocoder().geocodeAddressString(q).first?.location else { return nil }
        return Spot(name: q, lat: l.coordinate.latitude, lon: l.coordinate.longitude)
    }

    // Home or Work from the "me" card in Contacts (asks for Contacts access the first time).
    public func meAddress(work: Bool) async -> Result<Spot, Failure> {
        let cs = CNContactStore()
        guard (try? await cs.requestAccess(for: .contacts)) == true else { return .failure(Failure("Dateline can't see Contacts. Turn it on in System Settings, Privacy & Security, Contacts.")) }
        let keys = [CNContactPostalAddressesKey as CNKeyDescriptor]
        #if os(macOS)
        let meCard = try? cs.unifiedMeContactWithKeys(toFetch: keys)
        #else
        let meCard: CNContact? = nil  // the iPhone has no "my card" lookup
        #endif
        guard let me = meCard else { return .failure(Failure("No card is set as yours in Contacts (Card, Make This My Card).")) }
        guard let a = me.postalAddresses.first(where: { $0.label == (work ? CNLabelWork : CNLabelHome) })?.value else {
            return .failure(Failure("Your card in Contacts has no \(work ? "work" : "home") address."))
        }
        let text = CNPostalAddressFormatter.string(from: a, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
        guard var s = await locate(text) else { return .failure(Failure("Couldn't find your \(work ? "work" : "home") address on the map.")) }
        s.name = work ? "Work" : "Home"
        return .success(s)
    }
}

