// Week settings (approved mockup, 2026-10-27): the first day of the week, working days and working hours. Saved on this Mac.
import SwiftUI

enum WorkWeek {
    static let starts = ["Match Mac", "Sunday", "Monday", "Saturday"]
    private static let d = UserDefaults.standard
    static var start = d.string(forKey: "weekStart").flatMap { starts.contains($0) ? $0 : nil } ?? "Match Mac" { didSet { save(start, "weekStart") } }
    static var days = Set(d.array(forKey: "workDays") as? [Int] ?? [2, 3, 4, 5, 6]) { didSet { save(days.sorted(), "workDays") } }  // 1 = Sunday
    static var from = d.object(forKey: "workFrom") as? Int ?? 8 * 60 { didSet { save(from, "workFrom") } }  // minutes after midnight
    static var to = d.object(forKey: "workTo") as? Int ?? 18 * 60 { didSet { save(to, "workTo") } }
    static var stripe = d.object(forKey: "workStripe") as? Bool ?? true { didSet { save(stripe, "workStripe") } }
    static var sun = d.object(forKey: "showSun") as? Bool ?? true { didSet { save(sun, "showSun") } }  // Phase 5: sun and moon in the day and week views
    static var leave = d.object(forKey: "leaveAlerts") as? Bool ?? true { didSet { save(leave, "leaveAlerts") } }  // Phase 5: the leave alert's default per event

    private static func save(_ v: Any, _ key: String) { if Look.saves { d.set(v, forKey: key) } }

    // 1 = Sunday, 2 = Monday, 7 = Saturday; "Match Mac" follows Language & Region in System Settings.
    static var firstWeekday: Int { ["Sunday": 1, "Monday": 2, "Saturday": 7][start] ?? Calendar.autoupdatingCurrent.firstWeekday }
    static func isWorkDay(_ day: Date) -> Bool { days.contains(cal.component(.weekday, from: day)) }

    // The mockup's week, for the off-screen pictures and the self-checks; never saved.
    static func reset() { Look.saves = false; start = "Monday"; days = [2, 3, 4, 5, 6]; from = 8 * 60; to = 18 * 60; stripe = true; sun = true; leave = true }
}

func minuteText(_ m: Int, short: Bool = false) -> String {
    if m == 1440 { return "Midnight" }  // the end of the day, not 12:00 AM at its start
    let h = m / 60 % 24, mm = m % 60
    return "\(h % 12 == 0 ? 12 : h % 12)\(short && mm == 0 ? "" : ":\(mm < 10 ? "0" : "")\(mm)") \(h < 12 ? "AM" : "PM")"
}

