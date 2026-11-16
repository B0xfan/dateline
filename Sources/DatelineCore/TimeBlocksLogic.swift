// Free time blocks from LifeWorld's Planner (Lunch, Gym, Free time): not tasks, kept in one vault note that LifeWorld and Dateline both write
// (GL-002 "Time blocks", ruled 2026-11-16). Dateline shows them as a calendar of their own, striped, and changes one entry at a time by its id.
// Sample mode keeps them in memory and never reads the vault.
import SwiftUI

public struct TimeBlock: Equatable, Sendable {
    public var id = "", date = "", time = "", minutes = 30, title = ""  // date "YYYY-MM-DD", time "HH:MM"
    public init(id: String, date: String, time: String, minutes: Int, title: String) { self.id = id; self.date = date; self.time = time; self.minutes = minutes; self.title = title }
}

public let blocksCalendar = "a4-blocks"
public func isBlocks(_ calendarID: String) -> Bool { calendarID == blocksCalendar }

// The note next to the tasks folder's vault: <vault>/02 Planner/Time Blocks.md.
public func blocksFile(_ tasksFolder: String) -> String? { a4Vault(tasksFolder + "/x").map { $0 + "/02 Planner/Time Blocks.md" } }

private func yamlValue(_ raw: some StringProtocol) -> String {
    let v = raw.trimmingCharacters(in: .whitespaces)
    if v.hasPrefix("\""), let s = try? JSONDecoder().decode(String.self, from: Data(v.utf8)) { return s }  // YAML's double quotes escape as JSON does
    if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") { return String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
    return v
}

// Where the `blocks` list sits in the note's properties: its own line up to the next property. nil when there is none.
private func blocksRange(_ f: (lines: [String], end: Int)) -> Range<Int>? {
    guard let i = f.lines[1..<f.end].firstIndex(where: { $0.hasPrefix("blocks:") }) else { return nil }
    let next = f.lines[(i + 1)..<f.end].firstIndex { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("-") } ?? f.end
    return i..<next
}

// Every block in the note; nil when the note or any entry can't be read for sure, so Dateline never writes over what it doesn't understand.
public func blocksRead(_ text: String) -> [TimeBlock]? {
    guard let f = a4Front(text) else { return nil }
    guard let r = blocksRange(f) else { return [] }
    let own = f.lines[r.lowerBound].dropFirst("blocks:".count).trimmingCharacters(in: .whitespaces)
    if own == "[]" { return r.count == 1 ? [] : nil }
    guard own.isEmpty else { return nil }  // a list on one line: not what either app writes
    var entries: [[String: String]] = []
    for line in f.lines[(r.lowerBound + 1)..<r.upperBound] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        var l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") { entries.append([:]); l = String(l.dropFirst(2)) } else if entries.isEmpty { return nil }
        guard let c = l.firstIndex(of: ":") else { return nil }
        entries[entries.count - 1][String(l[..<c])] = yamlValue(l[l.index(after: c)...])
    }
    var out: [TimeBlock] = []
    for e in entries {
        guard let id = e["id"], !id.isEmpty, let date = e["date"], a4ParseDay(date) != nil, let time = e["time"], a4Minutes(date + "T" + time) != nil,
              let m = e["minutes"].flatMap({ Int($0) }), m > 0, Set(e.keys).isSubset(of: ["id", "date", "time", "minutes", "title"]) else { return nil }
        out.append(TimeBlock(id: id, date: date, time: time, minutes: m, title: e["title"] ?? ""))
    }
    return out
}

// The note with its `blocks` list replaced and every other line as it was. Every string is double quoted, which both apps read.
public func blocksWrite(_ text: String, _ blocks: [TimeBlock]) -> String? {
    guard var f = a4Front(text) else { return nil }
    func q(_ s: String) -> String { (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\"" }
    let lines = blocks.isEmpty ? ["blocks: []"] : ["blocks:"] + blocks.flatMap { b in
        ["  - id: \(q(b.id))", "    date: \(q(b.date))", "    time: \(q(b.time))", "    minutes: \(b.minutes)", "    title: \(q(b.title))"]
    }
    let r = blocksRange(f) ?? f.end..<f.end
    f.lines.replaceSubrange(r, with: lines)
    return f.lines.joined(separator: "\n")
}

// A block as an event on the grid.
public func blockItem(_ b: TimeBlock) -> Item? {
    guard let day = a4ParseDay(b.date), let m = a4Minutes(b.date + "T" + b.time), let start = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) else { return nil }
    return Item(id: "block:" + b.id, calendarID: blocksCalendar, title: b.title.isEmpty ? "Free time" : b.title, start: start, end: start.addingTimeInterval(Double(b.minutes * 60)), allDay: false, place: "", notes: "", showAs: .maybe)
}

// An event moved, stretched or renamed on the grid, back as its block. 15 minutes is the shortest, as in the Planner.
public func blockFrom(_ it: Item, id: String) -> TimeBlock {
    let c = cal.dateComponents([.hour, .minute], from: it.start)
    return TimeBlock(id: id, date: a4Day(it.start), time: String(format: "%02d:%02d", c.hour!, c.minute!), minutes: max(15, Int(it.end.timeIntervalSince(it.start) / 60)), title: it.title)
}

public func blockID() -> String { String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) }

extension Store {
    public var blocksInfo: CalInfo { CalInfo(id: blocksCalendar, title: "Time blocks", account: a4Account, color: .gray, writable: true) }

    public func blockEvents(from a: Date, to b: Date) -> [Item] { timeBlocks.compactMap(blockItem).filter { $0.end > a && $0.start < b } }

    // Swaps in a fresh read; the calendar shows only while the note is there.
    public func showBlocks(_ found: [TimeBlock]?) {
        let had = calendars.contains { isBlocks($0.id) }, changed = (found ?? []) != timeBlocks
        if changed { timeBlocks = found ?? [] }
        if (found != nil) != had { calendars = calendars.filter { !isBlocks($0.id) } + (found != nil ? [blocksInfo] : []) }
        if changed || (found != nil) != had { refetch() }
    }

    // Add, change (`it` set) or remove (`it` nil) one block, by its id. The note is read fresh first: Obsidian Sync may have changed it.
    public func saveBlock(id: String, _ it: Item?) -> Failure? {
        if let it, it.allDay { return Failure("A time block needs a time.") }
        func apply(_ list: [TimeBlock]) -> [TimeBlock]? {
            var list = list
            if let i = list.firstIndex(where: { $0.id == id }) {
                if let it { list[i] = blockFrom(it, id: id) } else { list.remove(at: i) }
            } else if let it { list.append(blockFrom(it, id: id)) } else { return nil }
            return list
        }
        if access == .sample {
            guard let next = apply(timeBlocks) else { return Failure("That time block is gone.") }
            timeBlocks = next; refetch(); return nil
        }
        guard let file = blocksFile(a4Folder), let text = try? String(contentsOfFile: file, encoding: .utf8) else { return Failure("The Planner's Time Blocks note isn't there any more.") }
        guard let now = blocksRead(text) else { return Failure("The Planner's Time Blocks note has something Dateline can't read, so it was left alone. Change it in Obsidian.") }
        guard let next = apply(now) else { reloadA4(); return Failure("That time block is gone.") }
        guard let edited = blocksWrite(text, next) else { return Failure("The Planner's Time Blocks note couldn't be read.") }
        do { try edited.write(toFile: file, atomically: true, encoding: .utf8) } catch { return Failure(error.localizedDescription) }
        timeBlocks = next; refetch()  // shows at once; the next read confirms it
        return nil
    }
}
