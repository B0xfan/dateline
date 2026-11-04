// The one door to the Mac's calendars and reminders. AppleCalendar is the real thing (F1, J3: the accounts already set up on this Mac, nothing leaves it);
// SampleCalendar is made-up data in memory for every test and picture, and never asks for access. Only this file talks to Apple's calendar framework.
// Items going through here carry what the calendar holds; Dateline's own extras (emoji, tags, travel) stay in Store.
import Foundation
import EventKit
import SwiftUI
import CoreLocation
import DatelineCore

@MainActor
// Saving, undo and calendar changes, end to end through the store on the sample source: nothing touches a real calendar or saved setting.
@MainActor func calendarSourceSelftest(_ expect: (Bool, String) -> Void) {
    let source = SampleCalendar()
    let a = AppState(store: Store(source: source)), s = a.store
    a.mode = .month
    func find(_ t: String) -> Item? { s.items.first { $0.title == t } }
    var p = Parsed(start: addDays(source.mon, 1).addingTimeInterval(9 * 3600), end: addDays(source.mon, 1).addingTimeInterval(10 * 3600)); p.title = "New one"
    guard let added = a.add(p, calendar: s.calendar("work")) else { expect(false, "adding an event saves it"); return }
    expect(find("New one") != nil && source.events.contains { $0.id == added.id }, "adding an event saves it in the calendar and shows it")
    a.undo()
    expect(find("New one") == nil && !source.events.contains { $0.id == added.id }, "undo takes a new event back out")

    guard var dentist = find("Dentist") else { expect(false, "sample event found"); return }
    let was = dentist.start
    dentist.start = was.addingTimeInterval(3600); dentist.end = dentist.end.addingTimeInterval(3600)
    a.save(dentist)
    expect(source.events.first { $0.id == dentist.id }?.start == dentist.start && find("Dentist")?.start == dentist.start, "a move is saved and shows")
    a.undo()
    expect(find("Dentist")?.start == was, "undo moves it back")

    dentist = find("Dentist")!
    expect(dentist.emoji == "🦷" && source.events.first { $0.id == dentist.id }?.emoji == "", "an emoji is kept by Dateline, never in the calendar")
    var marked = dentist; marked.tags = ["Teeth"]; marked.emoji = ""
    let before = source.events
    a.save(marked)
    expect(source.events == before && find("Dentist")?.tags == ["Teeth"] && s.allTags.contains { $0.0 == "Teeth" } && find("Dentist")?.emoji == "", "changing only Dateline's extras leaves the calendar alone")
    a.undo()
    expect(find("Dentist")?.emoji == "🦷" && find("Dentist")?.tags == [], "undo puts the extras back")

    a.delete(dentist)
    expect(find("Dentist") == nil && !source.events.contains { $0.title == "Dentist" }, "delete removes the event")
    a.undo()
    let back = find("Dentist")
    expect(back?.id != dentist.id && back?.emoji == "🦷" && back?.place == dentist.place && back?.geo == dentist.geo, "undo of a delete puts it back whole, as a new copy")
    var moved = dentist; moved.start = was.addingTimeInterval(7200); moved.end = moved.start.addingTimeInterval(3600)
    expect(s.update(moved) == nil && find("Dentist")?.start == moved.start, "an older undo step still finds an event that was deleted and put back")
    if let copy = find("Dentist") {
        a.delete(copy); expect(s.update(copy)?.message == "That event is gone.", "a deleted event says it's gone")
        a.undo()
    }

    guard let school = s.items.first(where: { isSub($0.calendarID) }) else { expect(false, "sample subscribed event"); return }
    var edited = school; edited.title = "Changed"
    expect(s.update(edited) != nil && s.delete(school) != nil, "a subscribed calendar's events can't be changed or deleted")

    // Another device changes the calendar: a burst of notices reads once, and the window follows.
    var far = dentist; far.id = "from-the-phone"; far.title = "From the phone"; far.emoji = ""
    source.events.append(far)
    var reads = 0
    let watching = s.$calendars.dropFirst().sink { _ in reads += 1 }
    for _ in 0..<5 { source.fireChange() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    expect(find("From the phone") != nil, "a change from another device shows")
    expect(reads == 1, "a burst of change notices reloads once (\(reads))")
    watching.cancel()

    // Tasks
    a.taskPanel.text = "Selftest task"
    a.commitTask()
    guard let task = s.todos.first(where: { $0.title == "Selftest task" }) else { expect(false, "adding a task"); return }
    expect(source.tasks.contains { $0.id == task.id }, "a new task is saved in Reminders")
    a.toggle(task)
    expect(source.tasks.first { $0.id == task.id }?.done == true && s.todos.first { $0.id == task.id }?.done == true, "a tick is saved and shows")
    a.undo()
    expect(source.tasks.first { $0.id == task.id }?.done == false, "undo takes the tick back")
    a.undo()
    expect(!source.tasks.contains { $0.id == task.id } && !s.todos.contains { $0.id == task.id }, "undo takes a new task back out")
}

