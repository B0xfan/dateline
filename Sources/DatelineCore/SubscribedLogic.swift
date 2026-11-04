// Phase 7 (F4, F5, approved mockup): calendars from a web address, and a short list of ready-made ones.
// Read-only and kept by Dateline on this Mac: the address is read every hour, day or week, and the last copy stays when it stops working.
import Foundation
import SwiftUI

public struct Sub: Codable, Identifiable, Equatable {
    public var id = "sub-" + UUID().uuidString
    public var url: String  // https address; empty for a calendar worked out here (`kind`)
    public var kind: String? = nil  // "moon" or "sun": made on this Mac, no address
    public var name: String
    public var color: Int  // a place in Palette.tags
    public var hours = 24  // how often it updates
    public var alerts = false
    public var updated: Date? = nil
    public var problem: String? = nil  // why the last update failed; the last events stay
    public init(id: String = "sub-" + UUID().uuidString, url: String, kind: String? = nil, name: String, color: Int, hours: Int = 24, alerts: Bool = false, updated: Date? = nil, problem: String? = nil) { self.id = id; self.url = url; self.kind = kind; self.name = name; self.color = color; self.hours = hours; self.alerts = alerts; self.updated = updated; self.problem = problem }
}

public func isSub(_ calendarID: String) -> Bool { calendarID.hasPrefix("sub-") }

// The events of one subscribed calendar between two dates, as Dateline items. A changed occurrence replaces the one it changes.
public func subItems(_ s: Sub, _ events: [ICalEvent], from a: Date, to b: Date) -> [Item] {
    var changed: [String: Set<Date>] = [:]
    for e in events { if let r = e.recurrenceID { changed[e.uid, default: []].insert(r) } }
    var out: [Item] = []
    for e in events where !(e.cancelled && e.recurrenceID == nil) {
        let len = e.end.timeIntervalSince(e.start)
        let starts = e.recurrenceID != nil ? (e.cancelled ? [] : occurrences(ICalEvent(start: e.start, end: e.end), from: a, to: b))
            : occurrences(e, from: a, to: b).filter { !(changed[e.uid]?.contains($0) ?? false) }
        for d in starts {
            let at = e.recurrenceID ?? d  // the occurrence's own key stays the same when it was moved
            out.append(Item(id: "\(s.id)/\(e.uid)|\(Int(at.timeIntervalSince1970))", calendarID: s.id, title: e.title, start: d, end: d.addingTimeInterval(len),
                            allDay: e.allDay, place: e.place, notes: e.notes, showAs: e.free ? .free : .busy,
                            alerts: s.alerts && !e.allDay ? [d] : []))
        }
    }
    return out
}

// The calendars made on this Mac: one all-day line a day.
@MainActor public func madeItems(_ s: Sub, from a: Date, to b: Date) -> [Item] {
    var out: [Item] = [], d = cal.startOfDay(for: a)
    while d < b {
        var title: String?
        if s.kind == "moon", let m = moonDay(d) {
            title = [MoonDay.new: "🌑 New moon", .firstHalf: "🌓 First quarter", .full: "🌕 Full moon", .lastHalf: "🌗 Last quarter"][m]
        } else if s.kind == "sun", let g = Here.shared.spot, let t = sunTimes(d, at: g) {
            title = "☀ " + timeText(t.rise, short: false) + " · " + timeText(t.set, short: false)
        }
        if let title {
            out.append(Item(id: "\(s.id)/\(Int(d.timeIntervalSince1970))", calendarID: s.id, title: title, start: d, end: addDays(d, 1),
                            allDay: true, place: "", notes: "", showAs: .free))
        }
        d = addDays(d, 1)
    }
    return out
}

// webcal:// is how calendar links are often shared; it is plain https underneath.
public func subAddress(_ text: String) -> URL? {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.lowercased().hasPrefix("webcal://") { t = "https://" + t.dropFirst(9) }
    guard let u = URL(string: t), ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
    return u
}

// Downloads and reads a calendar; the file's text comes back so it can be kept for when the address stops working.
public func downloadCalendar(_ u: URL) async -> Result<(String, [ICalEvent]), Failure> {
    var req = URLRequest(url: u, timeoutInterval: 30)
    req.setValue("text/calendar", forHTTPHeaderField: "Accept")
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { return .failure(Failure("The address answered with error \(h.statusCode).")) }
        guard data.count < 20_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("BEGIN:VCALENDAR") else { return .failure(Failure("That address is not a calendar. Look for a link ending in .ics or starting with webcal://.")) }
        let events = await Task.detached { parseICS(text) }.value
        return .success((text, events))
    } catch { return .failure(Failure("Couldn't reach it: \(error.localizedDescription)")) }
}

