// How an event repeats (approved Repeat mockup, 2026-11-20): the Repeat menu, Custom, the plain-words summary,
// and the same rule written for Apple Calendar, Google and iCloud/ICS.
import Foundation
import EventKit

public struct Repeat: Equatable, Hashable {
    public var unit: Character  // d, w, m or y
    public var n: Int           // every n days, weeks, months or years
    public var days: [Int] = [] // weekdays, 1 = Sunday: the week's days, or the day "on the third …"; Monday to Friday = "weekday"
    public var nth: Int? = nil  // monthly "on the first … fourth" (1 to 4) or "last" (-1); nil = on the event's own date
    public var count: Int? = nil
    public var until: Date? = nil  // the last day it can happen
    public init(unit: Character, n: Int, days: [Int] = [], nth: Int? = nil, count: Int? = nil, until: Date? = nil) {
        self.unit = unit; self.n = n; self.days = days; self.nth = nth; self.count = count; self.until = until
    }

    public static let weekdays = [2, 3, 4, 5, 6]
    static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    public static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    public static let nthNames = [1: "first", 2: "second", 3: "third", 4: "fourth", -1: "last"]

    // The Repeat menu for an event on `start`: its own weekday, its place in the month and its date.
    public static func menu(_ start: Date) -> [Repeat?] {
        let wd = cal.component(.weekday, from: start)
        return [nil, Repeat(unit: "d", n: 1), Repeat(unit: "w", n: 1, days: weekdays), Repeat(unit: "w", n: 1, days: [wd]),
                Repeat(unit: "w", n: 2, days: [wd]), Repeat(unit: "m", n: 1, days: [wd], nth: nthOf(start)), Repeat(unit: "y", n: 1)]
    }
    // Which one of its weekday in the month a day is; the fifth counts as the last.
    public static func nthOf(_ d: Date) -> Int { let k = (cal.component(.day, from: d) - 1) / 7 + 1; return k > 4 ? -1 : k }

    // The same rule however it was written: a weekly rule always names its days.
    public func normal(_ start: Date) -> Repeat {
        var r = self
        if unit == "w" && days.isEmpty { r.days = [cal.component(.weekday, from: start)] }
        if unit == "w" || nth == nil { r.nth = nil }
        if unit != "w" && nth == nil { r.days = [] }
        r.days = Array(Set(r.days)).sorted()
        return r
    }

    // "Every other week on Monday, Wednesday and Friday, 10 times, ending Aug 16, 2027"
    public func text(_ start: Date) -> String {
        let r = normal(start)
        func list(_ a: [String]) -> String { a.count < 2 ? a.joined() : a.dropLast().joined(separator: ", ") + " and " + a.last! }
        func every(_ one: String, _ many: String) -> String { n == 1 ? "Every \(one)" : n == 2 ? "Every other \(one)" : "Every \(n) \(many)" }
        var s: String
        switch unit {
        case "d": s = every("day", "days")
        case "w": s = n == 1 && r.days == Self.weekdays ? "Every weekday" : every("week", "weeks") + " on " + list(r.days.map { Self.dayNames[$0 - 1] })
        case "m":
            let on = r.nth.map { "the \(Self.nthNames[$0] ?? "") " + (r.days == Self.weekdays ? "weekday" : list(r.days.map { Self.dayNames[$0 - 1] })) }
            s = every("month", "months") + " on " + (on ?? "day \(cal.component(.day, from: start))")
        default: s = every("year", "years") + " on " + start.formatted(.dateTime.month(.abbreviated).day())
        }
        let longDate = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        if let count { s += count == 1 ? ", once" : ", \(count) times"; if count > 1, let last = lastTime(start) { s += ", ending " + last.formatted(longDate) } }
        else if let until { s += ", until " + until.formatted(longDate) }
        return s
    }

    // When the last time falls, for "10 times".
    public func lastTime(_ start: Date) -> Date? {
        occurrences(ICalEvent(start: start, end: start, tz: cal.timeZone, rule: ruleParts(allDay: false)), from: start, to: start.addingTimeInterval(86400 * 366 * 30)).last
    }

