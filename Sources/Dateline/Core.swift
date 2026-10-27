// Pure logic, no calendar access: the type-a-sentence parser and the date maths behind the views. Covered by --selftest.
import Foundation

enum ShowAs: String, CaseIterable { case busy = "Busy", free = "Free", maybe = "Maybe" }

// What the add box understood from a sentence (A1, A2).
struct Parsed: Equatable {
    var title = ""
    var start: Date
    var end: Date
    var allDay = false
    var place = ""
    var showAs = ShowAs.busy
    var lengthGiven = false  // an end time or "for 2 hours" was written
    var dateGiven = false  // a day or a time was written (a task without one has no due date)
    // Short codes (Phase 2): "/Personal" picks a calendar, "-a15m" an alert, "-r1w" a repeat.
    var calendarCode: String? = nil
    var alertMinutes: Int? = nil
    var repeats: Repeat? = nil
}

struct Repeat: Equatable {
    let unit: Character  // d, w, m or y
    let n: Int
    var text: String {
        let name = ["d": "day", "w": "week", "m": "month", "y": "year"][unit]!
        return n == 1 ? "Every \(name)" : "Every \(n) \(name)s"
    }
}

var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "en_US"); return c }()

// ISO week number (B21): the week with the year's first Thursday is week 1.
func weekNumber(_ d: Date) -> Int {
    var iso = Calendar(identifier: .iso8601); iso.timeZone = cal.timeZone
    return iso.component(.weekOfYear, from: d)
}

func startOfWeek(_ d: Date) -> Date {  // Monday, as in the mockup
    let day = cal.startOfDay(for: d)
    let wd = cal.component(.weekday, from: day)  // 1 = Sunday
    return cal.date(byAdding: .day, value: -((wd + 5) % 7), to: day)!
}

func addDays(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }

// The 35 or 42 days the month grid shows, Monday first.
func monthGrid(_ d: Date) -> [Date] {
    let first = cal.date(from: cal.dateComponents([.year, .month], from: d))!
    let start = startOfWeek(first)
    let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: first)!
    let weeks = (cal.dateComponents([.day], from: start, to: last).day! / 7) + 1
    return (0..<(weeks * 7)).map { addDays(start, $0) }
}

private let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
private let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

private func weekdayIndex(_ w: String) -> Int? {
    // Full names and the usual short forms only, so "Sunset" or "Monica" stay in the title.
    let short = ["sun", "mon", "tue", "tues", "wed", "weds", "thu", "thur", "thurs", "fri", "sat"]
    guard weekdays.contains(w) || short.contains(w) else { return nil }
    return weekdays.firstIndex { $0.hasPrefix(w) }.map { $0 + 1 }
}
private func monthIndex(_ w: String) -> Int? { w.count >= 3 ? months.firstIndex(where: { $0.hasPrefix(w) }).map { $0 + 1 } : nil }

// "7pm", "7:30pm", "19:00", "7", "noon" -> minutes after midnight.
// `sure`: am/pm was written or it is a 24-hour time, so no afternoon guess. `colon`: written with minutes ("7:30").
private func clock(_ s: String) -> (min: Int, sure: Bool, colon: Bool)? {
    if s == "noon" { return (720, true, false) }
    if s == "midnight" { return (0, true, false) }
    var t = s, pm: Bool? = nil
    if t.hasSuffix("pm") || t.hasSuffix("am") { pm = t.hasSuffix("pm"); t.removeLast(2) }
    else if t.hasSuffix("p") || t.hasSuffix("a") { pm = t.hasSuffix("p"); t.removeLast() }
    let parts = t.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let h = Int(parts[0]), (0...23).contains(h) else { return nil }
    let m = parts.count == 2 ? Int(parts[1]) : 0
    guard let m, (0...59).contains(m), parts.count == 2 || pm != nil || h <= 12 else { return nil }
    if parts.count == 2 && parts[1].count != 2 { return nil }
    var hh = h
    if let pm { guard h >= 1 && h <= 12 else { return nil }; hh = h % 12 + (pm ? 12 : 0) }
    return (hh * 60 + m, pm != nil || h > 12 || h == 0, parts.count == 2)
}

// A time with no am/pm ("dinner 7", "call 7:30") reads as the afternoon or evening when 1:00 to 7:59, like Fantastical.
private func guessPM(_ m: Int) -> Int { (60...479).contains(m) ? m + 720 : m }
private func value(_ c: (min: Int, sure: Bool, colon: Bool)) -> Int { c.sure ? c.min : guessPM(c.min) }