// The kept copies of these calendars; one with no copy yet is left out.
public func readSubFiles(_ ids: [String], in folder: URL) -> [String: [ICalEvent]] {
    var read: [String: [ICalEvent]] = [:]
    for id in ids {
        if let text = try? String(contentsOf: folder.appendingPathComponent(id + ".ics"), encoding: .utf8) { read[id] = parseICS(text) }
    }
    return read
}

// MARK: the Store side

extension Store {
    public static let subFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dateline/Subscribed")

    public var subInfos: [CalInfo] { subs.map { CalInfo(id: $0.id, title: $0.name, account: "Subscribed", color: Palette.tags[$0.color % Palette.tags.count], writable: false) } }

    public func sub(_ id: String) -> Sub? { subs.first { $0.id == id } }

    public func subEvents(from a: Date, to b: Date) -> [Item] {
        subs.flatMap { s in (s.kind == nil ? subItems(s, subParsed[s.id] ?? [], from: a, to: b) : madeItems(s, from: a, to: b)).map(decorated) }
    }

    // After a calendar is added, renamed, recolored or removed.
    public func subsChanged() {
        calendars = calendars.filter { !isSub($0.id) } + subInfos
        refetch()
    }

    // The files are read in the background, so a big one doesn't hold the window back. `ready` runs once they are in:
    // Apple Calendar is read after that, so there is no half-filled calendar and alerts never check without these events.
    public func loadSubs(then ready: @escaping @MainActor () -> Void) {
        if let v: [Sub] = load("subscriptions") { subs = v }
        let ids = subs.filter { $0.kind == nil }.map(\.id), folder = Self.subFolder
        guard !ids.isEmpty else { ready(); return }
        Task.detached(priority: .userInitiated) {
            let read = readSubFiles(ids, in: folder)
            await MainActor.run { self.adoptSubs(read); ready() }
        }
    }

    // What the launch read found. A download that finished first is newer, and a calendar removed meanwhile stays removed.
    public func adoptSubs(_ read: [String: [ICalEvent]]) {
        for (id, events) in read where sub(id) != nil && subParsed[id] == nil { subParsed[id] = events }
    }

    // Adds a calendar; `text`/`events` when the Subscribe window already downloaded it.
    public func subscribe(_ s: Sub, text: String? = nil, events: [ICalEvent]? = nil) {
        var s = s
        if let text, let events { keep(text, for: s.id); subParsed[s.id] = events; s.updated = Date() }
        subs.append(s)
        subsChanged()
        if s.kind == nil && text == nil { refreshSub(s.id) }
    }

    public func unsubscribe(_ id: String) {
        subs.removeAll { $0.id == id }
        subParsed[id] = nil
        hidden.remove(id)
        for i in sets.indices { sets[i].calendars.removeAll { $0 == id } }
        try? FileManager.default.removeItem(at: Self.subFolder.appendingPathComponent(id + ".ics"))
        subsChanged()
    }

    public func editSub(_ id: String, _ change: (inout Sub) -> Void) {
        guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
        change(&subs[i])
        subsChanged()
    }

    // Every 5 minutes: the calendars whose time has come. A failed one tries again after an hour.
    public func refreshSubs() {
        guard access != .sample else { return }
        let now = Date()
        for s in subs where s.kind == nil {
            let last = subTried[s.id] ?? s.updated ?? .distantPast
            if now.timeIntervalSince(last) >= Double(s.problem == nil ? s.hours : min(s.hours, 1)) * 3600 { refreshSub(s.id) }
        }
    }

    public func refreshSub(_ id: String) {
        guard access != .sample, let s = sub(id), s.kind == nil else { return }
        subTried[id] = Date()
        guard let u = subAddress(s.url) else { editSub(id) { $0.problem = "The address is not a web address." }; return }
        Task {
            let r = await downloadCalendar(u)
            guard sub(id) != nil else { return }  // removed while it downloaded
            switch r {
            case .success(let (text, events)):
                keep(text, for: id)
                subParsed[id] = events
                editSub(id) { $0.updated = Date(); $0.problem = nil }
            case .failure(let f): editSub(id) { $0.problem = f.message }
            }
        }
    }