    // RRULE text, as Google and iCloud/ICS files take it. An all-day event ends on a date, a timed one at the end of that day in UTC.
    public func rrule(allDay: Bool) -> String {
        ruleParts(allDay: allDay).sorted { $0.key == "FREQ" || ($1.key != "FREQ" && $0.key < $1.key) }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }
    func ruleParts(allDay: Bool) -> [String: String] {
        var p = ["FREQ": ["d": "DAILY", "w": "WEEKLY", "m": "MONTHLY", "y": "YEARLY"][unit]!]
        if n > 1 { p["INTERVAL"] = "\(n)" }
        if unit == "w" && !days.isEmpty { p["BYDAY"] = days.map { Self.codes[$0 - 1] }.joined(separator: ",") }
        if unit == "m", let k = nth, !days.isEmpty {
            if days.count == 1 { p["BYDAY"] = "\(k)" + Self.codes[days[0] - 1] }
            else { p["BYDAY"] = days.map { Self.codes[$0 - 1] }.joined(separator: ","); p["BYSETPOS"] = "\(k)" }
        }
        if let count { p["COUNT"] = "\(count)" }
        else if let until {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone; f.dateFormat = "yyyyMMdd"
            p["UNTIL"] = allDay ? f.string(from: until) : icsUTC(cal.date(bySettingHour: 23, minute: 59, second: 59, of: until) ?? until)
        }
        return p
    }

    // Read back from a calendar's rule; nil when it uses parts this editor can't show (it is then kept as it is).
    public init?(rule p: [String: String], allDay: Bool = false) {
        let known: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYSETPOS", "COUNT", "UNTIL", "WKST"]
        guard p.keys.allSatisfy(known.contains), let u = ["DAILY": "d", "WEEKLY": "w", "MONTHLY": "m", "YEARLY": "y"][p["FREQ"] ?? ""] else { return nil }
        let n = Int(p["INTERVAL"] ?? "1") ?? 0
        guard n >= 1 else { return nil }
        var days: [Int] = [], nth: Int? = nil
        for part in (p["BYDAY"] ?? "").split(separator: ",") {
            guard part.count >= 2, let w = Self.codes.firstIndex(of: String(part.suffix(2))) else { return nil }
            days.append(w + 1)
            if let k = Int(part.dropLast(2)) { nth = k }
        }
        if let s = p["BYSETPOS"] { guard let k = Int(s), days.count > 1, nth == nil else { return nil }; nth = k }
        if let k = nth, !(1...4).contains(k) && k != -1 { return nil }
        // Daily on chosen days, yearly on a weekday, or a monthly day list are written by other apps only.
        guard (u == "w" || u == "m" || days.isEmpty), u != "m" || days.isEmpty || nth != nil, nth == nil || u == "m" else { return nil }
        let until = p["UNTIL"].flatMap { v in icsDate(allDay ? String(v.prefix(8)) : v.count == 8 ? v + "T235959" : v, [:])?.0 }
        self.init(unit: Character(u), n: n, days: days, nth: nth, count: p["COUNT"].flatMap { Int($0) }, until: until)
    }

