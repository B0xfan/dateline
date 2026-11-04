// The iCalendar file reader and repeat rules. Pure, covered by --selftest; used by subscribed calendars and accounts.
import Foundation

// One VEVENT, as read from the file.
struct ICalEvent: Equatable {
    var uid = "", title = "", place = "", notes = ""
    var start = Date(), end = Date()
    var allDay = false, free = false, cancelled = false
    var tz = TimeZone.current
    var rule: [String: String]? = nil
    var exdates: Set<Date> = []
    var recurrenceID: Date? = nil  // set on a changed copy of one occurrence of a repeating event
    var url = ""  // Phase 8 accounts: the event's web link, and its alerts as offsets from the start
    var alarms: [TimeInterval] = []
    var files: [Attach] = []
}

// MARK: reading the file

func parseICS(_ text: String) -> [ICalEvent] {
    var lines: [String] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
        if let f = raw.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else { lines.append(String(raw)) }
    }
    var out: [ICalEvent] = [], props: [(String, [String: String], String)]? = nil, depth = 0, alarms: [TimeInterval] = []
    for l in lines {
        guard let (name, params, value) = icsLine(l) else { continue }
        if name == "BEGIN" { if props == nil { if value.uppercased() == "VEVENT" { props = []; depth = 0; alarms = [] } } else { depth += 1 }; continue }
        if name == "END", props != nil {
            if depth > 0 { depth -= 1 } else { if var e = icsEvent(props!) { e.alarms = alarms; out.append(e) }; props = nil }
            continue
        }
        if depth == 0 { props?.append((name, params, value)) }  // never an alarm's own SUMMARY
        else if depth == 1, props != nil, name == "TRIGGER", params["VALUE"]?.uppercased() != "DATE-TIME", params["RELATED"]?.uppercased() != "END" { alarms.append(icsDuration(value)) }
    }
    return out
}

// "DTSTART;TZID="America/New_York":20261030T160000" → name, parameters, value. A colon inside quotes is not the split.
func icsLine(_ l: String) -> (String, [String: String], String)? {
    var quoted = false, split: String.Index?
    for i in l.indices { if l[i] == "\"" { quoted.toggle() } else if l[i] == ":" && !quoted { split = i; break } }
    guard let split else { return nil }
    var parts = l[..<split].split(separator: ";").map(String.init)
    guard !parts.isEmpty else { return nil }
    let name = parts.removeFirst().uppercased()
    var params: [String: String] = [:]
    for p in parts { let kv = p.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
    return (name, params, String(l[l.index(after: split)...]))
}

func icsText(_ v: String) -> String {
    // One pass, left to right, so an escaped backslash before an n stays a backslash and an n.
    var out = "", escaped = false
    for ch in v {
        if !escaped { if ch == "\\" { escaped = true } else { out.append(ch) }; continue }
        escaped = false
        if ch == "n" || ch == "N" { out.append("\n") } else if ",;\\".contains(ch) { out.append(ch) } else { out.append("\\"); out.append(ch) }
    }
    return escaped ? out + "\\" : out
}

// Making a date reader is the slow part of reading a big file, so each kind is made once. Reading dates with one is safe from any thread.
private let icsFormatterLock = NSLock()
private var icsFormatters: [String: DateFormatter] = [:]
private func icsFormatter(_ tz: TimeZone, allDay: Bool) -> DateFormatter {
    icsFormatterLock.lock(); defer { icsFormatterLock.unlock() }
    let key = "\(allDay) \(tz.identifier)"
    if let f = icsFormatters[key] { return f }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
    icsFormatters[key] = f
    return f
}

// A date or date-time value: (moment, all-day, its time zone). All-day dates are midnight here.
func icsDate(_ v: String, _ params: [String: String]) -> (Date, Bool, TimeZone)? {
    let allDay = params["VALUE"] == "DATE" || v.count == 8
    let utc = v.hasSuffix("Z")
    // shortcut: a TZID that is not a standard place name (some Outlook files) reads as this Mac's time zone; map Windows names if a real calendar needs it.
    let tz = utc ? TimeZone(identifier: "UTC")! : params["TZID"].flatMap { id in TimeZone(identifier: id) ?? TimeZone(identifier: id.split(separator: "/").suffix(2).joined(separator: "/")) } ?? cal.timeZone
    guard let d = icsFormatter(allDay ? cal.timeZone : tz, allDay: allDay).date(from: String(v.prefix(allDay ? 8 : 15))) else { return nil }
    return (d, allDay, tz)
}

// "PT1H30M", "P1D", "-PT15M" → seconds.
func icsDuration(_ s: String) -> TimeInterval {
    var total = 0.0, num = ""
    for ch in s {
        if ch.isNumber { num.append(ch); continue }
        let v = Double(num) ?? 0
        num = ""
        switch ch { case "W": total += v * 604800; case "D": total += v * 86400; case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: break }
    }
    return s.hasPrefix("-") ? -total : total
}

private func icsEvent(_ props: [(String, [String: String], String)]) -> ICalEvent? {
    var e = ICalEvent(), end: Date?, duration: TimeInterval?, hasStart = false
    for (name, params, v) in props {
        switch name {
        case "UID": e.uid = v
        case "SUMMARY": e.title = icsText(v)
        case "LOCATION": e.place = icsText(v)
        case "DESCRIPTION": e.notes = icsText(v)
        case "TRANSP": e.free = v.uppercased() == "TRANSPARENT"
        case "STATUS": e.cancelled = v.uppercased() == "CANCELLED"
        case "DTSTART": guard let (d, a, tz) = icsDate(v, params) else { return nil }; e.start = d; e.allDay = a; e.tz = tz; hasStart = true
        case "DTEND": end = icsDate(v, params)?.0
        case "DURATION": duration = icsDuration(v)
        case "RRULE": e.rule = Dictionary(v.split(separator: ";").compactMap { p -> (String, String)? in
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init); return kv.count == 2 ? (kv[0].uppercased(), kv[1].uppercased()) : nil }, uniquingKeysWith: { a, _ in a })
        case "EXDATE": for one in v.split(separator: ",") { if let d = icsDate(String(one), params)?.0 { e.exdates.insert(d) } }
        case "RECURRENCE-ID": e.recurrenceID = icsDate(v, params)?.0
        case "URL": e.url = v
        case "ATTACH" where params["VALUE"]?.uppercased() != "BINARY":  // shortcut: files packed inside the event itself are left out; none of iCloud's are
            let name = params["FILENAME"] ?? params["X-APPLE-FILENAME"] ?? URL(string: v)?.lastPathComponent ?? v
            e.files.append(Attach(name: name.isEmpty ? v : name, url: v, size: params["SIZE"].flatMap { Int($0) }, id: params["MANAGED-ID"], type: params["FMTTYPE"] ?? ""))
        default: break
        }
    }
    guard hasStart else { return nil }
    e.end = end ?? duration.map { e.start.addingTimeInterval($0) } ?? (e.allDay ? addDays(e.start, 1) : e.start)
    if e.end < e.start { e.end = e.start }
    return e
}

