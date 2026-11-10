// The self-test: runs the pure logic in DatelineCore plus the Mac-only screens' logic. --selftest.
import SwiftUI
import AppKit
import Combine
import DatelineCore

func selftest() -> Int32 {
    WorkWeek.reset()  // the mockup's week: Monday first, Mon to Fri, 8 AM to 6 PM
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL:", what) } }
    var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 26; c.hour = 9; c.minute = 41
    cal.timeZone = TimeZone(identifier: "America/Costa_Rica")!
    let now = cal.date(from: c)!  // Monday, October 26, 2026, the mockup's "today"
    func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))! }

    expect(weekNumber(now) == 44, "Oct 26 2026 is week 44")
    // Direct handling (drag, stretch, tap on a slot, undo list) shared with the iPhone.
    do {
        let a = cal.startOfDay(for: now), e = Item(id: "d", calendarID: "w", title: "d", start: a.addingTimeInterval(9 * 3600), end: a.addingTimeInterval(10 * 3600), allDay: false, place: "", notes: "", showAs: .busy)
        expect(DragMath.minutes(dy: 20, hourH: 56) == 15 && DragMath.minutes(dy: 6, hourH: 56) == 0 && DragMath.minutes(dy: -42, hourH: 56) == -45, "drag snaps to 15 minutes")
        let m = DragMath.move(e, minutes: 45, days: 1)
        expect(m.start == addDays(a, 1).addingTimeInterval(9.75 * 3600) && m.end.timeIntervalSince(m.start) == 3600, "a move keeps the length and can change the day")
        expect(DragMath.stretch(e, minutes: 30).end == e.end.addingTimeInterval(1800) && DragMath.stretch(e, minutes: -9999).end == e.start.addingTimeInterval(900), "stretching never goes under 15 minutes")
        expect(DragMath.slot(on: a, y: 56 * 14.6, hourH: 56) == a.addingTimeInterval(14.5 * 3600) && DragMath.slot(on: a, y: -30, hourH: 56) == a && DragMath.slot(on: a, y: 5000, hourH: 56) == a.addingTimeInterval(23.5 * 3600), "a tap on a slot starts at the half hour above it")
        let u = UndoStack(); var log: [Int] = []
        expect(u.undo() == nil && !u.canUndo, "undo with nothing to undo does nothing")
        u.push { log.append(1); return nil }; u.push { log.append(2); return Failure("no") }
        expect(u.undo()?.message == "no" && u.undo() == nil && log == [2, 1] && !u.canUndo, "undo runs newest first and reports a failure")
    }
    expect(weekNumber(cal.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!) == 53, "Jan 1 2027 is in week 53 of 2026")
    expect(startOfWeek(at(11, 1, 12)) == at(10, 26, 0), "week starts Monday")
    expect(monthGrid(now).count == 35 && monthGrid(now).first == at(9, 28, 0), "October 2026 grid: 5 weeks from Sep 28")
    func ev(_ c: String, _ a: Date, _ b: Date) -> Item { Item(id: c, calendarID: c, title: "", start: a, end: b, allDay: false, place: "", notes: "", showAs: .busy) }
    let yr = cal.dateInterval(of: .year, for: now)!
    let dc = dayCalendars([ev("w", at(3, 2, 9), at(3, 2, 10)), ev("p", at(3, 2, 22), at(3, 4, 0)), ev("w", at(3, 2, 11), at(3, 2, 12)), ev("f", at(12, 31, 20), at(12, 31, 20))], in: yr)
    expect(dc[at(3, 2, 0)] == ["w", "p"] && dc[at(3, 3, 0)] == ["p"] && dc[at(3, 4, 0)] == nil, "year dots: one per calendar, overnight event spans to its end")
    expect(dc[at(12, 31, 0)] == ["f"], "year dots: a zero-length event still marks its day")
    func hit(_ id: String, _ d: Date, place: String = "", notes: String = "", cal c: String = "w") -> Item { Item(id: id, calendarID: c, title: id, start: d, end: d.addingTimeInterval(3600), allDay: false, place: place, notes: notes, showAs: .busy) }
    let sr = searchEvents(" dentist ", in: [hit("Dentist May", at(5, 11, 10)), hit("Dentist Feb", at(2, 5, 15)), hit("Cleaning", at(11, 18, 10), place: "Dentist office"), hit("Later", at(12, 1, 9), notes: "ask the DENTIST"),
                                         hit("Hidden dentist", at(11, 20, 9), cal: "x"), hit("Lunch", at(11, 19, 12))], hidden: ["x"], now: at(10, 26, 12))
    expect(sr.coming.map(\.id) == ["Cleaning", "Later"] && sr.past.map(\.id) == ["Dentist May", "Dentist Feb"], "search: title, place, notes in any case; coming soonest first, past newest first; hidden calendars left out")
    expect(searchEvents("  ", in: [hit("Dentist", at(11, 1, 9))], hidden: [], now: at(10, 26, 12)).coming.isEmpty, "search: blank text finds nothing")
    expect(dayCalendars([ev("x", at(1, 1, 0).addingTimeInterval(-86400 * 900), at(1, 1, 0).addingTimeInterval(86400 * 900))], in: yr).count == 365, "year dots: a years-long event is clipped to the year")

    var p = parseSentence("Dinner with Ana Friday 7pm at Casa Luna", now: now)
    expect(p.title == "Dinner with Ana", "title: \(p.title)")
    expect(p.start == at(10, 30, 19) && p.end == at(10, 30, 20), "Friday 7pm, one hour: \(p.start)")
    expect(p.place == "Casa Luna" && !p.allDay, "place: \(p.place)")
    p = parseSentence("Dinner with Ana Friday 7pm", now: now)
    expect(p.title == "Dinner with Ana" && p.start == at(10, 30, 19), "mockup sentence")
    p = parseSentence("Call mom tomorrow at 3", now: now)
    expect(p.title == "Call mom" && p.start == at(10, 27, 15), "bare 3 after 'at' reads as 3 PM: \(p.start)")
    p = parseSentence("Standup 9:30am for 15 min", now: now)
    expect(p.title == "Standup" && p.start == at(10, 27, 9, 30) && p.end == at(10, 27, 9, 45), "time already past today goes to tomorrow, 15 min: \(p.start)")
    p = parseSentence("Market and More delivery 9:30 AM to 10:00 AM", now: now)
    expect(p.title == "Market and More delivery" && p.start == at(10, 27, 9, 30) && p.end == at(10, 27, 10), "AM typed as its own word is read, not left in the title: \(p.title)")
    p = parseSentence("Dinner 7 p.m.", now: now)
    expect(p.title == "Dinner" && p.start == at(10, 26, 19), "p.m. with dots: \(p.title) \(p.start)")
    p = parseSentence("Q4 PM sync", now: now)
    expect(p.title == "Q4 PM sync" && p.allDay, "PM after a word that is not a time stays: \(p.title)")
    p = parseSentence("Gym today 6-7:30pm", now: now)
    expect(p.title == "Gym" && p.start == at(10, 26, 18) && p.end == at(10, 26, 19, 30), "range 6-7:30pm: \(p.start) \(p.end)")
    p = parseSentence("Workshop 2pm to 5pm on Nov 3", now: now)
    expect(p.title == "Workshop" && p.start == at(11, 3, 14) && p.end == at(11, 3, 17), "from-to with month day: \(p.title) \(p.start)")
    p = parseSentence("Maya's birthday 11/14", now: now)
    expect(p.allDay && p.start == at(11, 14, 0) && p.title == "Maya's birthday", "no time: all day")
    p = parseSentence("Team offsite all day next Thursday", now: now)
    expect(p.allDay && p.start == at(10, 29, 0) && p.title == "Team offsite", "all day + next weekday: \(p.title)")
    p = parseSentence("Lunch noon Wed free", now: now)
    expect(p.start == at(10, 28, 12) && p.showAs == .free && p.title == "Lunch", "noon, free: \(p.title)")
    p = parseSentence("Meet Carlos at the beach Saturday 4pm", now: now)
    expect(p.title == "Meet Carlos" && p.place == "the beach" && p.start == at(10, 31, 16), "place before day and time: \(p.place)")
    p = parseSentence("Dentist Oct 2 10am", now: now)
    expect(cal.dateComponents([.year, .month, .day, .hour], from: p.start) == DateComponents(year: 2027, month: 10, day: 2, hour: 10), "past date rolls to next year")
    p = parseSentence("Read 1.5h tonight", now: now)
    expect(p.start == at(10, 26, 19), "tonight = 7 PM")
    expect(snapped(at(10, 26, 9, 41), by: 15) == at(10, 26, 9, 45) && snapped(at(10, 26, 9, 41), by: -15) == at(10, 26, 9, 30), "nudge snaps to the grid both ways")
    expect(snapped(at(10, 26, 9, 41).addingTimeInterval(30), by: 15) == at(10, 26, 9, 45) && snapped(at(10, 26, 9, 45), by: -15) == at(10, 26, 9, 30), "seconds ignored, on-grid moves 15")
    p = parseSentence("Dinner at Casa Luna Nov 3 7pm", now: now)
    expect(p.place == "Casa Luna" && p.start == at(11, 3, 19), "date after the place: \(p.place)")
    p = parseSentence("Lunch at Soda Tica tonight", now: now)
    expect(p.place == "Soda Tica" && p.start == at(10, 26, 19), "tonight after the place")
    p = parseSentence("Party tonight 9pm", now: now)
    expect(p.start == at(10, 26, 21), "tonight then a time: \(p.start)")
    p = parseSentence("Meeting 7 to 9pm", now: now)
    expect(p.title == "Meeting" && p.start == at(10, 26, 19) && p.end == at(10, 26, 21), "7 to 9pm: \(p.title)")
    p = parseSentence("Call 7:30 to 9pm", now: now)
    expect(p.start == at(10, 26, 19, 30) && p.end == at(10, 26, 21), "7:30 to 9pm is evening: \(p.start)")
    p = parseSentence("Trip 25/12", now: now)
    expect(p.start == at(12, 25, 0) && p.allDay, "25/12 is December 25")
    expect(parseSentence("Trip 13/13", now: now).title == "Trip 13/13", "impossible date stays in the title")
    p = parseSentence("Sun and surf 3pm", now: now)
    expect(p.title == "Sun and surf" && p.start == at(10, 26, 15), "leading Sun is a word: \(p.title)")
    p = parseSentence("Standup next Monday 9am", now: now)
    expect(p.start == at(11, 2, 9), "next Monday on a Monday is a week away")
    p = parseSentence("Standup 9:30", now: now)
    expect(p.start == at(10, 27, 9, 30), "9:30 with no am/pm stays morning")
    p = parseSentence("Lunch with Sam tomorrow 1pm /Personal -a15m -r1w", now: now)
    expect(p.title == "Lunch with Sam" && p.start == at(10, 27, 13) && p.calendarCode == "Personal" && p.alertMinutes == 15 && p.repeats == Repeat(unit: "w", n: 1), "short codes: \(p.title)")
    p = parseSentence("-a1h Standup -r2d 9am free", now: now)
    expect(p.title == "Standup" && p.alertMinutes == 60 && p.repeats?.text == "Every 2 days" && p.showAs == .free, "codes anywhere: \(p.title)")
    expect(parseSentence("Read a-ha /", now: now).title == "Read a-ha /" && parseSentence("x -a1x", now: now).alertMinutes == nil, "not codes stay in the title")
    expect(parseSentence("Call -a99999999999999999d", now: now).alertMinutes == nil, "huge alert code is ignored, not a crash")
    let cals = ["Finance", "Family", "Fun Stuff"].map { CalInfo(id: $0, title: $0, account: "", color: .gray, writable: true) }
    expect(matchCalendar("f", in: cals, hidden: ["Finance"])?.id == "Family" && matchCalendar("funstuff", in: cals, hidden: [])?.id == "Fun Stuff"
           && matchCalendar("fin", in: cals, hidden: ["Finance"])?.id == "Finance" && matchCalendar("x", in: cals, hidden: []) == nil, "/code prefers shown calendars")
    expect(alertText(15) == "15 minutes before" && alertText(60) == "1 hour before" && alertText(2880) == "2 days before", "alert text")
    expect(alertText(900, allDay: true) == "1 day before, 9 AM" && alertText(-540, allDay: true) == "On the day, 9 AM"
           && alertText(9540, allDay: true) == "1 week before, 9 AM" && alertText(2370, allDay: true) == "2 days before, 8:30 AM", "all-day alert text")
    let alerted = Item(id: "a", calendarID: "c", title: "", start: Date(timeIntervalSince1970: 100_000), end: Date(timeIntervalSince1970: 103_600), allDay: false,
                       place: "", notes: "", showAs: .busy, alerts: [Date(timeIntervalSince1970: 100_000 - 900), Date(timeIntervalSince1970: 100_000 + 32400)])
    expect(alertMinutes(alerted) == [15, -540], "alert minutes from the saved alert times")
    let pastList = [Item(id: "a", calendarID: "personal", title: "Lunch with the team", start: at(9, 30, 12), end: at(9, 30, 13), allDay: false, place: "Office", notes: "", showAs: .busy),
                    Item(id: "b", calendarID: "personal", title: "Lunch with Sam", start: at(10, 13, 12), end: at(10, 13, 13, 30), allDay: false, place: "Casa Luna", notes: "", showAs: .maybe),
                    Item(id: "c", calendarID: "work", title: "Gym", start: at(10, 1, 7), end: at(10, 1, 8), allDay: false, place: "", notes: "", showAs: .busy)]
    let sug = suggestions("Lunch with Sam", in: pastList)
    expect(sug.map(\.id) == ["b", "a"], "past events: exact start first, same first word next")
    expect(suggestions("L", in: pastList).isEmpty, "one letter suggests nothing")
    p = applying(sug[0], to: parseSentence("Lunch with sam tomorrow 1pm", now: now))
    expect(p.title == "Lunch with Sam" && p.place == "Casa Luna" && p.end == at(10, 27, 14, 30) && p.showAs == .maybe, "past event fills place, length, show as")
    p = applying(sug[0], to: parseSentence("Lunch tomorrow 1-2pm at Soda", now: now))
    expect(p.place == "Soda" && p.end == at(10, 27, 14), "what was typed wins over the past event")
    expect(quarterStart(at(11, 14, 9)) == at(10, 1, 0) && quarterStart(at(3, 31, 9)) == at(1, 1, 0), "quarter starts")
    func it2(_ t: String, _ a: Date, _ b: Date, allDay: Bool = false) -> Item { Item(id: t, calendarID: "w", title: t, start: a, end: b, allDay: allDay, place: "", notes: "", showAs: .busy) }
    let soon = comingUp([it2("Review", at(10, 26, 9), at(10, 26, 10, 21)), it2("Lunch", at(10, 26, 11, 21), at(10, 26, 12)),
                         it2("Beach day", at(11, 1, 0), at(11, 2, 0), allDay: true), it2("Old", at(10, 26, 0), at(10, 27, 0), allDay: true)], now: now)
    expect(soon.map(\.title) == ["Review", "Lunch", "Beach day"], "coming up order: \(soon.map(\.title))")
    expect(soon[1].big == "1 h 40 min" && soon[2].big == "6 days" && soon[2].tail == " · Sunday" && soon[0].lead == "ends in 40 min · started 41 min ago" && soon[0].dim, "coming up text: \(soon)")
    // The second event today still shows (the Packers game, John 2026-11-08), all-day sits on its day, and the list stops at 4.
    let many = comingUp([it2("Game", at(10, 26, 9), at(10, 26, 11)), it2("Packers", at(10, 26, 13), at(10, 26, 16)),
                         it2("Birthday", at(10, 28, 0), at(10, 29, 0), allDay: true), it2("Dentist", at(10, 28, 9), at(10, 28, 10)), it2("Later", at(10, 30, 9), at(10, 30, 10))], now: now)
    expect(many.map(\.title) == ["Game", "Packers", "Birthday", "Dentist"], "coming up keeps time order: \(many.map(\.title))")
    expect(comingUp([it2("Trip", at(10, 29, 8), at(10, 29, 9))], now: now).first?.big == "3 days", "far next event counts days")
    expect(timeText(at(10, 26, 19)) == "7:00 PM" && timeText(at(10, 26, 19), short: true) == "7 PM", "clock text")
    // Phase 3: formatted notes keep plain text the phone can read.
    let plainNotes = "Fix before he leaves:\n[x] Kitchen tap\n[ ] Door lock\n- Gate code\n1. First"
    expect(notesShown(plainNotes) == "Fix before he leaves:\n☑ Kitchen tap\n☐ Door lock\n• Gate code\n1. First", "notes shown with boxes and bullets")
    expect(notesPlain(NSAttributedString(string: notesShown(plainNotes))) == plainNotes, "notes go back to the same plain text")
    let phone = "• eggs\n[X] done\n[] milk"
    expect(notesPlain(NSAttributedString(string: notesShown(phone) + "\n• new"), like: phone) == phone + "\n- new", "notes from the phone keep their marks when another line is added")
    let linked = NSMutableAttributedString(string: "Parts list here")
    linked.addAttribute(.link, value: URL(string: "https://x.com/a")!, range: NSRange(location: 0, length: 10))
    expect(notesPlain(linked) == "Parts list (https://x.com/a) here", "a link keeps its address in the plain text")
    expect(activeSet([CalSet(name: "W", calendars: ["w", "gone"])], calendars: ["w", "p"], hidden: ["p"])?.name == "W", "a set matches with a calendar gone from the Mac")
    expect(activeSet([CalSet(name: "W", calendars: ["w"])], calendars: ["w", "p"], hidden: []) == nil, "no set matches when all are shown")
    func callIn(link: String = "", place: String = "", notes: String = "") -> String? {
        callLink(Item(id: "", calendarID: "", title: "", start: now, end: now, allDay: false, place: place, notes: notes, showAs: .busy, link: link))?.service
    }
    expect(callIn(notes: "Join: https://us02web.zoom.us/j/8123456789?pwd=abc") == "Zoom", "a Zoom link in the notes")
    expect(callIn(place: "meet.google.com/xkd-pqrv-tmn") == "Google Meet", "a Meet link in the place, no https")
    expect(callIn(notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0") == "Microsoft Teams", "a Teams link")
    expect(callIn(link: "https://zoom.us/j/1", notes: "https://meet.google.com/abc-defg-hij") == "Zoom", "the event's own link wins")
    expect(callIn(notes: "https://evilzoom.us/j/1 https://notteams.live.com/meet/x") == nil, "a look-alike address is not a call")
    expect(callIn(notes: "see https://zoom.us/pricing and https://meet.google.com/") == nil, "a plain Zoom or Meet page is not a call")
    expect(callIn(notes: "zoommtg://zoom.us/j/1 ftp://meet.google.com/abc-defg-hij") == nil, "only web links open as a call")
    var tagged = it2("Tagged", at(10, 26, 9), at(10, 26, 10)); tagged.tags = ["Condo"]; tagged.emoji = "🏠"
    expect(sameInCalendar(tagged, it2("Tagged", at(10, 26, 9), at(10, 26, 10))), "emoji and tags never reach the calendar")

    // Phase 4: tasks.
    expect(!parseSentence("Buy milk", now: now).dateGiven && parseSentence("Call the bank Friday 3pm", now: now).dateGiven, "a task with no day or time has no due date")
    p = parseSentence("Call the bank Friday 3pm", now: now)
    expect(p.title == "Call the bank" && p.start == at(10, 30, 15) && !p.allDay, "task sentence: due Friday at 3")
    func td(_ due: Date?, timed: Bool = false, done: Bool = false) -> ToDo { ToDo(id: "x", listID: "l", title: "x", due: due, timed: timed, done: done) }
    expect(taskGroup(td(at(10, 23, 0)), now: now) == .overdue && taskGroup(td(at(10, 26, 0)), now: now) == .today
           && taskGroup(td(at(11, 2, 0)), now: now) == .week && taskGroup(td(at(11, 3, 0)), now: now) == .later && taskGroup(td(nil), now: now) == .none, "task groups")
    expect(taskGroup(td(at(10, 23, 0), done: true), now: now) == .today, "a done task is never overdue")
    func nd(_ list: String, _ title: String, done: Bool = false) -> ToDo { ToDo(id: list + title, listID: list, title: title, done: done) }
    let folds = noDateLists([nd("b", "Rice"), nd("a", "Eggs"), nd("c", "zinc"), nd("c", "Apples", done: true), nd("c", "Milk"), nd("d", "Mop"), nd("e", "Rake")]) { ["a": "Groceries", "b": "garden", "c": "Shopping", "d": "Condo", "e": "Condo"][$0]! }
    expect(folds.map(\.id) == ["c", "d", "e", "b", "a"], "no-date lists: biggest first, then A to Z by name ignoring case, same names in a steady order")
    expect(folds[0].rows.map(\.title) == ["Milk", "zinc", "Apples"], "no-date lists: open tasks A to Z, done ones last")
    expect(taskRowDay(td(at(10, 23, 0)), now: now) == at(10, 26, 0) && taskRowDay(td(at(10, 23, 15), timed: true), now: now) == at(10, 26, 0), "an unfinished task moves to today")
    expect(taskRowDay(td(at(10, 27, 11), timed: true), now: now) == nil && taskRowDay(td(at(10, 27, 0)), now: now) == at(10, 27, 0), "a timed task shows in the grid, not the row")
    expect(taskRowDay(td(at(10, 23, 0), done: true), now: now) == at(10, 23, 0), "a ticked task stays on its own day")
    // Week settings.
    MainActor.assumeIsolated {
        sampleToday = now  // sample events must sit in the test's week, or up/down finds none
        defer { sampleToday = nil }
        let a = AppState(store: Store(sample: true), today: now)
        a.mode = .week; a.days = 5
        expect(a.visibleDays == (0..<5).map { at(10, 26 + $0, 0) }, "5 days from Monday = Mon to Fri")
        a.days = 3
        expect(a.visibleDays == (0..<3).map { at(10, 26 + $0, 0) }, "3 days start on today")
        a.days = 7; a.anchor = at(10, 28, 0)
        expect(a.visibleDays == (0..<7).map { at(10, 28 + $0, 0) }, "7 days start on today, not the week's first day")
        a.step(1); expect(a.anchor == at(11, 4, 0), "7 days: next page is 7 days on")
        a.days = 5; a.anchor = at(10, 28, 0)
        expect(a.visibleDays == [at(10, 28, 0), at(10, 29, 0), at(10, 30, 0), at(11, 2, 0), at(11, 3, 0)], "5 days from Wednesday skip the weekend")
        a.step(1); expect(a.anchor == at(11, 4, 0), "5 days: next page starts after the last one shown")
        a.step(-1); expect(a.anchor == at(10, 28, 0), "5 days: back returns to the same page")
        a.anchor = at(10, 31, 0)
        expect(a.visibleDays == [at(10, 31, 0), at(11, 2, 0), at(11, 3, 0), at(11, 4, 0), at(11, 5, 0)], "5 days from Saturday: today first, even as a day off, then working days")
        a.step(1); expect(a.anchor == at(11, 6, 0), "5 days from Saturday: next page starts on the working day not yet shown")
        a.anchor = at(10, 28, 0)
        let picked = (0..<30).compactMap { _ -> Item? in a.selectNext(1); return a.selected }
        expect(!picked.isEmpty && !picked.contains { $0.start >= at(10, 31, 0) && $0.end <= at(11, 2, 0) }, "up and down skip events on days the 5 day week leaves out")
        a.selectedID = nil
        let gap = [at(10, 29, 0), at(10, 30, 0), at(11, 2, 0)]
        expect(dayShift(columns: 1, from: gap[1], in: gap) == 3 && dayShift(columns: -1, from: gap[2], in: gap) == -3 && dayShift(columns: 2, from: gap[2], in: gap) == 2 && dayShift(columns: 2, from: gap[1], in: gap) == 4, "dragging over the weekend gap moves by the days between columns")
        let xPost = Item(id: "x", calendarID: "", title: "X post", start: at(11, 10, 7, 51), end: at(11, 10, 8, 6), allDay: false, place: "", notes: "", showAs: .busy)
        let dentist = taskSpan(ToDo(id: "d", listID: "", title: "Dentist"), at: at(11, 10, 8), length: 1800), ln = lanes([xPost, dentist])
        expect(ln["x"]?.1 == 2 && ln["task:d"]?.1 == 2 && ln["x"]?.0 != ln["task:d"]?.0, "a timed task beside an event it overlaps gets its own lane, not on top")
        var short = xPost; short.start = at(11, 10, 7, 50); short.end = at(11, 10, 8)
        expect(lanes([short, dentist])["x"]?.1 == 1 && lanes([short, dentist], minLength: 1200)["x"]?.1 == 2, "a short event drawn taller than its time still gets its own lane")
        a.days = 3; a.anchor = at(10, 26, 0); a.now = at(10, 26, 23)
        a.tick(at(10, 28, 8)); expect(a.anchor == at(10, 28, 0) && a.now == at(10, 28, 8), "a new day: the view showing today moves on")
        a.anchor = at(10, 26, 0); a.now = at(10, 28, 8); a.tick(at(10, 29, 8)); expect(a.anchor == at(10, 26, 0), "a new day: a view paged elsewhere stays, even with today on screen")
        a.anchor = at(10, 26, 0); a.days = 5; a.now = now
        WorkWeek.days = [1, 3, 5]
        expect(a.visibleDays == [at(10, 26, 0), at(10, 27, 0), at(10, 29, 0)], "5 days = today, then the working days (Tue, Thu), as many as are ticked")
        WorkWeek.start = "Sunday"
        expect(startOfWeek(at(10, 31, 12)) == at(10, 25, 0) && monthGrid(now).first == at(9, 27, 0), "week starts Sunday")
        expect(a.visibleDays == [at(10, 26, 0), at(10, 27, 0), at(10, 29, 0)], "week start does not move the week view")
        expect(weekNumber(at(1, 4, 12)) == 2 && weekNumber(at(1, 3, 12)) == 1, "Sunday weeks count from January 1st")
        WorkWeek.days = [3]
        a.anchor = at(10, 27, 0)
        expect(a.visibleDays == [at(10, 27, 0)] && a.title == "Tuesday, October 27, 2026", "one working day: one column, one-day title")
        a.anchor = at(10, 26, 0)
        WorkWeek.days = []
        expect(a.visibleDays.count == 7, "no working days: the 5-day view shows the whole week")
        WorkWeek.start = "Saturday"
        expect(startOfWeek(now) == at(10, 24, 0), "week starts Saturday")
        WorkWeek.reset()
        expect(minuteText(8 * 60) == "8:00 AM" && minuteText(18 * 60 + 30) == "6:30 PM" && minuteText(0) == "12:00 AM" && minuteText(1440) == "Midnight" && minuteText(8 * 60, short: true) == "8 AM" && minuteText(18 * 60 + 30, short: true) == "6:30 PM", "working hours text")
    }
    MainActor.assumeIsolated {
        let a = AppState(store: Store(sample: true), today: now)
        for (typed, saved) in [("Pick up keys at the condo", "Pick up keys at the condo"), ("Buy rice for free", "Buy rice for free"), ("Call the bank Friday 3pm", "Call the bank")] {
            a.taskPanel.text = typed; a.commitTask()
            expect(a.store.todos.last?.title == saved, "task title kept: \(typed)")
        }
    }
    expect(shortDay(at(10, 23, 0), now: now) == "Fri" && shortDay(at(11, 14, 0), now: now) == "Nov 14", "task day text")

    // Phase 5: sun and moon (Tamarindo, the week of the mockups), travel extras.
    if let s = sunTimes(at(10, 26, 0), at: tamarindo) {
        expect(abs(s.rise.timeIntervalSince(at(10, 26, 5, 32))) < 150 && abs(s.set.timeIntervalSince(at(10, 26, 17, 21))) < 150, "Tamarindo Oct 26 sun: \(timeText(s.rise)) to \(timeText(s.set))")
    } else { expect(false, "Tamarindo has a sunrise") }
    expect(sunTimes(at(12, 21, 0), at: Geo(lat: 80, lon: 15)) == nil, "no sunrise at 80 north in December")
    let phases = (16...31).map { moonDay(at(10, $0, 0)) } + (1...12).map { moonDay(at(11, $0, 0)) }
    expect(phases.compactMap { $0 }.count == 4, "four moon phase days from Oct 16 to Nov 12")
    expect(moonDay(at(10, 18, 0)) == .firstHalf && moonDay(at(10, 25, 0)) == .full && moonDay(at(11, 1, 0)) == .lastHalf && moonDay(at(11, 9, 0)) == .new,
           "moon: half Oct 18, full Oct 25 (Oct 26 04:12 UTC), half Nov 1, new Nov 9")
    let oldExtra = try? JSONDecoder().decode(Extra.self, from: Data(#"{"emoji":"🏠","tags":[]}"#.utf8))
    expect(oldExtra?.emoji == "🏠" && oldExtra?.leave == nil && oldExtra?.from == nil, "extras saved before Phase 5 still read")
    var t1 = ev("x", at(10, 30, 19), at(10, 30, 21)), t2 = t1
    t2.leave = false; t2.from = .home; t2.noTravel = true
    expect(sameInCalendar(t1, t2), "travel choices stay on this Mac, never in the calendar")
    t1.geo = tamarindo
    expect(!sameInCalendar(t1, t2), "a place's map spot goes to the calendar")
    MainActor.assumeIsolated {
        sampleToday = now
        let a = AppState(store: Store(sample: true), today: now)
        a.planTravel()
        let dinner = a.store.soon.first { $0.title == "Dinner with Ana" }
        expect(dinner.flatMap { a.drive[$0.id] } == 25 && a.store.soon.filter { $0.geo == nil }.allSatisfy { a.drive[$0.id] == nil }, "sample drive times only for events with a place")
        sampleToday = nil
    }

    // Phase 6: alerts, time zones, menu bar words
    expect(startWord(at(10, 26, 10), now: at(10, 26, 10).addingTimeInterval(-295)) == "IN 5 MIN", "5 min before reads IN 5 MIN")
    expect(startWord(at(10, 26, 10), now: at(10, 26, 10).addingTimeInterval(5)) == "STARTING NOW", "starting now")
    expect(startWord(at(10, 26, 10), now: at(10, 26, 10, 5)) == "STARTED 5 MIN AGO", "after a snooze")
    let tenAM = ev("work", at(10, 26, 10), at(10, 26, 11))
    expect(fullScreenDue([tenAM], from: at(10, 26, 9, 54).addingTimeInterval(55), to: at(10, 26, 9, 55).addingTimeInterval(5), lead: 5) { _ in true }.count == 1, "full alert 5 min before")
    expect(fullScreenDue([tenAM], from: at(10, 26, 10), to: at(10, 26, 10).addingTimeInterval(10), lead: 0) { _ in true }.isEmpty, "a check landing exactly on the start shows it once, not twice")
    expect(fullScreenDue([tenAM], from: at(10, 26, 9, 59), to: at(10, 26, 10), lead: 0) { $0 != "work" }.isEmpty, "only the picked calendars")
    expect(zoneDiff(TimeZone(identifier: "Asia/Kolkata")!, at: now) == "11 h 30 min ahead", "half-hour zone")
    expect(zoneDiff(TimeZone(identifier: "America/Costa_Rica")!, at: now) == "same time", "same zone")
    expect(zoneOffset(TimeZone(identifier: "America/Los_Angeles")!, at: now) == "-1 h", "zone behind")
    expect(menuWords(2, now: now, today: []) == "W44", "week number in the menu bar")
    expect(menuWords(3, now: now, today: [ev("work", at(10, 26, 9, 46).addingTimeInterval(-1), at(10, 26, 11))]) != nil, "what's next")
    expect(menuWords(3, now: now, today: []) == nil, "a clear day shows the icon alone")
    expect(keySymbols("Control Option Space") == "⌃⌥Space", "quick add keys")
    // Phase 7: subscribed calendars
    weatherSelftest(expect)
    a4Selftest(expect)
    MainActor.assumeIsolated {
        let a = AppState(store: Store(sample: true), today: now)
        var redraws = 0
        let watching = a.objectWillChange.sink { redraws += 1 }
        a.addText = "Lunch"; a.now = now.addingTimeInterval(60)
        expect(redraws == 0, "a typed letter or a clock tick doesn't redraw the whole window")
        a.quick.text = "Lunch"; a.taskPanel.showDone = true; a.addBox.focused = true; a.panels.panelOpen = true
        expect(a.panels.panelOpen && redraws == 0, "quick add, the task list, the add box and panels don't touch the screens watching AppState")
        a.panels.tasksOpen = true
        expect(a.panels.tasksOpen && !a.panels.panelOpen, "the task list and event details share one side")
        a.panels.search = "dinner"; expect(!a.panels.tasksOpen, "search results take the side from the task list")
        a.panels.tasksOpen = true; expect(a.panels.search.isEmpty, "the task list button brings tasks back over a search")
        a.panels.openTaskID = "t1"; a.panels.panelOpen = true
        expect(a.panels.openTaskID == nil, "event details close a task's details")
        a.now = addDays(now, 1)
        expect(redraws == 1, "a new day does")
        watching.cancel()
    }
    let dayA = at(10, 26, 0), dayB = at(10, 27, 0), dayC = at(10, 28, 0)
    let spans = [it2("inside", at(10, 26, 9), at(10, 26, 10)), it2("two days", at(10, 26, 22), at(10, 27, 2)), it2("ends at midnight", at(10, 26, 23), dayB),
                 it2("no length", at(10, 27, 9), at(10, 27, 9)), it2("no length at midnight", dayB, dayB), it2("all day", dayB, dayC, allDay: true),
                 it2("runs for years", at(1, 1, 0), addDays(dayC, 900))]
    MainActor.assumeIsolated {
        let s = Store(sample: true), day = cal.startOfDay(for: now)
        s.show(from: addDays(day, -30), to: addDays(day, 30))
        let onDays = s.items.filter { $0.start >= addDays(day, -30) && $0.end > $0.start && !s.hidden.contains($0.calendarID) }
        expect(!onDays.isEmpty && onDays.allSatisfy { it in s.shown(on: it.start).contains { $0.id == it.id } }, "a day asked for by a date that isn't midnight still finds its events")
    }
    let grouped = itemsByDay(spans, from: dayA, to: addDays(dayC, 1))
    expect([dayA, dayB, dayC].allSatisfy { d in grouped[d]?.map(\.id) ?? [] == spans.filter { $0.start < addDays(d, 1) && $0.end > d }.map(\.id) } && grouped.count == 3, "events grouped by day land on the days the old scan found")
    MainActor.assumeIsolated {
        let d = UserDefaults.standard, before = (d.object(forKey: "hiddenCalendars") as? [String], d.string(forKey: "mode"))
        let a = AppState(store: Store(sample: true), today: now)
        a.store.hidden = ["selftest"]; a.mode = a.mode == .month ? .day : .month
        expect(d.object(forKey: "hiddenCalendars") as? [String] == before.0 && d.string(forKey: "mode") == before.1, "tests never change the saved calendar choice or view")
    }
    let whole = NewEventBubble.draft(title: "  ", start: at(11, 13, 9), end: at(11, 13, 10), allDay: true, place: " Cafe ", alert: 15)
    let timed = NewEventBubble.draft(title: "Dinner", start: at(11, 13, 19), end: at(11, 13, 20), allDay: false, place: "", alert: nil)
    expect(whole.title == "New event" && whole.allDay && whole.start == at(11, 13, 0) && whole.end == at(11, 14, 0) && whole.place == "Cafe" && whole.alertMinutes == 15
           && timed.title == "Dinner" && timed.start == at(11, 13, 19) && timed.end == at(11, 13, 20) && timed.alertMinutes == nil, "the double-click bubble: an all-day draft fills the day, an empty title is New event")
    // John 2026-11-04: a task couldn't be deleted. Delete takes it out with an Undo note; Undo puts it back in its list.
    MainActor.assumeIsolated {
        let a = AppState(store: Store(sample: true), today: now)
        guard let t = a.store.todos.first(where: { $0.a4 == nil }) else { expect(false, "the sample has a Reminders task"); return }
        var ticked = t; ticked.done.toggle()
        a.saveTask(ticked)
        a.panels.openTaskID = t.id
        a.deleteTask(ticked)
        let gone = !a.store.todos.contains { $0.id == t.id } && a.panels.openTaskID == nil && a.panels.toast?.text == t.title
        a.undo()
        let back = a.store.todos.first { $0.title == t.title && $0.listID == t.listID && $0.due == t.due }
        a.undo()  // the tick before the delete still undoes, though the task came back with a new id
        let first = a.store.todos.first { $0.id == back?.id }
        expect(gone && back?.done == ticked.done && first?.done == t.done && a.error == nil, "deleting a task: gone with an Undo note, Undo puts it back, and an earlier Undo still works")
        var a4 = t; a4.id = "a4-selftest"; a4.a4 = A4Task(); a.store.todos.append(a4)
        a.deleteTask(a4)
        expect(a.store.todos.contains { $0.id == a4.id } && a.error != nil, "an A4 task is not deleted")
    }
    // Nov 1 2026 is a clock-change day in the US; a 9:00 moved there stays 9:00.
    expect(NewEventBubble.moved(at(10, 28, 9, 30), to: at(11, 1, 0)) == at(11, 1, 9, 30) && NewEventBubble.ended(at(11, 13, 1), after: at(11, 13, 23)) == at(11, 14, 1)
           && NewEventBubble.ended(at(11, 13, 19, 1), after: at(11, 13, 19)) == at(11, 13, 19, 5), "the bubble: a new date keeps the clock time, an end before the start is the next day")
    let checked = at(10, 30, 9)
    expect(updateStatus(version: "0.8", last: nil, newer: nil, now: checked) == "Dateline 0.8 · not checked yet"
           && updateStatus(version: "0.8", last: checked, newer: false, now: checked.addingTimeInterval(60)).hasSuffix("you're up to date")
           && updateStatus(version: "0.8", last: checked, newer: true, now: addDays(checked, 2)).hasPrefix("Last checked Oct 30"), "updates: the status line")
    MainActor.assumeIsolated { assistantSelftest(expect) }
    MainActor.assumeIsolated { calendarSourceSelftest(expect) }
    MainActor.assumeIsolated { syncSelftest(expect) }
    licenseSelftest(expect)
    subSelftest(expect) { y, m, d, h, mi in cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))! }
    emailSelftest(expect) { y, m, d, h, mi in cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))! }
    accountsSelftest(expect) { y, m, d, h, mi in cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))! }
    print(fails == 0 ? "selftest: all passed" : "selftest: \(fails) failed")
    return fails == 0 ? 0 : 1
}

