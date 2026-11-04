// The maths behind the day, week and month grids: side-by-side lanes, day shifts, calendars per day.
import SwiftUI

// Side-by-side columns for events that overlap in time: (column, columns in its group).
public func lanes(_ items: [Item]) -> [String: (Int, Int)] {
    var out: [String: (Int, Int)] = [:]
    var group: [Item] = [], ends: [Date] = [], groupEnd = Date.distantPast
    func flush() { for it in group { out[it.id] = (out[it.id]!.0, ends.count) }; group = []; ends = [] }
    for it in items.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
        if it.start >= groupEnd { flush() }
        let lane = ends.firstIndex(where: { $0 <= it.start }) ?? ends.count
        if lane == ends.count { ends.append(it.end) } else { ends[lane] = it.end }
        out[it.id] = (lane, 0); group.append(it); groupEnd = max(groupEnd, it.end)
    }
    flush()
    return out
}

// Days between two columns of a week view: the 5 day week can skip days off, so one column can be several days. Past either end, each further column = one day.
public func dayShift(columns n: Int, from day: Date, in days: [Date]) -> Int {
    guard let i = days.firstIndex(of: day) else { return n }
    let edge = min(max(i + n, 0), days.count - 1)
    return cal.dateComponents([.day], from: day, to: days[edge]).day! + (i + n - edge)
}

// For the year view: each day (start of day) inside `range`, mapped to the calendars with something on it, in start order.
public func dayCalendars(_ items: [Item], in range: DateInterval) -> [Date: [String]] {
    var out: [Date: [String]] = [:]
    for it in items where it.end > range.start && it.start < range.end {
        var d = cal.startOfDay(for: max(it.start, range.start))
        let last = min(it.end, range.end)
        repeat {
            if !(out[d]?.contains(it.calendarID) ?? false) { out[d, default: []].append(it.calendarID) }
            d = addDays(d, 1)
        } while d < last
    }
    return out
}