// "-a15m" -> (15, "m"); "-r1w" or "-rw" -> (1, "w"). Nil when the word is not that code.
private func shortCode(_ w: String, _ prefix: String) -> (Int, Character)? {
    guard w.hasPrefix(prefix), w.count > prefix.count, let u = w.last else { return nil }
    let num = w.dropFirst(prefix.count).dropLast()
    guard let n = num.isEmpty ? 1 : Int(num), n >= 0, n <= 9999 else { return nil }
    return (n, u)
}

// Reads a sentence like "Dinner with Ana Friday 7pm at Casa Luna /Personal -a15m". `now` is the moment the box is typed in.
// Short codes are taken out first, wherever they are; the rest is read as below.
func parseSentence(_ text: String, now: Date, defaultMinutes: Int = 60) -> Parsed {
    var code: String? = nil, alert: Int? = nil, rep: Repeat? = nil
    let rest = text.split(separator: " ").filter { word in
        let w = word.lowercased()
        if w.count > 1 && w.hasPrefix("/") { code = String(word.dropFirst()); return false }
        if let (n, u) = shortCode(w, "-a"), let mult = ["m": 1, "h": 60, "d": 1440][u] { alert = n * mult; return false }
        if let (n, u) = shortCode(w, "-r"), n > 0, "dwmy".contains(u) { rep = Repeat(unit: u, n: n); return false }
        return true
    }
    var p = parsePlain(rest.joined(separator: " "), now: now, defaultMinutes: defaultMinutes)
    p.calendarCode = code; p.alertMinutes = alert; p.repeats = rep
    return p
}