    // Apple Calendar's form of the same rule.
    public var ek: EKRecurrenceRule {
        let f: [Character: EKRecurrenceFrequency] = ["d": .daily, "w": .weekly, "m": .monthly, "y": .yearly]
        let single = unit == "m" && days.count == 1 ? nth ?? 0 : 0
        let wd = days.isEmpty || (unit == "m" && nth == nil) ? nil : days.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!, weekNumber: single) }
        let pos = unit == "m" && days.count > 1 ? nth.map { [$0 as NSNumber] } : nil
        let end = count.map { EKRecurrenceEnd(occurrenceCount: $0) } ?? until.map { EKRecurrenceEnd(end: cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0) }
        return EKRecurrenceRule(recurrenceWith: f[unit]!, interval: n, daysOfTheWeek: wd, daysOfTheMonth: nil, monthsOfTheYear: nil,
                                weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: pos, end: end)
    }
    public init?(ek r: EKRecurrenceRule) {
        guard r.daysOfTheMonth == nil, r.monthsOfTheYear == nil, r.weeksOfTheYear == nil, r.daysOfTheYear == nil else { return nil }
        let u: Character = [.daily: "d", .weekly: "w", .monthly: "m", .yearly: "y"][r.frequency] ?? "d"
        let days = (r.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue }
        let inWeek = r.daysOfTheWeek?.first.map { $0.weekNumber } ?? 0
        let pos = r.setPositions?.first?.intValue
        let nth = pos ?? (inWeek != 0 ? inWeek : nil)
        if let k = nth, !(1...4).contains(k) && k != -1 { return nil }
        guard u == "w" || days.isEmpty || (u == "m" && nth != nil) else { return nil }
        self.init(unit: u, n: r.interval, days: days, nth: nth, count: r.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil },
                  until: r.recurrenceEnd?.endDate.map { cal.startOfDay(for: $0) })
    }
}

// What the panels show about an event's repeat before it is read.
public enum RepeatNow: Equatable { case never, rule(Repeat), other }

@MainActor
public func repeatSelfTest(_ expect: (Bool, String) -> Void) {
    let mon = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 6))!  // the third Monday
    let menu = Repeat.menu(mon).map { $0?.text(mon) ?? "Never" }
    expect(menu == ["Never", "Every day", "Every weekday", "Every week on Monday", "Every other week on Monday", "Every month on the third Monday", "Every year on Nov 16"],
           "repeat: menu follows the event's day: \(menu)")
    let mwf = Repeat(unit: "w", n: 2, days: [6, 2, 4])
    expect(mwf.normal(mon).text(mon) == "Every other week on Monday, Wednesday and Friday", "repeat: weekly days read in order")
    expect(mwf.normal(mon).rrule(allDay: false) == "FREQ=WEEKLY;BYDAY=MO,WE,FR;INTERVAL=2", "repeat: weekly rule \(mwf.normal(mon).rrule(allDay: false))")
    let third = Repeat(unit: "m", n: 1, days: [2], nth: 3, count: 10)
    expect(third.rrule(allDay: false) == "FREQ=MONTHLY;BYDAY=3MO;COUNT=10", "repeat: third Monday rule")
    expect(third.text(mon) == "Every month on the third Monday, 10 times, ending Aug 16, 2027", "repeat: summary with the end: \(third.text(mon))")
    let firstWd = Repeat(unit: "m", n: 1, days: Repeat.weekdays, nth: 1)
    expect(firstWd.rrule(allDay: false) == "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1", "repeat: first weekday rule")
    let dec1 = cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 6))!, jan1 = cal.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 6))!
    let firsts = occurrences(ICalEvent(start: dec1, end: dec1, tz: cal.timeZone, rule: firstWd.ruleParts(allDay: false)), from: dec1, to: cal.date(from: DateComponents(year: 2027, month: 3, day: 1))!)
    expect(firsts.map { cal.component(.day, from: $0) } == [1, 1, 1], "repeat: first weekday of Dec, Jan (a Friday) and Feb \(firsts)")
    expect(Repeat(unit: "d", n: 2).text(mon) == "Every other day", "repeat: every other day")
    // Read back what each calendar writes, and leave alone what this editor can't show.
    for r in [mwf.normal(mon), third, firstWd, Repeat(unit: "y", n: 1, until: cal.startOfDay(for: jan1))] {
        expect(Repeat(rule: r.ruleParts(allDay: false)) == r, "repeat: rule reads back: \(r.rrule(allDay: false))")
        expect(Repeat(ek: r.ek)?.normal(mon) == r.normal(mon), "repeat: Apple rule reads back: \(r.rrule(allDay: false))")
    }
    expect(Repeat(rule: ["FREQ": "MONTHLY", "BYMONTHDAY": "1,15"]) == nil, "repeat: a rule from another app is kept as it is")
    expect(Repeat(rule: ["FREQ": "WEEKLY"])?.normal(mon).days == [2], "repeat: plain weekly means the event's own day")
}
