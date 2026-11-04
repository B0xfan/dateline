// A4 tasks in Dateline: task notes in John's vault shown beside Apple Reminders (approved design, 2026-10-31).
// A change goes into the note itself, touching only the lines it changes. Finishing a task goes through A4's own task engine in the running Obsidian, because only that files it in the Archive and moves a repeating task on.
// Sample mode (every test and picture) keeps made-up tasks in memory and never reads the vault.
import SwiftUI
import DatelineCore

func a4Selftest(_ expect: (Bool, String) -> Void) {
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
    let note = "---\nstatus: open\npriority: normal\ndue: 2026-10-25T09:30\nprojects:\n  - \"[[04 Inner World/Projects/Home|Home]]\"\ntags:\n  - task\n---\n\nFix it.\n---\nmore\n"
    let t = a4Read(note, file: "/v/Fix the gate.md", now: now)
    expect(t?.title == "Fix the gate" && t?.listID == "a4:Home" && t?.timed == true && t?.notes == "Fix it.\n---\nmore" && t?.done == false, "a4: reads a note")
    expect(t?.due == cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 30)) && isOverdue(t!, now: now) && taskRowDay(t!, now: now) == cal.startOfDay(for: now), "a4: an overdue task shows on today")
    expect(a4Read("no properties", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: open\n---\n", file: "/v/x.md", now: now) == nil, "a4: a note that isn't a task is skipped")
    expect(a4Read("---\nstatus: someday\ntags: [task]\n---\n", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: open\ntags:\n  - task\n  - archived\n---\n", file: "/v/x.md", now: now) == nil, "a4: Someday and archived are skipped")
    expect(a4Read("---\nstatus: done\ncompletedDate: 2026-10-01\ntags: [task]\n---\n", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: done\ncompletedDate: 2026-10-30\ntags: [task]\n---\n", file: "/v/x.md", now: now)?.done == true, "a4: done tasks stay a week")
    let rep = a4Read("---\nstatus: open\ndue: 2026-10-25\nscheduled: 2026-10-31\nrecurrence: DTSTART:20260904;FREQ=DAILY\ntags: [task]\n---\n", file: "/v/r.md", now: now)
    expect(rep?.a4?.repeating == true && rep?.due == cal.startOfDay(for: now), "a4: a repeating task sits on its current occurrence")
    expect(a4Edit(note, [("due", "2026-11-02T09:30"), ("completedDate", "2026-10-31")]) == note.replacingOccurrences(of: "due: 2026-10-25T09:30", with: "due: 2026-11-02T09:30").replacingOccurrences(of: "  - task\n---", with: "  - task\ncompletedDate: 2026-10-31\n---"), "a4: an edit touches only its lines")
    expect(a4Edit("---\ndue: 2026-10-25\ncompletedDate: 2026-10-30\n---\n---\n", [("due", ""), ("completedDate", nil)]) == "---\ndue:\n---\n---\n", "a4: empties Due, removes the rest, leaves the text alone")
    expect(a4Edit("no block", [("due", "x")]) == nil, "a4: never edits a note with no properties")
    var moved = t!; moved.due = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 30))
    expect(a4Changes(old: t!, new: moved, text: note, now: now).first?.1 == "2026-11-02T09:30", "a4: moving the day keeps the clock time")
    var r2 = rep!; r2.due = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))
    let shifted = a4Changes(old: rep!, new: r2, text: "---\ndue: 2026-10-25\nscheduled: 2026-10-31\n---\n", now: now)
    expect(shifted[0].0 == "scheduled" && shifted[0].1 == "2026-11-02" && shifted[1].0 == "due" && shifted[1].1 == "2026-10-27", "a4: moving a repeating task keeps the gap to its Due")
    expect(a4Read("---\nstatus: open\nscheduled: 2026-10-31\nrecurrence: FREQ=DAILY\ncomplete_instances:\n  - 2026-10-31\ntags: [task]\n---\n", file: "/v/r.md", now: now)?.done == true, "a4: a repeating day already ticked shows ticked")
    var cleared = t!; cleared.due = nil
    expect(a4Edit("---\ndue: 2026-10-25\nplanned_day: 2026-10-25\nplanned_half: am\n---\n", a4Changes(old: t!, new: cleared, text: note, now: now))?.contains("planned_") == false, "a4: clearing Due takes the task off A4's planned day")
    var reopened = a4Read("---\nstatus: done\ncompletedDate: 2026-10-30\ntags: [task]\n---\n", file: "/v/x.md", now: now)!; let was = reopened; reopened.a4?.status = "open"; reopened.done = false
    expect(a4Changes(old: was, new: reopened, text: "", now: now).contains { $0.0 == "completedDate" && $0.1 == nil }, "a4: reopening removes the done day")
    // A task with a clock time sits in the grid at that time; the time is read the way A4 reads it.
    func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
    func read(_ props: String) -> ToDo? { a4Read("---\nstatus: open\n\(props)\ntags: [task]\n---\n", file: "/v/a.md", now: now) }
    let appt = read("due: 2026-11-03T11:00")!
    expect(appt.timed && appt.due == at(3, 11, 0) && taskRowDay(appt, now: now) == nil, "a4: a task with a time goes in the grid, not the Tasks row")
    expect(read("due: \"2026-11-03T11:00:00.000-06:00\"")?.due == at(3, 11, 0), "a4: a quoted time with seconds reads as written")
    let dayOnly = read("due: 2026-11-03")!
    expect(!dayOnly.timed && taskRowDay(dayOnly, now: now) == at(3, 0, 0), "a4: a task with only a day stays in the Tasks row")
    expect(read("due: 2026-11-03T25:00")?.timed == false && read("due: 2026-11-03T25:00")?.due == at(3, 0, 0), "a4: a broken time counts as no time")
    expect(read("due: 2026-11-03T-1:00")?.timed == false, "a4: a time that isn't digits counts as no time")
    expect(read("scheduled: 2026-11-03\nrecurrence: DTSTART:20261012T090000Z;FREQ=DAILY")?.due == at(3, 9, 0), "a4: a repeating task with no time on its day takes its rule's")
    expect(read("scheduled: 2026-11-03T14:30\nrecurrence: DTSTART:20261012T090000Z;FREQ=DAILY")?.due == at(3, 14, 30), "a4: a repeating task's own time beats its rule's")
    expect(read("scheduled: 2026-11-03\nrecurrence: DTSTART:20261012T000000Z;FREQ=DAILY")?.timed == false, "a4: a rule at midnight means no time")
    var slot = appt; slot.due = at(4, 14, 15)
    expect(a4Changes(old: appt, new: slot, text: "", now: now).first?.1 == "2026-11-04T14:15", "a4: a new day and time are written to Due")
    var timedNow = dayOnly; timedNow.due = at(3, 9, 0); timedNow.timed = true
    expect(a4Changes(old: dayOnly, new: timedNow, text: "", now: now).first?.1 == "2026-11-03T09:00", "a4: adding a time writes it")
    let midnight = read("due: 2026-11-03T00:00")!; var noTime = midnight; noTime.timed = false
    expect(midnight.timed && a4Changes(old: midnight, new: noTime, text: "", now: now).first?.1 == "2026-11-03", "a4: taking off a midnight time is a change")
    let repText = "---\nstatus: open\ndue: 2026-11-01\nscheduled: 2026-11-03T11:00\nrecurrence: FREQ=DAILY\ntags: [task]\n---\n"
    let repTimed = a4Read(repText, file: "/v/r.md", now: now)!; var repMoved = repTimed; repMoved.due = at(4, 11, 0)
    let repSet = a4Changes(old: repTimed, new: repMoved, text: repText, now: now)
    expect(repSet[0].1 == "2026-11-04T11:00" && repSet[1].1 == "2026-11-02", "a4: a repeating task moved a day keeps its time and the gap to its Due")
    expect(a4Edit(repText, repSet).flatMap { a4Read($0, file: "/v/r.md", now: now) }?.due == at(4, 11, 0), "a4: a moved time reads back")
    let ruleText = "---\nstatus: open\nscheduled: 2026-11-03\nrecurrence: DTSTART:20261012T090000Z;FREQ=DAILY\ntags: [task]\n---\n"
    let ruleTask = a4Read(ruleText, file: "/v/r.md", now: now)!; var ruleMoved = ruleTask; ruleMoved.due = at(4, 9, 0)
    expect(a4Changes(old: ruleTask, new: ruleMoved, text: ruleText, now: now).first?.1 == "2026-11-04", "a4: a time from the rule isn't copied into the note")
    // A first time rings, as in A4; the half of the day follows the time.
    let dayText = "---\nstatus: open\ndue: 2026-11-03\nplanned_half: am\ntags: [task]\n---\n"
    var pm = dayOnly; pm.due = at(3, 14, 15); pm.timed = true; pm.a4?.ring = true
    let pmNote = a4Edit(dayText, a4Changes(old: dayOnly, new: pm, text: dayText, now: now)) ?? ""
    expect(pmNote.contains("due: 2026-11-03T14:15\n") && pmNote.contains("planned_half: pm\n") && pmNote.contains("relatedTo: due, offset: PT0M}]\n") && a4Read(pmNote, file: "/v/a.md", now: now) != nil, "a4: a first time rings and picks the half of the day")
    let hasBell = "---\nstatus: open\ndue: 2026-11-03\nreminders:\n  - id: rem_1\n    type: absolute\ntags: [task]\n---\n"
    expect(!a4Changes(old: dayOnly, new: pm, text: hasBell, now: now).contains { $0.0 == "reminders" }, "a4: a reminder already there is left alone")
    var undone = pm; undone.a4?.ring = false
    expect(!a4Changes(old: dayOnly, new: undone, text: dayText, now: now).contains { $0.0 == "reminders" }, "a4: an undo that brings a time back adds no ring")
    expect(!a4Changes(old: dayOnly, new: pm, text: "---\ndue: 2026-11-03\nreminders: [\n  {id: x}\n]\n---\n", now: now).contains { $0.0 == "reminders" }, "a4: a reminder list over several lines is left alone")
    let secs = read("due: 2026-11-03T11:00:00.000-06:00")!; var secsMoved = secs; secsMoved.due = at(4, 11, 0)
    expect(a4Changes(old: secs, new: secsMoved, text: "---\ndue: 2026-11-03T11:00:00.000-06:00\n---\n", now: now).first?.1 == "2026-11-04T11:00:00.000-06:00", "a4: a move keeps the time as written")
    var later = appt; later.due = at(3, 15, 0)
    expect(!a4Changes(old: appt, new: later, text: "---\ndue: 2026-11-03T11:00\n---\n", now: now).contains { $0.0 == "reminders" }, "a4: changing a time adds no reminder")
    expect(sameClock(at(1, 11, 30), on: at(5, 0, 0)) == at(5, 11, 30), "the time stays when the day changes")
    // A4 tasks with a time, as real events.
    func task(_ file: String, _ due: Date?, timed: Bool = true, done: Bool = false, repeating: Bool = false, title: String = "Vet") -> ToDo {
        ToDo(id: "a4:" + file, listID: "a4:H", title: title, due: due, timed: timed, done: done, a4: A4Task(file: file, repeating: repeating))
    }
    func ev(_ start: Date, id: String = "e1", title: String = "Vet") -> Item { Item(id: id, calendarID: "c", title: title, start: start, end: start.addingTimeInterval(1800), allDay: false, place: "", notes: "", showAs: .busy) }
    let dueAt = at(3, 11, 0), link = A4Link(event: "e1", calendar: "c", start: dueAt, title: "Vet")
    func plan(_ ts: [ToDo], _ ls: [String: A4Link] = [:], _ es: [Item] = [], calendar: String? = "c") -> (links: [String: A4Link], steps: [A4Step]) { a4Plan(tasks: ts, links: ls, events: es, calendarFor: { _ in calendar }, now: now) }
    let vetTask = task("/a", dueAt)
    expect(plan([vetTask]).steps == [.create(vetTask, calendar: "c")], "a4 link: a new task with a time makes an event")
    expect(plan([vetTask], calendar: nil).steps.isEmpty, "a4 link: no calendar picked, no event")
    expect(plan([task("/a", at(3, 11, 0), done: true), task("/b", at(3, 11, 0), repeating: true), task("/c", at(3, 0, 0), timed: false), task("/d", cal.date(byAdding: .day, value: -1, to: now)!)]).steps.isEmpty, "a4 link: done, repeating, no time and past tasks make none")
    expect(plan((0..<30).map { task("/\($0)", dueAt) }).steps.count == a4CreateCap, "a4 link: new events per pass are capped")
    expect(plan([vetTask], ["/a": link], [ev(dueAt)]).steps.isEmpty, "a4 link: nothing moved, nothing to do")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(dueAt)]).steps == [.moveEvent(ev(dueAt), to: at(4, 9, 0), title: "Vet")], "a4 link: the task moved, so the event follows")
    expect(plan([vetTask], ["/a": link], [ev(at(4, 9, 0))]).steps == [.moveTask(vetTask, to: at(4, 9, 0))], "a4 link: the event moved, so the task follows")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(at(5, 9, 0))]).steps == [.moveEvent(ev(at(5, 9, 0)), to: at(4, 9, 0), title: "Vet")], "a4 link: both moved, the note wins")
    expect(plan([task("/a", dueAt, title: "Vet visit")], ["/a": link], [ev(dueAt)]).steps == [.moveEvent(ev(dueAt), to: dueAt, title: "Vet visit")], "a4 link: a new title reaches the event")
    expect(plan([vetTask], ["/a": link], [ev(dueAt, title: "My name")]).steps.isEmpty, "a4 link: a new title on the event stays")
    let untimed = plan([task("/a", at(3, 0, 0), timed: false)], ["/a": link], [ev(dueAt)])
    expect(untimed.steps.isEmpty && untimed.links["/a"]?.misses == 1, "a4 link: a time gone for one read leaves the event, in case it was half typed")
    let threeReads = plan([task("/a", at(3, 0, 0), timed: false)], ["/a": { var m = link; m.misses = 2; return m }()], [ev(dueAt)])
    expect(threeReads.steps == [.dropEvent(ev(dueAt))] && threeReads.links.isEmpty, "a4 link: the time stays off, the event goes")
    let manyOff = Dictionary(uniqueKeysWithValues: (0..<9).map { ("/\($0)", A4Link(event: "e\($0)", calendar: "c", start: dueAt, title: "Vet", misses: 2)) })
    expect(plan((0..<9).map { task("/\($0)", at(3, 0, 0), timed: false) }, manyOff, (0..<9).map { ev(dueAt, id: "e\($0)") }).steps.count == a4DropCap, "a4 link: events removed per pass are capped")
    let pushedOnce = plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(dueAt)]).links
    expect(plan([vetTask], pushedOnce, [ev(at(4, 9, 0))]).steps == [.moveEvent(ev(at(4, 9, 0)), to: dueAt, title: "Vet")], "a4 link: a task changed back before they agree isn't overwritten")
    expect(plan([task("/a", at(4, 9, 0))], pushedOnce, [ev(dueAt)]).steps == [.moveEvent(ev(dueAt), to: at(4, 9, 0), title: "Vet")], "a4 link: a send that failed is tried again, the note unchanged")
    expect(plan([vetTask], [:], [ev(dueAt)]).steps.isEmpty && plan([vetTask], [:], [ev(dueAt)]).links["/a"]?.event == "e1", "a4 link: an event already there is taken up, not made twice")
    expect(plan([vetTask, task("/b", dueAt)], ["/b": link], [ev(dueAt)]).steps == [.create(vetTask, calendar: "c")], "a4 link: an event another task owns isn't taken")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": { var m = link; m.zone = "Asia/Tokyo"; return m }()], [ev(dueAt)]).steps.isEmpty, "a4 link: away from the note's time zone nothing moves")
    expect(plan([vetTask], ["/a": { var m = link; m.dismissed = true; return m }()], [ev(dueAt)]).links["/a"]?.dismissed == false, "a4 link: an event that comes back is linked again")
    expect(a4Plan(tasks: [vetTask], links: [:], events: [], calendarFor: { _ in "c" }, now: now, seen: { _ in false }).steps.isEmpty, "a4 link: no event made on a calendar not read yet")
    expect(plan([task("/a", dueAt, done: true)], ["/a": link], [ev(at(5, 9, 0))]).steps.isEmpty, "a4 link: a finished task's event is left alone")
    let filed = plan([], ["/a": link], [ev(dueAt)])
    expect(filed.steps.isEmpty && filed.links["/a"]?.away == true, "a4 link: a filed task leaves its event in place")
    expect(plan([vetTask], filed.links, [ev(dueAt)]).steps.isEmpty && plan([vetTask], filed.links, [ev(dueAt)]).links["/a"]?.away == false, "a4 link: a note that comes back finds its event, not a second one")
    let finishedLink = plan([task("/a", dueAt, done: true)], ["/a": link], [ev(dueAt)]).links
    expect(plan([task("/new", dueAt, title: "Dentist")], finishedLink, [ev(dueAt)]).steps.count == 1 && plan([task("/new", dueAt, title: "Dentist")], finishedLink, [ev(dueAt)]).links["/new"] == nil, "a4 link: a new task at a finished task's time gets its own event")
    expect(plan([task("/x", dueAt), task("/y", dueAt)], ["/a": link], [ev(dueAt)]).links["/a"] != nil, "a4 link: two new tasks at that time aren't taken for a rename")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(dueAt)]).links["/a"]?.start == dueAt, "a4 link: a move isn't recorded until the event has it, so a failed send is tried again")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(at(4, 9, 0))]).links["/a"]?.start == at(4, 9, 0), "a4 link: agreeing records the time")
    expect(plan([task("/a", dueAt, title: "Vet visit")], ["/a": link], [ev(at(5, 9, 0))]).steps == [.moveEvent(ev(at(5, 9, 0)), to: at(5, 9, 0), title: "Vet visit")], "a4 link: a new title doesn't snap a moved event back")
    expect(a4Plan(tasks: [vetTask], links: ["/a": link], events: [], calendarFor: { _ in "c" }, now: now, seen: { _ in false }).links["/a"]?.misses == 0, "a4 link: a calendar not read yet counts no miss")
    let renamed = plan([task("/new", dueAt)], ["/a": link], [ev(dueAt)])
    expect(renamed.steps.isEmpty && renamed.links["/new"] == link, "a4 link: a renamed note keeps its event")
    let otherCal = plan([vetTask], ["/a": link], [ev(dueAt, id: "e2")])
    expect(otherCal.steps.isEmpty && otherCal.links["/a"]?.event == "e2", "a4 link: an event moved to another calendar stays linked")
    var left = ["/a": link]
    for _ in 0..<2 { left = plan([vetTask], left).links }
    expect(left["/a"]?.dismissed == false && plan([vetTask], left).links["/a"]?.dismissed == true, "a4 link: a missing event counts as deleted after three reads")
    var gone = link; gone.dismissed = true
    expect(plan([vetTask], ["/a": gone]).steps.isEmpty, "a4 link: a deleted event doesn't come back")
    expect(plan([vetTask], ["/a": { var m = link; m.misses = 2; return m }()], [ev(dueAt)]).links["/a"]?.misses == 0, "a4 link: finding it again resets the count")
    // The project's note says work or personal.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("a4-sphere-\(UUID().uuidString)").path
    let fm = FileManager.default, taskDir = root + "/Tasks", projectDir = root + "/Projects/Deep"
    try? fm.createDirectory(atPath: taskDir, withIntermediateDirectories: true); try? fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    expect(a4Spheres(root + "/not there").isEmpty && a4Spheres("").isEmpty, "a4 link: no projects folder, nothing is read")
    try? "---\ntype: project\nsphere: work\n---\n".write(toFile: projectDir + "/client.md", atomically: true, encoding: .utf8)
    try? "---\nsphere: \"personal\"\n---\n".write(toFile: projectDir + "/Home.md", atomically: true, encoding: .utf8)
    try? "---\ntype: project\n---\n\nsphere: work in the text\n".write(toFile: projectDir + "/Unmarked.md", atomically: true, encoding: .utf8)
    try? "---\nsphere: work\n---\n".write(toFile: projectDir + "/Both.md", atomically: true, encoding: .utf8)
    try? "---\nsphere: personal\n---\n".write(toFile: root + "/Projects/Both.md", atomically: true, encoding: .utf8)
    for (name, project) in [("a", "Client"), ("b", "Home"), ("c", "Unmarked"), ("d", "Nowhere"), ("e", "Both")] {
        try? "---\nstatus: open\nprojects:\n  - \"[[x/\(project)]]\"\ntags:\n  - task\n---\n".write(toFile: taskDir + "/\(name).md", atomically: true, encoding: .utf8)
    }
    let sides = Dictionary(uniqueKeysWithValues: a4Scan(taskDir, now: now, projects: root + "/Projects").map { (($0.a4!.file as NSString).lastPathComponent, $0.a4!.sphere) })
    try? fm.removeItem(atPath: root)
    expect(sides == ["a.md": "work", "b.md": "personal", "c.md": "", "d.md": "", "e.md": ""], "a4 link: a task takes its project's side of life")
    expect(a4Project("[[a/b/Home.md|H]]") == "Home" && a4Project("Plain") == "Plain", "a4: project names")
    expect(a4Stamp(now).hasPrefix("2026-10-31T09:00:00.000") && a4Stamp(now).count == 29, "a4: A4's time stamp")
    MainActor.assumeIsolated {
        // The calendar follows the project, and an unmarked task goes nowhere.
        let routed = Store(sample: true), writable = routed.calendars.filter(\.writable)
        routed.a4WorkCalendar = writable[0].id; routed.a4Calendar = writable[1].id
        var w = task("/w", at(3, 11, 0)); w.a4?.sphere = "work"
        var h = task("/h", at(3, 11, 0)); h.a4?.sphere = "personal"
        expect(routed.a4Target(w) == writable[0].id && routed.a4Target(h) == writable[1].id && routed.a4Target(task("/n", at(3, 11, 0))) == nil, "a4 link: work and personal tasks go on their own calendars, others on none")
        routed.a4WorkCalendar = nil
        expect(routed.a4Target(w) == nil, "a4 link: no work calendar picked, a work task stays a task")
        // The whole round on sample calendars: event made, shown once, each side moves the other.
        let linked = AppState(store: .sampleWithA4(), today: now)
        let ls = linked.store, vet = ls.todos.first { $0.title == "Vet appointment" }!, target = ls.calendars.first { $0.writable && !ls.hidden.contains($0.id) }!
        ls.a4Calendar = target.id
        @MainActor func events() -> [Item] { ls.between(addDays(now, -60), addDays(now, 400)) }
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        @MainActor func theEvent() -> Item? { events().first { $0.title == "Vet appointment" } }
        expect(theEvent()?.start == vet.due && theEvent()?.calendarID == target.id && ls.a4OnCalendar(vet), "a4 link: the event is made and the task shows once")
        let firstCount = events().count
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        expect(events().count == firstCount, "a4 link: a second pass makes no second event")
        var pushed = theEvent()!; pushed.start = addDays(pushed.start, 1); pushed.end = addDays(pushed.end, 1)
        ls.update(pushed)
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        expect(ls.todos.first { $0.id == vet.id }?.due == pushed.start, "a4 link: moving the event moves the task")
        var back = ls.todos.first { $0.id == vet.id }!; back.due = vet.due
        ls.todos = ls.todos.map { $0.id == back.id ? back : $0 }
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        expect(theEvent()?.start == vet.due, "a4 link: moving the task moves the event")
        let d = UserDefaults.standard, before = (d.object(forKey: "a4On") as? Bool, d.string(forKey: "a4Folder"))
        let a = AppState(store: .sampleWithA4(), today: now)
        a.store.a4Set(on: false, folder: "/selftest")
        expect((d.object(forKey: "a4On") as? Bool, d.string(forKey: "a4Folder")) == before, "a4: tests never change the saved A4 settings")
        a.store.use(CalSet(name: "W", calendars: [], lists: []))
        expect(a.store.lists.filter { $0.account == a4Account }.allSatisfy { !a.store.hiddenLists.contains($0.id) }, "a4: a saved set never hides A4 projects")
        let s = a.store.todos.first { $0.a4 != nil && $0.due != nil }!
        a.drop(taskID: s.id, at: at(4, 14, 15))
        expect(a.store.todos.first { $0.id == s.id }.map { $0.timed && $0.due == at(4, 14, 15) } == true, "a4: a task dropped on the grid takes that time")
        if let i = a.store.todos.firstIndex(where: { $0.id == s.id }) { a.store.todos[i].a4?.repeating = true }
        a.drop(taskID: s.id, at: at(5, 9, 0))
        expect(a.store.todos.first { $0.id == s.id }?.due == at(5, 14, 15), "a4: a repeating task dropped on the grid takes the day and keeps its time")
        var n = s; n.done = true; a.saveTask(n)
        expect(a.store.todos.first { $0.id == s.id }?.done == true && a.store.lists.filter { $0.account == a4Account }.allSatisfy { !$0.writable }, "a4: a sample tick stays in memory; no moving reminders into A4")
        if case .failure = a.store.addTask(ToDo(id: "", listID: "", title: "x"), listID: "a4-home") {} else { expect(false, "a4: new tasks can't go in an A4 list") }
    }
}

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
                    Button { app.panels.openTaskID = nil } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.accessibilityLabel("Close").buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 8)
                HStack(alignment: .top, spacing: 8) {
                    TaskCircle(done: task.done, color: a4Color, size: 16) { let was = task.done; task.done.toggle(); task.a4?.status = task.done ? "done" : "open"; app.saveTask(task); if info.repeating { task.done = was; task.a4?.status = info.status } }.padding(.top, 4)
                    Text(task.title).font(.ui(17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                row("Project") { HStack(spacing: 8) { Circle().fill(a4Color).frame(width: 8, height: 8); Text((store.taskList(task.listID)?.title ?? "").replacingOccurrences(of: "A4: ", with: "")) } }
                row("Due") {
                    if let d = task.due {
                        DatePicker("", selection: Binding(get: { d }, set: { v in
                            task.due = task.timed ? sameClock(d, on: v) : cal.startOfDay(for: v); save()
                        }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        if info.repeating {
                            if task.timed { Text(timeText(d)) }
                        } else if task.timed {
                            DatePicker("", selection: Binding(get: { d }, set: { task.due = $0; save() }), displayedComponents: .hourAndMinute).labelsHidden()
                            Button { task.timed = false; task.due = cal.startOfDay(for: d); save() } label: { Image(systemName: "clock.badge.xmark") }.accessibilityLabel("Take the time off").buttonStyle(.plain).foregroundStyle(Palette.text3).help("Keep the day, take the time off")
                        } else {
                            Button("add time") { task.timed = true; task.a4?.ring = true; task.due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d); save() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }
                        if !info.repeating { Button { task.due = nil; task.timed = false; save() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear due").buttonStyle(.plain).foregroundStyle(Palette.text3).help("Clear the Due property") }
                    } else {
                        Button("Add a date") { task.due = cal.startOfDay(for: app.now); save() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                }
                row("Status") {
                    Menu {
                        ForEach(A4Task.statuses, id: \.0) { s in Button(s.1) { setStatus(s.0) } }
                    } label: { Text(A4Task.statuses.first { $0.0 == info.status }?.1 ?? info.status) }.menuStyle(.borderlessButton).fixedSize()
                }
                row("Priority") {
                    Menu {
                        ForEach(A4Task.priorities, id: \.self) { p in Button(p.capitalized) { task.a4?.priority = p; save() } }
                    } label: { Text(info.priority.capitalized) }.menuStyle(.borderlessButton).fixedSize()
                }
                Text("NOTE").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 16).padding(.bottom, 4)
                Text(task.notes.isEmpty ? "No text in this note." : task.notes).font(.ui(13)).foregroundStyle(task.notes.isEmpty ? Palette.text3 : Palette.text2)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                Button("Open in Obsidian") { openInObsidian(info.file) }.padding(.top, 12)
                Text("Saved in your A4 vault, so Obsidian sees each change. Change the title, the note's text and a repeating task's time in Obsidian.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            .padding(16)
        }
        .background(Palette.win)
        .onChange(of: store.todos) { _, list in
            // Changed in Obsidian, or by a tick in the calendar, while open.
            if let fresh = list.first(where: { $0.id == task.id }), fresh != task { task = fresh }
        }
    }

    // A refused save puts the panel back to what the note says, so a later edit can't carry the refused change along.
    func save() { app.saveTask(task); if let fresh = store.todos.first(where: { $0.id == task.id }), fresh != task { task = fresh } }

    func setStatus(_ s: String) {
        if task.a4?.repeating == true && s == "done" { var n = task; n.done = true; app.saveTask(n); return }  // ticks today's occurrence; the task itself stays open
        task.a4?.status = s; task.done = A4Task.finished.contains(s); app.saveTask(task)
    }

    func openInObsidian(_ file: String) {
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "path", value: file)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 52, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 8)
    }
}

struct A4Settings: View {
    @ObservedObject var store: Store
    func calendarPicker(_ label: String, work: Bool, selection: String?) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: { store.a4Pick(calendar: $0, work: work) })) {
            Text("No calendar").tag(String?.none)
            ForEach(store.calendars.filter(\.writable)) { c in Text(c.title + "  (" + c.account + ")").tag(String?.some(c.id)) }
        }.fixedSize()
    }
    var body: some View {
        let count = store.todos.filter { $0.a4 != nil && !$0.done }.count
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show A4 tasks on the calendar", isOn: Binding(get: { store.a4On }, set: { store.a4Set(on: $0) })).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 8) {
                Text("Tasks folder").font(.ui(13, weight: .semibold))
                HStack(spacing: 8) {
                    Text((store.a4Folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(store.a4Folder)
                    Button("Choose\u{2026}") {
                        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false; o.directoryURL = URL(fileURLWithPath: store.a4Folder)
                        if o.runModal() == .OK, let u = o.url { store.a4Set(folder: u.path) }
                    }
                }
                calendarPicker("Work tasks go on", work: true, selection: store.a4WorkCalendar).padding(.top, 8)
                calendarPicker("Personal tasks go on", work: false, selection: store.a4Calendar)
                Text("Each A4 task with a date and time becomes a real event, an hour long, on the calendar for its project: work or personal. Move the event, even to another calendar, and the task's Due follows; change the task and the event follows. Repeating tasks, and tasks whose project isn't marked work or personal, stay tasks. It happens while Dateline is running.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                Text(FileManager.default.fileExists(atPath: store.a4Folder) || store.access == .sample
                     ? "Found \(count) tasks that aren't done. Tasks with a Due property show on the calendar; the rest sit under No date, by project."
                     : "That folder isn't on this Mac.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 480, alignment: .leading)
    }
}

extension Store {
    // Only John's Mac has an A4 vault; on any other Mac, A4 stays out of sight.
    var a4Here: Bool { [a4Folder, a4DefaultFolder].contains { FileManager.default.fileExists(atPath: $0) } }

    // A sample store with made-up A4 tasks, for the A4 checks and John's A4 picture; the buyer-facing sample has none.
    static func sampleWithA4() -> Store { let s = Store(sample: true); s.loadSampleA4(SampleCalendar().mon); return s }

    // Made-up A4 tasks (Monday `mon`).
    func loadSampleA4(_ mon: Date) {
        let projects = [("a4-launch", "A4: Dateline launch"), ("a4-home", "A4: Home"), ("a4-reading", "A4: Reading Vault")]
        lists += projects.map { CalInfo(id: $0.0, title: $0.1, account: a4Account, color: a4Color, writable: false) }
        func t(_ list: String, _ title: String, _ day: Int?, hour: Int? = nil, status: String = "open", priority: String = "normal", notes: String = "") {
            todos.append(ToDo(id: "a4-\(title)", listID: list, title: title, due: day.map { d in cal.date(byAdding: .hour, value: hour ?? 0, to: addDays(mon, d))! }, timed: hour != nil, notes: notes, a4: A4Task(status: status, priority: priority, file: "/sample/" + title + ".md", sphere: list == "a4-launch" ? "work" : "personal")))
        }
        t("a4-launch", "Choose a license for Dateline", 0, priority: "high", notes: "Compare MIT and GPL, then add the file to the repo.")
        t("a4-home", "Pay the water bill", -2, status: "in-progress")
        t("a4-reading", "Answer buyer questions", 1)
        t("a4-launch", "Bring the GitHub page up to date", 3)
        t("a4-home", "Vet appointment", 1, hour: 11)
        for s in ["Sign the app", "Check the code is safe to share"] { t("a4-launch", s, nil) }
        for s in ["Fix the gate latch", "Sort the garage", "Renew the car papers"] { t("a4-home", s, nil) }
    }
}

