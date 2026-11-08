// Pure logic, no calendar access: the type-a-sentence parser and the date maths behind the views. Covered by --selftest.
import Foundation

public enum ShowAs: String, CaseIterable { case busy = "Busy", free = "Free", maybe = "Maybe" }

// What the add box understood from a sentence (A1, A2).
public struct Parsed: Equatable {
    public var title = ""
    public var start: Date
    public var end: Date
    public var allDay = false
    public var place = ""
    public var geo: Geo? = nil  // set when the place was picked from Apple Maps
    public var showAs = ShowAs.busy
    public var lengthGiven = false  // an end time or "for 2 hours" was written
    public var dateGiven = false  // a day or a time was written (a task without one has no due date)
    // Short codes (Phase 2): "/Personal" picks a calendar, "-a15m" an alert, "-r1w" a repeat.
    public var calendarCode: String? = nil
    public var alertMinutes: Int? = nil
    public var repeats: Repeat? = nil
    public var notes = ""  // only set by Make Event from Email and A4 tasks on the calendar
    public init(title: String = "", start: Date, end: Date, allDay: Bool = false, place: String = "", geo: Geo? = nil, showAs: ShowAs = ShowAs.busy, lengthGiven: Bool = false, dateGiven: Bool = false, calendarCode: String? = nil, alertMinutes: Int? = nil, repeats: Repeat? = nil, notes: String = "") { self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.place = place; self.geo = geo; self.showAs = showAs; self.lengthGiven = lengthGiven; self.dateGiven = dateGiven; self.calendarCode = calendarCode; self.alertMinutes = alertMinutes; self.repeats = repeats; self.notes = notes }
}

public struct Repeat: Equatable {
    public let unit: Character  // d, w, m or y
    public let n: Int
    public var text: String {
        let name = ["d": "day", "w": "week", "m": "month", "y": "year"][unit]!
        return n == 1 ? "Every \(name)" : "Every \(n) \(name)s"
    }
    public init(unit: Character, n: Int) { self.unit = unit; self.n = n }
}

public var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "en_US"); return c }()

// ISO week number (B21): the week with the year's first Thursday is week 1.
// Weeks that start on another day count from January 1st, as Apple Calendar does.
public func weekNumber(_ d: Date) -> Int {
    var c = Calendar(identifier: WorkWeek.firstWeekday == 2 ? .iso8601 : .gregorian); c.timeZone = cal.timeZone
    if WorkWeek.firstWeekday != 2 { c.firstWeekday = WorkWeek.firstWeekday; c.minimumDaysInFirstWeek = 1 }
    return c.component(.weekOfYear, from: d)
}

public func startOfWeek(_ d: Date) -> Date {  // the day picked in Settings, Week
    let day = cal.startOfDay(for: d)
    let wd = cal.component(.weekday, from: day)  // 1 = Sunday
    return cal.date(byAdding: .day, value: -((wd - WorkWeek.firstWeekday + 7) % 7), to: day)!
}

public func addDays(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }

// `day` at the clock time of `from`, right on a day the clocks change too.
public func sameClock(_ from: Date, on day: Date) -> Date {
    let c = cal.dateComponents([.hour, .minute], from: from)
    return cal.date(bySettingHour: c.hour!, minute: c.minute!, second: 0, of: day) ?? day
}