    private func keep(_ text: String, for id: String) {
        try? FileManager.default.createDirectory(at: Self.subFolder, withIntermediateDirectories: true)
        try? text.write(to: Self.subFolder.appendingPathComponent(id + ".ics"), atomically: true, encoding: .utf8)
    }
}

// MARK: the ready-made list (free public addresses, each checked to work on 2026-10-28; moon and sun are worked out on this Mac)

public struct ReadyMade: Identifiable {
    public let name, about, group: String
    public var url = "", kind: String? = nil
    public let color: Int
    public var id: String { name }
}

public let readyMade = [
    ReadyMade(name: "Costa Rica holidays", about: "Public holidays and days off, in English", group: "Holidays",
              url: "https://calendar.google.com/calendar/ical/en.cr%23holiday%40group.v.calendar.google.com/public/basic.ics", color: 0),
    ReadyMade(name: "Feriados de Costa Rica", about: "The same holidays, in Spanish", group: "Holidays",
              url: "https://calendar.google.com/calendar/ical/es.cr%23holiday%40group.v.calendar.google.com/public/basic.ics", color: 0),
    ReadyMade(name: "United States holidays", about: "Federal holidays plus Thanksgiving, Halloween and others", group: "Holidays",
              url: "https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics", color: 4),
    ReadyMade(name: "Moon phases", about: "New moon, full moon and the quarters", group: "Sky", kind: "moon", color: 7),
    ReadyMade(name: "Sunrise and sunset", about: "For where this Mac is, one all-day note each day", group: "Sky", kind: "sun", color: 1),
    ReadyMade(name: "Costa Rica national football team", about: "Match dates and kick-off times", group: "Sports",
              url: "https://pub.fotmob.com/prod/pub/api/v2/calendar/team/6705.ics", color: 2),
]

// MARK: the Subscribe window (approved mockup: web address tab, ready-made tab)

// The name the calendar gives itself (X-WR-CALNAME), if any.
public func calendarName(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline).lazy.compactMap { icsLine(String($0)) }.first { $0.0 == "X-WR-CALNAME" }
        .map { icsText($0.2).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
}

// A small calendar file with the awkward parts real ones have: a folded line, escapes, an alarm inside an event, time zones,
// repeats by week (with a skipped and a moved week), by month and by year, and a cancelled event.
let sampleICS = """
BEGIN:VCALENDAR\r
X-WR-CALNAME:Grade 5 schedule\r
BEGIN:VTIMEZONE\r
TZID:America/Costa_Rica\r
BEGIN:STANDARD\r
DTSTART:19700101T000000\r
TZOFFSETFROM:-0600\r
TZOFFSETTO:-0600\r
END:STANDARD\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
UID:meet\r
DTSTART;TZID=America/Costa_Rica:20261030T160000\r
DTEND;TZID=America/Costa_Rica:20261030T170000\r
SUMMARY:Parent meeting\r
DESCRIPTION:Room 4\\, upstairs\\nBring the form\r
LOCATION:Escuela\r
BEGIN:VALARM\r
SUMMARY:Alarm text that is not the title\r
TRIGGER:-PT15M\r
END:VALARM\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:trip\r
DTSTART;VALUE=DATE:20261102\r
SUMMARY:Field trip to the Museo \r
 Nacional\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:swim\r
DTSTART:20261028T220000Z\r
DURATION:PT45M\r
RRULE:FREQ=WEEKLY;BYDAY=WE,FR;COUNT=6\r
EXDATE:20261104T220000Z\r
SUMMARY:Swim class\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:swim\r
RECURRENCE-ID:20261106T220000Z\r
DTSTART:20261106T230000Z\r
DTEND:20261106T234500Z\r
SUMMARY:Swim class (late)\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:board\r
DTSTART;TZID="America/Costa_Rica":20261110T180000\r
DTEND;TZID="America/Costa_Rica":20261110T190000\r
RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20270301T000000Z\r
SUMMARY:School board\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:thanks\r
DTSTART;VALUE=DATE:20261126\r
DTEND;VALUE=DATE:20261127\r
RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH\r
SUMMARY:Thanksgiving\r
TRANSP:TRANSPARENT\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:last\r
DTSTART;VALUE=DATE:20261031\r
RRULE:FREQ=MONTHLY;COUNT=4\r
SUMMARY:Month end\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:gone\r
DTSTART;VALUE=DATE:20261113\r
STATUS:CANCELLED\r
SUMMARY:Cancelled day\r
END:VEVENT\r
END:VCALENDAR\r
"""

