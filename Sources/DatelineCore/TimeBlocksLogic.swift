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

// nil for anything not read for sure (a comment, an escape YAML has and JSON doesn't), so the note is left alone.
private func yamlValue(_ raw: some StringProtocol) -> String? {
    let v = raw.trimmingCharacters(in: .whitespaces)
    if v.hasPrefix("\"") { return try? JSONDecoder().decode(String.self, from: Data(v.utf8)) }  // YAML's double quotes escape as JSON does
    if v.hasPrefix("'") {
        let inner = v.dropFirst().dropLast()
        return v.count >= 2 && v.hasSuffix("'") && !inner.replacingOccurrences(of: "''", with: "").contains("'") ? inner.replacingOccurrences(of: "''", with: "'") : nil
    }
    return v.contains(" #") || v.hasPrefix("#") || v.hasPrefix("\"") ? nil : v
}

// "7:00" or "07:00" as "07:00"; nil for anything else.
private func blockTime(_ s: String) -> String? {
    let p = s.split(separator: ":", omittingEmptySubsequences: false)
    guard p.count == 2, (1...2).contains(p[0].count), p[1].count == 2, p.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let h = Int(p[0]), let m = Int(p[1]), h < 24, m < 60 else { return nil }
    return String(format: "%02d:%02d", h, m)
}

// Where the `blocks` list sits in the note's properties: its own line up to the next property. nil when there is none.
private func blocksRange(_ f: (lines: [String], end: Int)) -> Range<Int>? {
    guard let i = f.lines[1..<f.end].firstIndex(where: { $0.hasPrefix("blocks:") }) else { return nil }
    let next = f.lines[(i + 1)..<f.end].firstIndex { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("-") } ?? f.end
    return i..<next
}

// The list's entries, each with its own lines. An entry that can't be read for sure has no block: it stays as written and isn't drawn (as in LifeWorld).
// nil when the list itself can't be read (a list on one line, a line outside any entry), so the note is never written.
private struct BlockList { var range: Range<Int>; var entries: [(at: Range<Int>, block: TimeBlock?)] }

private func blockList(_ f: (lines: [String], end: Int)) -> BlockList? {
    guard let r = blocksRange(f) else { return BlockList(range: f.end..<f.end, entries: []) }
    let own = f.lines[r.lowerBound].dropFirst("blocks:".count).trimmingCharacters(in: .whitespaces)
    if own == "[]" { return r.count == 1 ? BlockList(range: r, entries: []) : nil }
    guard own.isEmpty else { return nil }
    var starts: [Int] = []
    for i in (r.lowerBound + 1)..<r.upperBound {
        let l = f.lines[i].trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") || l == "-" { starts.append(i) } else if starts.isEmpty && !l.isEmpty { return nil }
    }
    return BlockList(range: r, entries: starts.indices.map { k in
        let at = starts[k]..<(k + 1 < starts.count ? starts[k + 1] : r.upperBound)
        return (at, blockEntry(f.lines[at]))
    })
}

// One entry, values quoted or not (Obsidian writes date and time bare, an all-digit id quoted). A blank title is Free time when drawn.
private func blockEntry(_ lines: ArraySlice<String>) -> TimeBlock? {
    var e: [String: String] = [:]
    for (n, line) in lines.enumerated() {
        var l = line.trimmingCharacters(in: .whitespaces)
        if n == 0 { l = String(l.dropFirst(2)) }  // the "- "
        if l.isEmpty { continue }
        guard let c = l.firstIndex(of: ":"), let v = yamlValue(l[l.index(after: c)...]) else { return nil }
        let k = String(l[..<c])
        guard e[k] == nil else { return nil }
        e[k] = v
    }
    guard let id = e["id"], !id.isEmpty, let date = e["date"], date.count == 10, a4ParseDay(date) != nil, let time = e["time"].flatMap(blockTime),
          let m = e["minutes"].flatMap({ Int($0) }), m >= 15, Set(e.keys).isSubset(of: ["id", "date", "time", "minutes", "title"]) else { return nil }
    return TimeBlock(id: id, date: date, time: time, minutes: m, title: e["title"] ?? "")
}

// Every block that can be read; nil when the list can't be.
public func blocksRead(_ text: String) -> [TimeBlock]? {
    guard let f = a4Front(text), let list = blockList(f) else { return nil }
    return list.entries.compactMap(\.block)
}

// The note with one entry, found by id, changed (`b` set), added, or removed (`b` nil); every other line as it was.
// nil when the list can't be read, or there is nothing to remove. Strings are double quoted, which both apps read.
public func blocksWrite(_ text: String, id: String, _ b: TimeBlock?) -> String? {
    guard var f = a4Front(text), let list = blockList(f) else { return nil }
    func q(_ s: String) -> String { (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\"" }
    let mine = b.map { b in ["  - id: \(q(b.id))", "    date: \(q(b.date))", "    time: \(q(b.time))", "    minutes: \(b.minutes)", "    title: \(q(b.title))"] } ?? []
    var body: [String] = [], found = false
    for e in list.entries {
        if !found, e.block?.id == id { found = true; body += mine } else { body += f.lines[e.at] }
    }
    if !found { guard b != nil else { return nil }; body += mine }
    f.lines.replaceSubrange(list.range, with: body.isEmpty ? ["blocks: []"] : ["blocks:"] + body)
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

public func blockID(taken: [String]) -> String {
    while true {
        let id = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        if !taken.contains(id) { return id }
    }
}

extension Store {
    public var blocksInfos: [CalInfo] { calendars.contains { isBlocks($0.id) } ? [blocksInfo] : [] }  // kept when the calendars are read again
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
        if it == nil, !now.contains(where: { $0.id == id }) { reloadA4(); return Failure("That time block is gone.") }
        guard let edited = blocksWrite(text, id: id, it.map { blockFrom($0, id: id) }) else { return Failure("The Planner's Time Blocks note couldn't be read.") }
        do { try edited.write(toFile: file, atomically: true, encoding: .utf8) } catch { return Failure(error.localizedDescription) }
        timeBlocks = blocksRead(edited) ?? now; refetch()  // shows at once; the next read confirms it
        return nil
    }
}
