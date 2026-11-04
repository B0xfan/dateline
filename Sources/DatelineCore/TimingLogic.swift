// --timing <file>: how long the slow calendar reads take on this Mac's real calendars. Only times and counts go in the file, never event text.
// Never asks for access (no permission box) and never starts the app: no window, no settings written, no sign-ins.
import Foundation
import SwiftUI

@MainActor public func timingCheck(_ path: String) -> Int32 {
    guard AppleCalendar.hasEventAccess else {
        try? "no calendar access for this copy, nothing timed\n".write(toFile: path, atomically: true, encoding: .utf8)
        return 2
    }
    let source = AppleCalendar(), today = cal.startOfDay(for: Date())
    var out = ""
    func time(_ name: String, _ a: Date, _ b: Date) {
        var runs: [Double] = [], count = 0
        for _ in 0..<5 {
            let t = Date()
            count = source.events(from: a, to: b).count
            runs.append(Date().timeIntervalSince(t) * 1000)
        }
        out += "\(name): \(Int(runs.sorted()[2])) ms (\(count) events; worst \(Int(runs.max()!)) ms)\n"
    }
    time("Week step, the days shown", addDays(today, -1), addDays(today, 9))
    time("Coming up, 120 days", addDays(today, -1), addDays(today, 120))
    let y = cal.dateInterval(of: .year, for: today)!
    time("Year view, whole year", addDays(y.start, -1), addDays(y.end, 2))
    time("Quick add past events, one year", addDays(today, -365), today)
    return (try? out.write(toFile: path, atomically: true, encoding: .utf8)) == nil ? 1 : 0
}

// --timing-file <file.ics>: how long a subscribed calendar's file takes to read and to show. Saves nothing.
public func timingFile(_ path: String) -> Int32 {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("Can't read \(path)"); return 1 }
    func ms(_ work: () -> Int) -> String {
        var runs: [Double] = [], n = 0
        for _ in 0..<5 { let t = Date(); n = work(); runs.append(Date().timeIntervalSince(t) * 1000) }
        return "\(Int(runs.sorted()[2])) ms (\(n))"
    }
    let events = parseICS(text), s = Sub(url: "", name: "timing", color: 0), today = cal.startOfDay(for: Date())
    print("Read the file:", ms { parseICS(text).count })
    print("Show a week:", ms { subItems(s, events, from: today, to: addDays(today, 9)).count })
    print("Show 120 days:", ms { subItems(s, events, from: today, to: addDays(today, 120)).count })
    print("Show a year:", ms { subItems(s, events, from: today, to: addDays(today, 365)).count })
    return 0
}