public func subSelftest(_ expect: (Bool, String) -> Void, at: (Int, Int, Int, Int, Int) -> Date) {
    let ev = parseICS(sampleICS)
    expect(ev.count == 8, "8 events read (the time zone block and the alarm are not events)")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dateline-selftest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? sampleICS.write(to: dir.appendingPathComponent("a.ics"), atomically: true, encoding: .utf8)
    let read = readSubFiles(["a", "no-copy"], in: dir)
    try? FileManager.default.removeItem(at: dir)
    expect(read.count == 1 && read["a"]?.count == 8, "launch read: kept copies are read, a calendar with no copy is left out")
    MainActor.assumeIsolated {
        let s = Store(sample: true)
        s.subs = [Sub(id: "a", url: "x", name: "A", color: 0), Sub(id: "b", url: "x", name: "B", color: 0)]
        s.subParsed = ["b": []]
        s.adoptSubs(["a": ev, "b": ev, "gone": ev])
        expect(s.subParsed["a"]?.count == 8 && s.subParsed["b"]?.isEmpty == true && s.subParsed["gone"] == nil, "launch read: a newer download stays, a removed calendar stays removed")
    }
    func times(_ lines: String, _ a: String, _ b: String) -> Int {
        guard let e = parseICS("BEGIN:VEVENT\nUID:u\n\(lines)\nEND:VEVENT").first, let x = icsDate(a, [:])?.0, let y = icsDate(b, [:])?.0 else { return -1 }
        return occurrences(e, from: x, to: y).count
    }
    expect(times("DTSTART:20261102T150000Z\nRRULE:FREQ=WEEKLY;UNTIL=20261116", "20261101", "20261201") == 3, "a bare end date keeps that day's time on a timed event")
    expect(times("DTSTART;VALUE=DATE:20261102\nRRULE:FREQ=WEEKLY;UNTIL=20261116T000000Z", "20261101", "20261201") == 3, "an end time in UTC keeps the last day of an all-day event")
    expect(times("DTSTART:20261102T150000\nRRULE:FREQ=WEEKLY;COUNT=3\nEXDATE;VALUE=DATE:20261109", "20261101", "20261201") == 2, "a date-only exception removes a timed event's day")
    expect(times("DTSTART;TZID=Europe/Madrid:20261102T003000\nRRULE:FREQ=WEEKLY;COUNT=3\nEXDATE;VALUE=DATE:20261109", "20261101", "20261201") == 2, "a date-only exception goes by the date where the event is")
    expect(times("DTSTART:20261113T100000\nRRULE:FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", "20261101", "20271231") == 2, "Friday the 13th matches both parts")
    expect(times("DTSTART:20261102T100000\nRRULE:FREQ=YEARLY;BYDAY=MO", "20261101", "20261231") == 9, "every Monday of the year, with no month named")
    expect(icsText("C:\\\\new\\nnext\\, end") == "C:\\new\nnext, end", "an escaped backslash before an n stays a backslash and an n")
    let meet = ev.first { $0.uid == "meet" }
    expect(meet?.title == "Parent meeting" && meet?.notes == "Room 4, upstairs\nBring the form", "title and escaped notes; the alarm's text is not the title")
    expect(meet?.start == at(2026, 10, 30, 16, 0) && meet?.end == at(2026, 10, 30, 17, 0), "time zone by name")
    let trip = ev.first { $0.uid == "trip" }
    expect(trip?.title == "Field trip to the Museo Nacional" && trip?.allDay == true && trip?.end == at(2026, 11, 3, 0, 0), "folded line; an all-day date without an end is one day")
    let s = Sub(id: "sub-t", url: "", name: "t", color: 0)
    let items = subItems(s, ev, from: at(2026, 10, 1, 0, 0), to: at(2027, 12, 31, 0, 0))
    let swim = items.filter { $0.title.hasPrefix("Swim") }.sorted { $0.start < $1.start }.map { ($0.title, $0.start) }
    // Wed 28, Fri 30, Wed 4 (skipped), Fri 6 (moved to 5 PM), Wed 11, Fri 13: 4 PM here (22:00 UTC).
    expect(swim.count == 5 && swim.map(\.1) == [at(2026, 10, 28, 16, 0), at(2026, 10, 30, 16, 0), at(2026, 11, 6, 17, 0), at(2026, 11, 11, 16, 0), at(2026, 11, 13, 16, 0)]
           && swim[2].0 == "Swim class (late)", "weekly repeat: count, skipped week, moved week")
    expect(items.first { $0.title == "Swim class" }?.end == at(2026, 10, 28, 16, 45), "duration")
    let board = items.filter { $0.title == "School board" }.map(\.start)
    expect(board == [at(2026, 11, 10, 18, 0), at(2026, 12, 8, 18, 0), at(2027, 1, 12, 18, 0), at(2027, 2, 9, 18, 0)], "second Tuesday each month, until March")
    expect(items.filter { $0.title == "Thanksgiving" }.map(\.start) == [at(2026, 11, 26, 0, 0), at(2027, 11, 25, 0, 0)], "fourth Thursday of November each year")
    expect(items.first { $0.title == "Thanksgiving" }?.showAs == .free, "TRANSP:TRANSPARENT shows as free")
    expect(items.filter { $0.title == "Month end" }.map(\.start) == [at(2026, 10, 31, 0, 0), at(2026, 12, 31, 0, 0), at(2027, 1, 31, 0, 0), at(2027, 3, 31, 0, 0)],
           "the 31st skips months without one, and the count only counts real ones")
    expect(!items.contains { $0.title == "Cancelled day" }, "cancelled events are left out")
    let week = subItems(s, ev, from: at(2026, 11, 1, 0, 0), to: at(2026, 11, 8, 0, 0))
    expect(week.map(\.title).sorted() == ["Field trip to the Museo Nacional", "Swim class (late)"], "only what overlaps the week")
    expect(Set(items.map(\.id)).count == items.count, "every occurrence has its own id")
    var alerting = s; alerting.alerts = true
    expect(subItems(alerting, ev, from: at(2026, 10, 30, 0, 0), to: at(2026, 10, 31, 0, 0)).first { $0.title == "Parent meeting" }?.alerts == [at(2026, 10, 30, 16, 0)]
           && items.allSatisfy { $0.alerts.isEmpty }, "alerts only when switched on")
    expect(subAddress("webcal://example.com/a.ics")?.absoluteString == "https://example.com/a.ics" && subAddress("ftp://x/y") == nil && subAddress("hello") == nil, "web addresses")
    expect(calendarName(sampleICS) == "Grade 5 schedule", "the calendar's own name")
    expect(icsDuration("P1DT2H") == 93600 && icsDuration("-PT15M") == -900, "durations")
    // Review fixes: rule filters, the first time off the rule's days, UNTIL in the event's own zone, the name's escapes.
    let more = parseICS("""
    BEGIN:VCALENDAR
    X-WR-CALNAME;VALUE=TEXT:Grade 5\\, Room 4
    BEGIN:VEVENT
    UID:weekdays
    SUMMARY:School day
    DTSTART:20261030T090000
    RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=3
    END:VEVENT
    BEGIN:VEVENT
    UID:offday
    SUMMARY:Club
    DTSTART:20261027T100000
    RRULE:FREQ=WEEKLY;BYDAY=WE,FR;COUNT=4
    END:VEVENT
    BEGIN:VEVENT
    UID:hawaii
    SUMMARY:Call
    DTSTART;TZID=Pacific/Honolulu:20261124T180000
    RRULE:FREQ=WEEKLY;UNTIL=20261201T180000
    END:VEVENT
    END:VCALENDAR
    """)
    let mi = subItems(s, more, from: at(2026, 10, 1, 0, 0), to: at(2027, 1, 1, 0, 0))
    expect(mi.filter { $0.title == "School day" }.map(\.start).sorted() == [at(2026, 10, 30, 9, 0), at(2026, 11, 2, 9, 0), at(2026, 11, 3, 9, 0)], "daily on weekdays skips the weekend")
    expect(mi.filter { $0.title == "Club" }.map(\.start).sorted() == [at(2026, 10, 27, 10, 0), at(2026, 10, 28, 10, 0), at(2026, 10, 30, 10, 0), at(2026, 11, 4, 10, 0)], "the first time counts even off the rule's days")
    expect(mi.filter { $0.title == "Call" }.count == 2, "UNTIL without Z is in the event's own time zone")
    expect(calendarName("""
    BEGIN:VCALENDAR
    X-WR-CALNAME;VALUE=TEXT:Grade 5\\, Room 4
    """) == "Grade 5, Room 4", "the name with a parameter and an escape")
}