// The 35 or 42 days the month grid shows, from the first day of the week.
public func monthGrid(_ d: Date) -> [Date] {
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
public func parseSentence(_ text: String, now: Date, defaultMinutes: Int = 60) -> Parsed {
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
    // "9:30 AM" or "9 p.m." typed as two words joins into one time word, so the AM never stays in the title.
    var words: [String] = []
    for w in text.split(separator: " ").map(String.init) {
        let ap = w.lowercased().filter { $0 != "." && $0 != "," }
        let joined = (words.last ?? "").lowercased() + ap
        // Only a real time ("Q4 PM" stays), and never a day number ("Nov 3 PM" keeps its date).
        if ap == "am" || ap == "pm", clock(joined) != nil || timeRange(joined) != nil, monthIndex(words.dropLast().last?.lowercased() ?? "") == nil {
            words[words.count - 1] += ap
        } else { words.append(w) }
    }
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
public func timeText(_ d: Date, short: Bool = false) -> String {
    dateText(d, short && cal.component(.minute, from: d) == 0 ? "h a" : "h:mm a")
}

// One formatter per format, reused: the views ask for dates many times per redraw.
@MainActor private var formatters: [String: DateFormatter] = [:]
public func dateText(_ d: Date, _ format: String, in tz: TimeZone = cal.timeZone) -> String {
    MainActor.assumeIsolated {
        let f = formatters[format] ?? { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = format; formatters[format] = f; return f }()
        f.timeZone = tz
        return f.string(from: d)
    }
}

// Moves a time by whole minutes on the 15-minute grid (Option Up/Down). Off the grid, the first step goes to the nearest grid line that way.
public func snapped(_ d: Date, by minutes: Int, step: Int = 15) -> Date {
    let day = cal.startOfDay(for: d)
    let t = cal.dateComponents([.minute], from: day, to: d).minute!
    let down = t / step * step
    let target = minutes > 0 || t == down ? down + minutes : down + minutes + step
    return cal.date(byAdding: .minute, value: target, to: day)!
}

// A past event's title can stand in for what is typed: same first word, exact starts first, at most two (quick add).
public func suggestions(_ title: String, in past: [Item]) -> [Item] {
    let t = title.lowercased()
    guard t.count >= 2, let first = t.split(separator: " ").first else { return [] }
    let hits = past.filter { $0.title.lowercased().hasPrefix(first) }
    return Array((hits.filter { $0.title.lowercased().hasPrefix(t) } + hits.filter { !$0.title.lowercased().hasPrefix(t) }).prefix(2))
}

// Tab on a past event: its title, and its place, length and show-as where the sentence did not say.
public func applying(_ pick: Item, to p: Parsed) -> Parsed {
    var p = p
    p.title = pick.title
    if p.place.isEmpty { p.place = pick.place }
    if p.showAs == .busy { p.showAs = pick.showAs }
    if !p.allDay && !p.lengthGiven && !pick.allDay { p.end = p.start.addingTimeInterval(pick.end.timeIntervalSince(pick.start)) }
    return p
}

public func alertText(_ m: Int) -> String {
    if m == 0 { return "At the start" }
    let (n, unit) = m % 1440 == 0 ? (m / 1440, "day") : m % 60 == 0 ? (m / 60, "hour") : (m, "minute")
    return "\(n) \(unit)\(n == 1 ? "" : "s") before"
}

// "/fam" or "/f" -> the calendar named that, or starting with it. Calendars shown in the sidebar win over hidden ones.
public func matchCalendar(_ code: String, in cals: [CalInfo], hidden: Set<String>) -> CalInfo? {
    let k = code.lowercased()
    let squash = { (c: CalInfo) in c.title.lowercased().replacingOccurrences(of: " ", with: "") }
    let ordered = cals.filter { !hidden.contains($0.id) } + cals.filter { hidden.contains($0.id) }
    return ordered.first { squash($0) == k } ?? ordered.first { squash($0).hasPrefix(k) }
}

public func quarterStart(_ d: Date) -> Date {
    var c = cal.dateComponents([.year, .month], from: d)
    c.month = (c.month! - 1) / 3 * 3 + 1
    return cal.date(from: c)!
}

// One line of the sidebar's "Coming up" card: `lead` + `big` (bold) + `tail`. `dim`: the event already under way.
public struct Soon: Equatable { public let title: String; public let calendarID: String; public let lead: String; public let big: String; public let tail: String; public let dim: Bool
    public init(title: String, calendarID: String, lead: String, big: String, tail: String, dim: Bool) { self.title = title; self.calendarID = calendarID; self.lead = lead; self.big = big; self.tail = tail; self.dim = dim } }

// "5 min", "2 h", "5 h 28 min" (also the menu bar's "What's next").
public func span(_ s: TimeInterval) -> String {
    let m = max(1, Int(s / 60)), h = m / 60, r = m % 60
    return h == 0 ? "\(m) min" : r == 0 ? "\(h) h" : "\(h) h \(r) min"
}

public func comingUp(_ items: [Item], now: Date) -> [Soon] {
    func days(_ d: Date) -> (String, String) {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day!
        return (n == 1 ? "1 day" : "\(n) days", " · " + dateText(d, "EEEE"))
    }
    // In time order (John 2026-11-08): what is on now, then the next events; an all-day event sits at the start of its day.
    let onNow = items.filter { !$0.allDay && $0.start <= now && $0.end > now }.sorted { $0.start < $1.start }.map {
        Soon(title: $0.shownTitle, calendarID: $0.calendarID, lead: "ends in \(span($0.end.timeIntervalSince(now))) · started \(span(now.timeIntervalSince($0.start))) ago", big: "", tail: "", dim: true)
    }
    let next = items.filter { $0.start > now }.sorted { $0.start < $1.start }.prefix(4).map { n -> Soon in
        if !n.allDay && n.start.timeIntervalSince(now) < 86400 { return Soon(title: n.shownTitle, calendarID: n.calendarID, lead: "starts in ", big: span(n.start.timeIntervalSince(now)), tail: "", dim: false) }
        let (b, t) = days(n.start); return Soon(title: n.shownTitle, calendarID: n.calendarID, lead: "in ", big: b, tail: t, dim: false)
    }
    return Array((onNow + next).prefix(4))
}