// Words not taken as a date, time or mark make the title; after "at <place>" they make the place.
private func parsePlain(_ text: String, now: Date, defaultMinutes: Int) -> Parsed {
    let words = text.split(separator: " ").map(String.init)
    var used = Set<Int>()
    var day: Date? = nil
    var startMin: Int? = nil, endMin: Int? = nil, duration: Int? = nil, startSure = false
    var allDay = false, tonight = false, showAs = ShowAs.busy
    var placeFrom: Int? = nil
    let today = cal.startOfDay(for: now)
    func low(_ i: Int) -> String { i >= 0 && i < words.count ? words[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?")) : "" }
    let joiners = ["at", "from", "@"]
    let tos = ["to", "until", "-", "till"]

    var i = 0
    while i < words.count {
        let w = low(i), next = low(i + 1)
        if w == "today" || w == "tonight" { day = today; used.insert(i); tonight = tonight || w == "tonight" }
        else if w == "tomorrow" || w == "tmrw" { day = addDays(today, 1); used.insert(i) }
        else if (w == "next" || w == "this" || w == "on"), let wd = weekdayIndex(next) {
            var d = nextWeekday(wd, from: today)
            if w == "next" && d == today { d = addDays(d, 7) }  // "next Monday" said on a Monday is a week away
            day = d; used.formUnion([i, i + 1]); i += 1
        }
        // A short day name as the first word is more likely a word than a day ("Sun and surf").
        else if let wd = weekdayIndex(w), i > 0 || weekdays.contains(w) { day = nextWeekday(wd, from: today); used.insert(i) }
        else if let mo = monthIndex(w), let dn = Int(next.filter(\.isNumber)), (1...31).contains(dn), next.allSatisfy({ $0.isNumber || "stndrh".contains($0) }) {
            day = dateFor(month: mo, day: dn, today: today); used.formUnion([i, i + 1]); i += 1
        }
        else if w.range(of: #"^\d{1,2}/\d{1,2}$"#, options: .regularExpression) != nil {
            let p = w.split(separator: "/").compactMap { Int($0) }
            // Month first, unless the first number can only be a day ("25/12").
            let (mo, dn) = p[0] > 12 ? (p[1], p[0]) : (p[0], p[1])
            if let d = dateFor(month: mo, day: dn, today: today) { day = d; used.insert(i) }
        }
        else if w == "all" && next == "day" { allDay = true; used.formUnion([i, i + 1]); i += 1 }
        else if w == "free" && i == words.count - 1 { showAs = .free; used.insert(i) }
        else if (w == "maybe" || w == "tentative") && i == words.count - 1 { showAs = .maybe; used.insert(i) }
        else if w == "for", let (mins, n) = durationAt(i + 1, words.map { $0.lowercased() }) { duration = mins; used.formUnion(i...(i + n)); i += n }
        else if joiners.contains(w), clock(next) != nil { used.insert(i) }
        else if (w == "at" || w == "@"), placeFrom == nil, i + 1 < words.count { placeFrom = i; used.insert(i) }
        else if let range = timeRange(w) { startMin = range.0; endMin = range.1; startSure = true; used.insert(i) }
        // A time counts with am/pm, with minutes, after at/from, or right before "to" and another time ("7 to 9pm").
        else if let c = clock(w), c.sure || c.colon || joiners.contains(low(i - 1)) || (tos.contains(next) && clock(low(i + 2)) != nil) {
            if startMin == nil { startMin = value(c); startSure = c.sure }
            used.insert(i)
        }
        else if tos.contains(w), let s = startMin, let c = clock(next) {
            var e = value(c)
            if !c.sure, e < s { e += 720 }
            endMin = e; used.formUnion([i, i + 1]); i += 1
        }
        i += 1
    }
    // A start with no am/pm written takes the end's: "7 to 9am" is morning.
    if let s = startMin, let e = endMin, !startSure, s > e, s >= 720 { startMin = s - 720 }
    if tonight && startMin == nil { startMin = 19 * 60 }

    var p = Parsed(start: now, end: now)
    // A linking word right before a date or time ("on Nov 3", "at 7pm") goes with it.
    for j in 0..<words.count where ["on", "at", "from", "by"].contains(low(j)) && used.contains(j + 1) { used.insert(j) }
    func join(_ r: Range<Int>) -> String {
        r.filter { !used.contains($0) }.map { words[$0] }.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,-"))
    }
    p.title = join(0..<(placeFrom ?? words.count))
    if let placeFrom { p.place = join((placeFrom + 1)..<words.count) }
    p.showAs = showAs
    p.dateGiven = day != nil || startMin != nil
    let base = day ?? today
    if allDay || startMin == nil {
        p.allDay = true
        p.start = base; p.end = addDays(base, 1)
        return p
    }
    var start = cal.date(byAdding: .minute, value: startMin!, to: base)!
    // A time already past today, with no day written, means tomorrow.
    if day == nil && start < now { start = addDays(start, 1) }
    p.start = start
    p.lengthGiven = endMin != nil || duration != nil
    let len = endMin.map { $0 > startMin! ? $0 - startMin! : $0 + 1440 - startMin! } ?? duration ?? defaultMinutes
    p.end = cal.date(byAdding: .minute, value: len, to: start)!
    return p
}

private func nextWeekday(_ wd: Int, from today: Date) -> Date {
    let cur = cal.component(.weekday, from: today)
    return addDays(today, (wd - cur + 7) % 7)
}

private func dateFor(month: Int, day: Int, today: Date) -> Date? {
    guard (1...12).contains(month) else { return nil }
    var c = cal.dateComponents([.year], from: today); c.month = month; c.day = day
    guard let d = cal.date(from: c), cal.component(.day, from: d) == day else { return nil }
    return d < today ? cal.date(byAdding: .year, value: 1, to: d) : d
}

// "7-9pm", "7pm-9pm", "19:00-20:30"
private func timeRange(_ w: String) -> (Int, Int)? {
    let parts = w.split(separator: "-").map(String.init)
    guard parts.count == 2, let a = clock(parts[0]), let b = clock(parts[1]) else { return nil }
    var s = a.min, e = b.min
    if !a.sure { s = b.min >= 720 && a.min + 720 < b.min ? a.min + 720 : (b.sure ? a.min : guessPM(a.min)) }
    if !b.sure { e = guessPM(b.min); if e < s { e += 720 } }
    return (s, e)
}

// "2 hours", "30 min", "1.5h", "90m" -> (minutes, words used)
private func durationAt(_ i: Int, _ w: [String]) -> (Int, Int)? {
    guard i < w.count else { return nil }
    let units: [(String, Double)] = [("h", 60), ("hr", 60), ("hrs", 60), ("hour", 60), ("hours", 60), ("m", 1), ("min", 1), ("mins", 1), ("minute", 1), ("minutes", 1)]
    if let n = Double(w[i]), i + 1 < w.count, let u = units.first(where: { $0.0 == w[i + 1] }) { return (Int(n * u.1), 2) }
    for (name, mult) in units.sorted(by: { $0.0.count > $1.0.count }) where w[i].hasSuffix(name) {
        if let n = Double(w[i].dropLast(name.count)) { return (Int(n * mult), 1) }
    }
    return nil
}

// Clock text for the views: "7:00 PM", "7 PM" when `short`.
func timeText(_ d: Date, short: Bool = false) -> String {
    dateText(d, short && cal.component(.minute, from: d) == 0 ? "h a" : "h:mm a")
}

// One formatter per format, reused: the views ask for dates many times per redraw.
@MainActor private var formatters: [String: DateFormatter] = [:]
func dateText(_ d: Date, _ format: String) -> String {
    MainActor.assumeIsolated {
        let f = formatters[format] ?? { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = format; formatters[format] = f; return f }()
        f.timeZone = cal.timeZone
        return f.string(from: d)
    }
}

// Moves a time by whole minutes on the 15-minute grid (Option Up/Down). Off the grid, the first step goes to the nearest grid line that way.
func snapped(_ d: Date, by minutes: Int, step: Int = 15) -> Date {
    let day = cal.startOfDay(for: d)
    let t = cal.dateComponents([.minute], from: day, to: d).minute!
    let down = t / step * step
    let target = minutes > 0 || t == down ? down + minutes : down + minutes + step
    return cal.date(byAdding: .minute, value: target, to: day)!
}

// A past event's title can stand in for what is typed: same first word, exact starts first, at most two (quick add).
func suggestions(_ title: String, in past: [Item]) -> [Item] {
    let t = title.lowercased()
    guard t.count >= 2, let first = t.split(separator: " ").first else { return [] }
    let hits = past.filter { $0.title.lowercased().hasPrefix(first) }
    return Array((hits.filter { $0.title.lowercased().hasPrefix(t) } + hits.filter { !$0.title.lowercased().hasPrefix(t) }).prefix(2))
}

// Tab on a past event: its title, and its place, length and show-as where the sentence did not say.
func applying(_ pick: Item, to p: Parsed) -> Parsed {
    var p = p
    p.title = pick.title
    if p.place.isEmpty { p.place = pick.place }
    if p.showAs == .busy { p.showAs = pick.showAs }
    if !p.allDay && !p.lengthGiven && !pick.allDay { p.end = p.start.addingTimeInterval(pick.end.timeIntervalSince(pick.start)) }
    return p
}

func alertText(_ m: Int) -> String {
    if m == 0 { return "At the start" }
    let (n, unit) = m % 1440 == 0 ? (m / 1440, "day") : m % 60 == 0 ? (m / 60, "hour") : (m, "minute")
    return "\(n) \(unit)\(n == 1 ? "" : "s") before"
}

// "/fam" or "/f" -> the calendar named that, or starting with it. Calendars shown in the sidebar win over hidden ones.
func matchCalendar(_ code: String, in cals: [CalInfo], hidden: Set<String>) -> CalInfo? {
    let k = code.lowercased()
    let squash = { (c: CalInfo) in c.title.lowercased().replacingOccurrences(of: " ", with: "") }
    let ordered = cals.filter { !hidden.contains($0.id) } + cals.filter { hidden.contains($0.id) }
    return ordered.first { squash($0) == k } ?? ordered.first { squash($0).hasPrefix(k) }
}

func quarterStart(_ d: Date) -> Date {
    var c = cal.dateComponents([.year, .month], from: d)
    c.month = (c.month! - 1) / 3 * 3 + 1
    return cal.date(from: c)!
}

// One line of the sidebar's "Coming up" card: `lead` + `big` (bold) + `tail`. `dim`: the event already under way.
struct Soon: Equatable { let title: String; let calendarID: String; let lead: String; let big: String; let tail: String; let dim: Bool }

// The next event, the next all-day event (the next big day), and the event under way now.
func comingUp(_ items: [Item], now: Date) -> [Soon] {
    func span(_ s: TimeInterval) -> String {
        let m = max(1, Int(s / 60)), h = m / 60, r = m % 60
        return h == 0 ? "\(m) min" : r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
    func days(_ d: Date) -> (String, String) {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day!
        return (n == 1 ? "1 day" : "\(n) days", " · " + dateText(d, "EEEE"))
    }
    var out: [Soon] = []
    let timed = items.filter { !$0.allDay }.sorted { $0.start < $1.start }
    if let n = timed.first(where: { $0.start > now }) {
        if n.start.timeIntervalSince(now) < 86400 { out.append(Soon(title: n.shownTitle, calendarID: n.calendarID, lead: "starts in ", big: span(n.start.timeIntervalSince(now)), tail: "", dim: false)) }
        else { let (b, t) = days(n.start); out.append(Soon(title: n.shownTitle, calendarID: n.calendarID, lead: "in ", big: b, tail: t, dim: false)) }
    }
    if let b = items.filter({ $0.allDay && $0.start > now }).min(by: { $0.start < $1.start }) {
        let (big, t) = days(b.start)
        out.append(Soon(title: b.shownTitle, calendarID: b.calendarID, lead: "in ", big: big, tail: t, dim: false))
    }
    if let c = timed.first(where: { $0.start <= now && $0.end > now }) {
        out.append(Soon(title: c.shownTitle, calendarID: c.calendarID, lead: "ends in \(span(c.end.timeIntervalSince(now))) · started \(span(now.timeIntervalSince(c.start))) ago", big: "", tail: "", dim: true))
    }
    return out
}

func selftest() -> Int32 {
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL:", what) } }
    var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 26; c.hour = 9; c.minute = 41
    cal.timeZone = TimeZone(identifier: "America/Costa_Rica")!
    let now = cal.date(from: c)!  // Monday, October 26, 2026, the mockup's "today"
    func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))! }

    expect(weekNumber(now) == 44, "Oct 26 2026 is week 44")
    expect(weekNumber(cal.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!) == 53, "Jan 1 2027 is in week 53 of 2026")
    expect(startOfWeek(at(11, 1, 12)) == at(10, 26, 0), "week starts Monday")
    expect(monthGrid(now).count == 35 && monthGrid(now).first == at(9, 28, 0), "October 2026 grid: 5 weeks from Sep 28")
    func ev(_ c: String, _ a: Date, _ b: Date) -> Item { Item(id: c, calendarID: c, title: "", start: a, end: b, allDay: false, place: "", notes: "", showAs: .busy) }
    let yr = cal.dateInterval(of: .year, for: now)!
    let dc = dayCalendars([ev("w", at(3, 2, 9), at(3, 2, 10)), ev("p", at(3, 2, 22), at(3, 4, 0)), ev("w", at(3, 2, 11), at(3, 2, 12)), ev("f", at(12, 31, 20), at(12, 31, 20))], in: yr)
    expect(dc[at(3, 2, 0)] == ["w", "p"] && dc[at(3, 3, 0)] == ["p"] && dc[at(3, 4, 0)] == nil, "year dots: one per calendar, overnight event spans to its end")
    expect(dc[at(12, 31, 0)] == ["f"], "year dots: a zero-length event still marks its day")
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
    p = parseSentence("Gym today 6-7:30pm", now: now)
    expect(p.title == "Gym" && p.start == at(10, 26, 18) && p.end == at(10, 26, 19, 30), "range 6-7:30pm: \(p.start) \(p.end)")
    p = parseSentence("Workshop 2pm to 5pm on Nov 3", now: now)
    expect(p.title == "Workshop" && p.start == at(11, 3, 14) && p.end == at(11, 3, 17), "from-to with month day: \(p.title) \(p.start)")
    p = parseSentence("Lily's birthday 11/14", now: now)
    expect(p.allDay && p.start == at(11, 14, 0) && p.title == "Lily's birthday", "no time: all day")
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
    expect(soon.map(\.title) == ["Lunch", "Beach day", "Review"], "coming up order: \(soon.map(\.title))")
    expect(soon[0].big == "1 h 40 min" && soon[1].big == "6 days" && soon[1].tail == " · Sunday" && soon[2].lead == "ends in 40 min · started 41 min ago", "coming up text: \(soon)")
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
    expect(taskRowDay(td(at(10, 23, 0)), now: now) == at(10, 26, 0) && taskRowDay(td(at(10, 23, 15), timed: true), now: now) == at(10, 26, 0), "an unfinished task moves to today")
    expect(taskRowDay(td(at(10, 27, 11), timed: true), now: now) == nil && taskRowDay(td(at(10, 27, 0)), now: now) == at(10, 27, 0), "a timed task shows in the grid, not the row")
    expect(taskRowDay(td(at(10, 23, 0), done: true), now: now) == at(10, 23, 0), "a ticked task stays on its own day")
    MainActor.assumeIsolated {
        let a = AppState(store: Store(sample: true), today: now)
        for (typed, saved) in [("Pick up keys at the condo", "Pick up keys at the condo"), ("Buy rice for free", "Buy rice for free"), ("Call the bank Friday 3pm", "Call the bank")] {
            a.taskText = typed; a.commitTask()
            expect(a.store.todos.last?.title == saved, "task title kept: \(typed)")
        }
    }
    expect(shortDay(at(10, 23, 0), now: now) == "Fri" && shortDay(at(11, 14, 0), now: now) == "Nov 14", "task day text")

    print(fails == 0 ? "selftest: all passed" : "selftest: \(fails) failed")
    return fails == 0 ? 0 : 1
}