// MARK: repeats

// Every start of `e` that overlaps a..b (the first one is DTSTART). Repeats by day, week, month and year, with the usual parts.
func occurrences(_ e: ICalEvent, from a: Date, to b: Date) -> [Date] {
    let len = e.end.timeIntervalSince(e.start)
    func overlaps(_ d: Date) -> Bool { d < b && (d.addingTimeInterval(len) > a || (len == 0 && d >= a)) }
    // shortcut: rules by the hour or minute, or with BYSETPOS/BYWEEKNO/BYYEARDAY, show the first time only; add them if a real calendar needs one.
    guard let r = e.rule, let freq = r["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq),
          r["BYSETPOS"] == nil, r["BYWEEKNO"] == nil, r["BYYEARDAY"] == nil else { return overlaps(e.start) ? [e.start] : [] }
    var c = Calendar(identifier: .gregorian)
    c.timeZone = e.allDay ? cal.timeZone : e.tz
    let names = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    c.firstWeekday = (names.firstIndex(of: r["WKST"] ?? "MO") ?? 1) + 1
    let step = max(1, Int(r["INTERVAL"] ?? "") ?? 1)
    // A feed can say any gap. Over 1000 the next time is years away, and step * period below could overflow and crash.
    guard step <= 1000 else { return overlaps(e.start) ? [e.start] : [] }
    let count = Int(r["COUNT"] ?? "")
    let until = r["UNTIL"].flatMap { v -> Date? in
        if e.allDay { return icsDate(String(v.prefix(8)), [:])?.0 }  // an all-day event ends on a date, whatever form it is written in
        return icsDate(v.count == 8 ? v + "T235959" : v, ["TZID": e.tz.identifier])?.0  // no Z: the event's own time zone; a bare date means all of that day
    }
    // BYDAY: "MO,WE" or "2TU", "-1FR" → (which one in the month, 0 = every; weekday 1 = Sunday)
    let byDay: [(Int, Int)] = (r["BYDAY"] ?? "").split(separator: ",").compactMap { p in
        guard p.count >= 2, let w = names.firstIndex(of: String(p.suffix(2))) else { return nil }
        return (Int(p.dropLast(2)) ?? 0, w + 1)
    }
    let byMonthDay = (r["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
    let byMonth = (r["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
    let t = c.dateComponents([.hour, .minute, .second], from: e.start)
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        guard let x = c.date(from: DateComponents(year: y, month: m, day: d, hour: t.hour, minute: t.minute, second: t.second)),
              c.component(.month, from: x) == m else { return nil }  // Feb 31 does not exist: skipped, as the rules say
        return x
    }
    func inMonth(_ y: Int, _ m: Int) -> [Date] {
        guard let first = day(y, m, 1) else { return [] }
        let last = c.range(of: .day, in: .month, for: first)!.count
        if !byDay.isEmpty {
            let hits = byDay.flatMap { n, w -> [Date] in
                let all = (1...last).compactMap { day(y, m, $0) }.filter { c.component(.weekday, from: $0) == w }
                if n == 0 { return all }
                let i = n > 0 ? n - 1 : all.count + n
                return all.indices.contains(i) ? [all[i]] : []
            }
            // Both parts set (Friday the 13th): the day must match both.
            return byMonthDay.isEmpty ? hits : hits.filter { d in byMonthDay.contains { ($0 > 0 ? $0 : last + 1 + $0) == c.component(.day, from: d) } }
        }
        let days = byMonthDay.isEmpty ? [c.component(.day, from: e.start)] : byMonthDay
        return days.compactMap { day(y, m, $0 > 0 ? $0 : last + 1 + $0) }
    }
    // A date-only exception on a timed event removes that date in the event's own time zone. icsDate reads it as that date's midnight here.
    func offByDate(_ d: Date) -> Bool {
        !e.allDay && !e.exdates.isEmpty && cal.date(from: c.dateComponents([.year, .month, .day], from: d)).map(e.exdates.contains) == true
    }
    let y0 = c.component(.year, from: e.start), m0 = c.component(.month, from: e.start)
    let week0 = c.dateInterval(of: .weekOfYear, for: e.start)!.start
    var out: [Date] = [], made = 0
    for period in 0..<5000 {  // shortcut: 5000 steps (13 years of daily repeats) from the first time; later times of an older daily event are not shown
        var list: [Date]
        switch freq {
        case "DAILY":
            guard let d = c.date(byAdding: .day, value: period * step, to: e.start) else { return out }
            list = [d]
        case "WEEKLY":
            guard let wk = c.date(byAdding: .weekOfYear, value: period * step, to: week0) else { return out }
            let days = byDay.isEmpty ? [c.component(.weekday, from: e.start)] : byDay.map(\.1)
            list = days.compactMap { w in
                let off = (w - c.firstWeekday + 7) % 7
                guard let d = c.date(byAdding: .day, value: off, to: wk) else { return nil }
                return day(c.component(.year, from: d), c.component(.month, from: d), c.component(.day, from: d))
            }
        case "MONTHLY":
            let mm = m0 - 1 + period * step
            list = inMonth(y0 + mm / 12, mm % 12 + 1)
        default:
            // Every Monday of the year with no month named means all twelve months; "2nd Monday" with no month keeps the first month.
            let everyMonth = !byDay.isEmpty && byDay.allSatisfy { $0.0 == 0 }
            list = (byMonth.isEmpty ? (everyMonth ? Array(1...12) : [m0]) : byMonth).flatMap { inMonth(y0 + period * step, $0) }
        }
        // BYMONTH narrows every rule; BYDAY and BYMONTHDAY narrow a daily one (weekly, monthly and yearly use them to pick days above).
        list = list.filter { d in
            (byMonth.isEmpty || byMonth.contains(c.component(.month, from: d))) && (freq != "DAILY" ||
            ((byDay.isEmpty || byDay.contains { $0.1 == c.component(.weekday, from: d) }) && (byMonthDay.isEmpty || byMonthDay.contains(c.component(.day, from: d)))))
        }
        if period == 0 { list.append(e.start) }  // the first time always counts, even off the rule's days
        for d in Set(list).sorted() where d >= e.start {
            if let until, d > until { return out }
            made += 1
            if let count, made > count { return out }
            if d >= b { return out }
            if overlaps(d) && !e.exdates.contains(d) && !offByDate(d) { out.append(d) }
        }
    }
    return out
}
