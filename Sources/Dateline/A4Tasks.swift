// A4 tasks in Dateline: task notes in John's vault shown beside Apple Reminders (approved design, 2026-10-31).
// A change goes into the note itself, touching only the lines it changes. Finishing a task goes through A4's own task engine in the running Obsidian, because only that files it in the Archive and moves a repeating task on.
// Sample mode (every test and picture) keeps made-up tasks in memory and never reads the vault.
import SwiftUI

struct A4Task: Equatable {
    var status = "open"
    var priority = "normal"
    var file = ""  // the note's full path
    var repeating = false
    var time = ""  // "T09:30" when the Due property holds a clock time; Dateline moves the day and keeps it
    static let statuses = [("open", "Open"), ("in-progress", "In progress"), ("blocked", "Blocked"), ("done", "Done")]
    static let priorities = ["low", "normal", "high"]
    static let finished = ["done", "closed"]
}

let a4Color = Color(red: 0.49, green: 0.36, blue: 0.82)
let a4Account = "A4"
let a4DefaultFolder = NSHomeDirectory() + "/Projects/A4/02 Planner/TaskNotes/Tasks"

// MARK: reading and changing a note (pure, covered by --selftest and --a4-check)

// The lines of a note and where its properties end; nil when it has no properties block.
func a4Front(_ text: String) -> (lines: [String], end: Int)? {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
    return (lines, end)
}

func a4Clean(_ s: some StringProtocol) -> String {
    var v = s.trimmingCharacters(in: .whitespaces)
    if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
    return v
}

func a4Value(_ f: (lines: [String], end: Int), _ key: String) -> String {
    guard let l = f.lines[1..<f.end].first(where: { $0.hasPrefix(key + ":") }) else { return "" }
    return a4Clean(l.dropFirst(key.count + 1))
}

// A property holding a list: "- a" lines under it, or [a, b] on its own line, or one plain value.
func a4List(_ f: (lines: [String], end: Int), _ key: String) -> [String] {
    guard let i = f.lines[1..<f.end].firstIndex(where: { $0.hasPrefix(key + ":") }) else { return [] }
    let own = f.lines[i].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
    if own.hasPrefix("[") { return own.dropFirst().dropLast().split(separator: ",").map { a4Clean($0) } }
    if !own.isEmpty { return [a4Clean(own)] }
    return f.lines[(i + 1)..<f.end].prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
        .map { a4Clean($0.trimmingCharacters(in: .whitespaces).dropFirst(2)) }
}

// The note with these one-line properties changed (nil removes one, "" keeps it empty) and every other byte as it was.
func a4Edit(_ text: String, _ set: [(String, String?)]) -> String? {
    guard var f = a4Front(text) else { return nil }
    for (key, value) in set {
        let i = f.lines[1..<f.end].firstIndex { $0.hasPrefix(key + ":") }
        let line = value.map { $0.isEmpty ? key + ":" : key + ": " + $0 }
        switch (i, line) {
        case let (i?, line?): f.lines[i] = line
        case let (i?, nil): f.lines.remove(at: i); f.end -= 1
        case let (nil, line?): f.lines.insert(line, at: f.end); f.end += 1
        case (nil, nil): break
        }
    }
    return f.lines.joined(separator: "\n")
}

func a4Day(_ d: Date) -> String { let c = cal.dateComponents([.year, .month, .day], from: d); return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!) }

func a4ParseDay(_ s: String) -> Date? {
    let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard s.count >= 10, p.count == 3 else { return nil }
    return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
}

// The time stamp A4 writes in dateModified: local time with its offset.
func a4Stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx"
    return f.string(from: d)
}

// The project's name from its link: "[[04 Inner World/Projects/Home|Home]]" is Home.
func a4Project(_ link: String) -> String {
    let inner = link.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
    let path = inner.split(separator: "|").first.map(String.init) ?? inner
    let name = path.split(separator: "/").last.map(String.init) ?? path
    return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
}

// One note as a task; nil for what A4 doesn't show as a task: no task tag, archived, kept for Someday, or finished over a week ago.
// shortcut: a task finished through A4's engine leaves here when A4 files it in the Archive (about 5 minutes), because reopening one takes A4's own un-archive; read the Archive too if done tasks should stay the week.
func a4Read(_ text: String, file: String, now: Date) -> ToDo? {
    guard let f = a4Front(text) else { return nil }
    let tags = a4List(f, "tags")
    guard tags.contains("task"), !tags.contains("archived"), a4Value(f, "archived") != "true" else { return nil }
    let status = a4Value(f, "status")
    guard status != "someday" else { return nil }
    let done = A4Task.finished.contains(status)
    if done {
        guard let d = a4ParseDay(a4Value(f, "completedDate")), d >= addDays(cal.startOfDay(for: now), -7) else { return nil }
    }
    let repeating = !a4Value(f, "recurrence").isEmpty
    // A repeating task's `scheduled` is its current occurrence, the day A4 Today shows it on.
    let raw = repeating && !a4Value(f, "scheduled").isEmpty ? a4Value(f, "scheduled") : a4Value(f, "due")
    let name = (file as NSString).lastPathComponent
    let title = a4Value(f, "title")
    let project = a4List(f, "projects").first.map(a4Project) ?? "Inbox"
    let body = f.lines[(f.end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let priority = a4Value(f, "priority")
    return ToDo(id: "a4:" + file, listID: "a4:" + project, title: title.isEmpty ? String(name.dropLast(3)) : title, due: a4ParseDay(raw), done: done || (repeating && a4List(f, "complete_instances").contains(String(raw.prefix(10)))), notes: String(body.prefix(2000)),
                a4: A4Task(status: status.isEmpty ? "open" : status, priority: priority.isEmpty ? "normal" : priority, file: file, repeating: repeating, time: raw.count > 10 ? String(raw.dropFirst(10)) : ""))
}

// Every task in the folder.
func a4Scan(_ folder: String, now: Date) -> [ToDo] {
    guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.compactMap { u in
        (try? String(contentsOf: u, encoding: .utf8)).flatMap { a4Read($0, file: u.path, now: now) }
    }
}

// The lines that change when `old` becomes `new` in the note `text`. Finishing is not here: that goes through A4's engine.
func a4Changes(old: ToDo, new: ToDo, text: String, now: Date) -> [(String, String?)] {
    guard let o = old.a4, let n = new.a4 else { return [] }
    var set: [(String, String?)] = []
    if old.due != new.due {
        let v = new.due.map { a4Day($0) + n.time } ?? ""
        if n.repeating, let f = a4Front(text) {
            set.append(("scheduled", v))
            // A repeating task's Due moves by the same days, so its gap from the current day survives a move and its undo.
            let due = a4Value(f, "due")
            if let was = old.due, let now = new.due, let d = a4ParseDay(due), let by = cal.dateComponents([.day], from: was, to: now).day {
                set.append(("due", a4Day(addDays(d, by)) + due.dropFirst(10)))
            }
        } else {
            set.append(("due", v))
            if new.due == nil { set += [("planned_day", nil), ("planned_half", nil), ("planned_order", nil)] }  // as A4's own unschedule, or the task stays on that day in Today
        }
    }
    if o.priority != n.priority { set.append(("priority", n.priority)) }
    if o.status != n.status {
        set.append(("status", n.status))
        if !n.repeating { set.append(("completedDate", A4Task.finished.contains(n.status) ? a4Day(now) : nil)) }
    }
    if !set.isEmpty { set.append(("dateModified", a4Stamp(now))) }
    return set
}

// MARK: A4's engine, through the running Obsidian (the same route as the task reminders job)

enum A4Answer: Equatable { case closed, ok, failed(String) }

// Runs inside Obsidian. `day` set: tick (or untick) that one occurrence of a repeating task.
func a4EngineCode(vault: String, path: String, day: String?) -> String {
    let a = (try? JSONSerialization.data(withJSONObject: ["vault": vault, "path": path, "day": day ?? ""])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    return "(async () => { const a = \(a); const out = (o) => JSON.stringify(o); if (app.vault.getName() !== a.vault) return out({ r: 'closed' }); const pl = app.plugins.plugins; const own = pl['a4-projects'] || (pl.lifeworld && pl.lifeworld.running && pl.lifeworld.running['a4-projects']); const api = own && typeof own.taskApi === 'function' ? own.taskApi() : null; if (!api) return out({ r: 'noapi' }); if (!app.vault.getAbstractFileByPath(a.path)) return out({ r: 'gone' }); if (a.day) await api.recurring.toggleCompleteInstance(a.path, a.day); else await api.tasks.complete(a.path); return out({ r: 'ok' }); })()"
}

// The vault a file is in: the nearest folder above it holding .obsidian.
func a4Vault(_ file: String) -> String? {
    var d = (file as NSString).deletingLastPathComponent
    while d.count > 1 {
        if FileManager.default.fileExists(atPath: d + "/.obsidian") { return d }
        d = (d as NSString).deletingLastPathComponent
    }
    return nil
}

// The program's output, or nil when it didn't finish in time.
func a4Run(_ tool: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, out: String)? {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.standardOutput = pipe; p.standardError = pipe
    guard (try? p.run()) != nil else { return nil }
    let killer = DispatchWorkItem { p.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return p.terminationReason == .uncaughtSignal ? nil : (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// Never starts Obsidian: closed is an answer of its own, and the caller decides.
func a4Engine(file: String, day: String?) -> A4Answer {
    guard let vault = a4Vault(file), a4Run("/usr/bin/pgrep", ["-x", "Obsidian"], timeout: 10)?.status == 0 else { return .closed }
    guard let cli = ["/opt/homebrew/bin/obsidian", "/usr/local/bin/obsidian", "/Applications/Obsidian.app/Contents/MacOS/obsidian-cli"].first(where: FileManager.default.fileExists(atPath:)) else { return .failed("Dateline can't reach Obsidian: its command line tool isn't turned on.") }
    let name = (vault as NSString).lastPathComponent
    let code = a4EngineCode(vault: name, path: String(file.dropFirst(vault.count + 1)), day: day)
    guard let r = a4Run(cli, ["vault=\(name)", "eval", "code=" + code], timeout: 30) else { return .failed("Obsidian didn't answer. The task may still have changed; look at it there.") }
    guard let line = r.out.split(separator: "\n").last(where: { $0.hasPrefix("=> ") }) else { return .failed("Obsidian didn't take the change: " + r.out.suffix(200)) }
    if line.contains("'ok'") || line.contains("\"ok\"") { return .ok }
    if line.contains("\"closed\"") || line.contains("'closed'") { return .closed }
    if line.contains("noapi") { return .failed("A4's tasks aren't running in Obsidian yet. Try again in a moment.") }
    return .failed("That task is gone.")
}

extension Store {
    // Reads the folder in the background and swaps the tasks in when they changed.
    func reloadA4() {
        guard access != .sample, a4Busy == 0 else { return }
        a4Fetch += 1
        let n = a4Fetch, on = a4On, folder = a4Folder
        Task.detached(priority: .utility) {
            let found = on ? a4Scan(folder, now: Date()) : []
            await MainActor.run { if n == self.a4Fetch, self.a4Busy == 0 { self.showA4(found) } }
        }
    }

    private func showA4(_ found: [ToDo]) {
        let sorted = found.sorted { $0.id < $1.id }
        if todos.filter({ $0.a4 != nil }).sorted(by: { $0.id < $1.id }) != sorted { todos = todos.filter { $0.a4 == nil } + sorted }
        let names = Set(found.map(\.listID)).sorted()
        if lists.filter({ $0.account == a4Account }).map(\.id) != names {
            lists = lists.filter { $0.account != a4Account } + names.map { CalInfo(id: $0, title: "A4: " + $0.dropFirst(3), account: a4Account, color: a4Color, writable: false) }
        }
    }

    // A changed A4 task, from the task details, a tick or a drop.
    func updateA4(_ t: ToDo, old: ToDo?) -> Failure? {
        guard let old, var a = t.a4 else { return Failure("That task has been filed in A4's Archive, or is gone. Look for it in Obsidian.") }
        if a4Busy > 0 { return Failure("Still saving the last change to Obsidian. Try again in a moment.") }  // A4's engine would write over this when it finishes
        if old.done != t.done, A4Task.finished.contains(a.status) == old.done { a.status = t.done ? "done" : "open" }  // a tick changes only `done`
        var t = t; t.a4 = a
        let finishing = t.done && !old.done && !a.repeating
        var fileNew = t
        if finishing { fileNew.a4?.status = old.a4?.status ?? "open" }  // the engine writes the status
        guard let text = try? String(contentsOfFile: a.file, encoding: .utf8) else { reloadA4(); return Failure("That task is gone.") }
        let set = a4Changes(old: old, new: fileNew, text: text, now: Date())
        if !set.isEmpty {
            guard let edited = a4Edit(text, set) else { return Failure("That task's note couldn't be read.") }
            do { try edited.write(toFile: a.file, atomically: true, encoding: .utf8) } catch { reloadA4(); return Failure(error.localizedDescription) }
        }
        if let i = todos.firstIndex(where: { $0.id == t.id }) { todos[i] = t }  // shows at once; the reload that follows confirms it
        if finishing { a4Finish(t) } else { reloadA4() }
        return nil
    }

    private func a4Finish(_ t: ToDo) {
        guard let file = t.a4?.file else { return }
        a4Busy += 1
        Task.detached(priority: .userInitiated) {
            var answer = a4Engine(file: file, day: nil)
            if answer == .closed {
                // Obsidian closed: the note says done, as A4 writes it; only the move to the Archive, which A4 does itself, doesn't happen.
                let now = Date()
                let text = try? String(contentsOfFile: file, encoding: .utf8)
                let edited = text.flatMap { a4Edit($0, [("status", "done"), ("completedDate", a4Day(now)), ("dateModified", a4Stamp(now))]) }
                answer = (try? edited?.write(toFile: file, atomically: true, encoding: .utf8)) != nil ? .ok : .failed("That task's note couldn't be changed.")
            }
            let done = answer
            await MainActor.run { self.a4Busy -= 1; if case .failed(let m) = done { self.onError?(m) }; self.reloadA4() }
        }
    }

    // A tick on a repeating task: that day's occurrence only, and ticking it again takes it back.
    func a4Tick(_ t: ToDo, then: @escaping @MainActor () -> Void = {}) -> Failure? {
        guard let file = t.a4?.file else { return Failure("That task is gone.") }
        if access == .sample { return nil }
        if a4Busy > 0 { return Failure("Still saving the last change to Obsidian. Try again in a moment.") }
        let day = a4Day(t.due ?? Date())  // never nil: with no day the engine would finish the whole repeating task
        a4Busy += 1
        if let i = todos.firstIndex(where: { $0.id == t.id }) { todos[i].done = !t.done }
        Task.detached(priority: .userInitiated) {
            let answer = a4Engine(file: file, day: day)
            await MainActor.run {
                self.a4Busy -= 1
                // shortcut: a repeating task needs Obsidian open, because working out its next day lives in A4's engine; port the rule if ticking with Obsidian closed matters.
                if answer == .closed { self.onError?("Open Obsidian to tick a repeating A4 task.") } else if case .failed(let m) = answer { self.onError?(m) } else { then() }
                self.todos = self.todos.map { var x = $0; if x.id == t.id { x.done = t.done }; return x }
                self.reloadA4()
            }
        }
        return nil
    }

    func a4Set(on: Bool? = nil, folder: String? = nil) {
        if let on { a4On = on; if access != .sample { UserDefaults.standard.set(on, forKey: "a4On") } }
        if let folder { a4Folder = folder; if access != .sample { UserDefaults.standard.set(folder, forKey: "a4Folder") } }
        reloadReminders()  // the A4 Tasks list in Reminders comes back when A4 tasks are off
        reloadA4()
    }
}

// The real-data check, run on a copy of the tasks folder: every note reads, a change touches only its own lines, and nothing else in the folder changes.
func a4Check(_ folder: String) -> Int32 {
    if a4Vault(folder + "/x") != nil { print("refused: that folder is in an Obsidian vault; this check changes the files it is given, so give it a copy"); return 2 }
    let now = Date()
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL:", what) } }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".md") }.sorted() ?? []
    let tasks = a4Scan(folder, now: now)
    print("notes: \(files.count), shown as tasks: \(tasks.count), not done: \(tasks.filter { !$0.done }.count), with a date: \(tasks.filter { $0.due != nil }.count), repeating: \(tasks.filter { $0.a4?.repeating == true }.count), projects: \(Set(tasks.map(\.listID)).count)")
    for t in tasks {
        guard let a = t.a4, let text = try? String(contentsOfFile: a.file, encoding: .utf8) else { expect(false, "reads back: \(t.id)"); continue }
        expect(!t.title.isEmpty, "has a title: \(t.id)")
        var n = t; n.due = addDays(cal.startOfDay(for: now), 3); n.a4?.priority = a.priority == "high" ? "low" : "high"; n.a4?.status = a.status == "blocked" ? "open" : "blocked"
        let set = a4Changes(old: t, new: n, text: text, now: now)
        guard let edited = a4Edit(text, set) else { expect(false, "edits: \(t.id)"); continue }
        // Only the named property lines may differ.
        let keys = set.map(\.0)
        func others(_ s: String) -> [String] {
            guard let f = a4Front(s) else { return [] }
            return f.lines.enumerated().filter { i, l in !(i > 0 && i < f.end && keys.contains { l.hasPrefix($0 + ":") }) }.map(\.element)
        }
        expect(others(text) == others(edited), "only its own lines change: \(t.id)")
        guard let back = a4Read(edited, file: a.file, now: now) else { expect(false, "still reads after a change: \(t.id)"); continue }
        expect(back.due == n.due && back.a4?.priority == n.a4?.priority && back.a4?.status == n.a4?.status, "the change reads back: \(t.id)")
        expect(a4Edit(text, []) == text, "no change leaves every byte: \(t.id)")
        try? edited.write(toFile: a.file, atomically: true, encoding: .utf8)  // on the copy: the caller compares the folder afterwards
    }
    print(fails == 0 ? "a4 check: all passed" : "a4 check: \(fails) failed")
    return fails == 0 ? 0 : 1
}

func a4Selftest(_ expect: (Bool, String) -> Void) {
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
    let note = "---\nstatus: open\npriority: normal\ndue: 2026-10-25T09:30\nprojects:\n  - \"[[04 Inner World/Projects/Home|Home]]\"\ntags:\n  - task\n---\n\nFix it.\n---\nmore\n"
    let t = a4Read(note, file: "/v/Fix the gate.md", now: now)
    expect(t?.title == "Fix the gate" && t?.listID == "a4:Home" && t?.a4?.time == "T09:30" && t?.notes == "Fix it.\n---\nmore" && t?.done == false, "a4: reads a note")
    expect(t?.due == cal.date(from: DateComponents(year: 2026, month: 10, day: 25)) && isOverdue(t!, now: now) && taskRowDay(t!, now: now) == cal.startOfDay(for: now), "a4: an overdue task shows on today")
    expect(a4Read("no properties", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: open\n---\n", file: "/v/x.md", now: now) == nil, "a4: a note that isn't a task is skipped")
    expect(a4Read("---\nstatus: someday\ntags: [task]\n---\n", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: open\ntags:\n  - task\n  - archived\n---\n", file: "/v/x.md", now: now) == nil, "a4: Someday and archived are skipped")
    expect(a4Read("---\nstatus: done\ncompletedDate: 2026-10-01\ntags: [task]\n---\n", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: done\ncompletedDate: 2026-10-30\ntags: [task]\n---\n", file: "/v/x.md", now: now)?.done == true, "a4: done tasks stay a week")
    let rep = a4Read("---\nstatus: open\ndue: 2026-10-25\nscheduled: 2026-10-31\nrecurrence: DTSTART:20260904;FREQ=DAILY\ntags: [task]\n---\n", file: "/v/r.md", now: now)
    expect(rep?.a4?.repeating == true && rep?.due == cal.startOfDay(for: now), "a4: a repeating task sits on its current occurrence")
    expect(a4Edit(note, [("due", "2026-11-02T09:30"), ("completedDate", "2026-10-31")]) == note.replacingOccurrences(of: "due: 2026-10-25T09:30", with: "due: 2026-11-02T09:30").replacingOccurrences(of: "  - task\n---", with: "  - task\ncompletedDate: 2026-10-31\n---"), "a4: an edit touches only its lines")
    expect(a4Edit("---\ndue: 2026-10-25\ncompletedDate: 2026-10-30\n---\n---\n", [("due", ""), ("completedDate", nil)]) == "---\ndue:\n---\n---\n", "a4: empties Due, removes the rest, leaves the text alone")
    expect(a4Edit("no block", [("due", "x")]) == nil, "a4: never edits a note with no properties")
    var moved = t!; moved.due = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))
    expect(a4Changes(old: t!, new: moved, text: note, now: now).first?.1 == "2026-11-02T09:30", "a4: moving the day keeps the clock time")
    var r2 = rep!; r2.due = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))
    let shifted = a4Changes(old: rep!, new: r2, text: "---\ndue: 2026-10-25\nscheduled: 2026-10-31\n---\n", now: now)
    expect(shifted[0].0 == "scheduled" && shifted[0].1 == "2026-11-02" && shifted[1].0 == "due" && shifted[1].1 == "2026-10-27", "a4: moving a repeating task keeps the gap to its Due")
    expect(a4Read("---\nstatus: open\nscheduled: 2026-10-31\nrecurrence: FREQ=DAILY\ncomplete_instances:\n  - 2026-10-31\ntags: [task]\n---\n", file: "/v/r.md", now: now)?.done == true, "a4: a repeating day already ticked shows ticked")
    var cleared = t!; cleared.due = nil
    expect(a4Edit("---\ndue: 2026-10-25\nplanned_day: 2026-10-25\nplanned_half: am\n---\n", a4Changes(old: t!, new: cleared, text: note, now: now))?.contains("planned_") == false, "a4: clearing Due takes the task off A4's planned day")
    var reopened = a4Read("---\nstatus: done\ncompletedDate: 2026-10-30\ntags: [task]\n---\n", file: "/v/x.md", now: now)!; let was = reopened; reopened.a4?.status = "open"; reopened.done = false
    expect(a4Changes(old: was, new: reopened, text: "", now: now).contains { $0.0 == "completedDate" && $0.1 == nil }, "a4: reopening removes the done day")
    expect(a4Project("[[a/b/Home.md|H]]") == "Home" && a4Project("Plain") == "Plain", "a4: project names")
    expect(a4Stamp(now).hasPrefix("2026-10-31T09:00:00.000") && a4Stamp(now).count == 29, "a4: A4's time stamp")
    MainActor.assumeIsolated {
        let d = UserDefaults.standard, before = (d.object(forKey: "a4On") as? Bool, d.string(forKey: "a4Folder"))
        let a = AppState(store: Store(sample: true), today: now)
        a.store.a4Set(on: false, folder: "/selftest")
        expect((d.object(forKey: "a4On") as? Bool, d.string(forKey: "a4Folder")) == before, "a4: tests never change the saved A4 settings")
        a.store.use(CalSet(name: "W", calendars: [], lists: []))
        expect(a.store.lists.filter { $0.account == a4Account }.allSatisfy { !a.store.hiddenLists.contains($0.id) }, "a4: a saved set never hides A4 projects")
        let s = a.store.todos.first { $0.a4 != nil && $0.due != nil }!
        var n = s; n.done = true; a.saveTask(n)
        expect(a.store.todos.first { $0.id == s.id }?.done == true && a.store.lists.filter { $0.account == a4Account }.allSatisfy { !$0.writable }, "a4: a sample tick stays in memory; no moving reminders into A4")
        if case .failure = a.store.addTask(ToDo(id: "", listID: "", title: "x"), listID: "a4-home") {} else { expect(false, "a4: new tasks can't go in an A4 list") }
    }
}

// Task details for an A4 task: Due, Status and Priority change here. The title and the note's text stay in Obsidian, because renaming the file from here would break the links to it.
struct A4TaskDetail: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var task: ToDo
    var body: some View {
        let info = task.a4 ?? A4Task()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("A4 TASK").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                    Spacer()
                    Button { app.openTaskID = nil } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 10)
                HStack(alignment: .top, spacing: 8) {
                    TaskCircle(done: task.done, color: a4Color, size: 16) { let was = task.done; task.done.toggle(); task.a4?.status = task.done ? "done" : "open"; app.saveTask(task); if info.repeating { task.done = was; task.a4?.status = info.status } }.padding(.top, 3)
                    Text(task.title).font(.ui(17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                row("Project") { HStack(spacing: 6) { Circle().fill(a4Color).frame(width: 8, height: 8); Text((store.taskList(task.listID)?.title ?? "").replacingOccurrences(of: "A4: ", with: "")) } }
                row("Due") {
                    if let d = task.due {
                        DatePicker("", selection: Binding(get: { d }, set: { task.due = cal.startOfDay(for: $0); app.saveTask(task) }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        if !info.repeating { Button { task.due = nil; app.saveTask(task) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.text3).help("Clear the Due property") }
                    } else {
                        Button("Add a date") { task.due = cal.startOfDay(for: app.now); app.saveTask(task) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                }
                row("Status") {
                    Menu {
                        ForEach(A4Task.statuses, id: \.0) { s in Button(s.1) { setStatus(s.0) } }
                    } label: { Text(A4Task.statuses.first { $0.0 == info.status }?.1 ?? info.status) }.menuStyle(.borderlessButton).fixedSize()
                }
                row("Priority") {
                    Menu {
                        ForEach(A4Task.priorities, id: \.self) { p in Button(p.capitalized) { task.a4?.priority = p; app.saveTask(task) } }
                    } label: { Text(info.priority.capitalized) }.menuStyle(.borderlessButton).fixedSize()
                }
                Text("NOTE").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 18).padding(.bottom, 6)
                Text(task.notes.isEmpty ? "No text in this note." : task.notes).font(.ui(13)).foregroundStyle(task.notes.isEmpty ? Palette.text3 : Palette.text2)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                Button("Open in Obsidian") { openInObsidian(info.file) }.padding(.top, 12)
                Text("Saved in your A4 vault, so Obsidian sees each change. Change the title and the note's text in Obsidian.")
                    .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            .padding(16)
        }
        .background(Palette.win)
        .onChange(of: store.todos) { _, list in
            // Changed in Obsidian, or by a tick in the calendar, while open.
            if let fresh = list.first(where: { $0.id == task.id }), fresh != task { task = fresh }
        }
    }

    func setStatus(_ s: String) {
        if task.a4?.repeating == true && s == "done" { var n = task; n.done = true; app.saveTask(n); return }  // ticks today's occurrence; the task itself stays open
        task.a4?.status = s; task.done = A4Task.finished.contains(s); app.saveTask(task)
    }

    func openInObsidian(_ file: String) {
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "path", value: file)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 52, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 10)
    }
}

struct A4Settings: View {
    @ObservedObject var store: Store
    var body: some View {
        let count = store.todos.filter { $0.a4 != nil && !$0.done }.count
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show A4 tasks on the calendar", isOn: Binding(get: { store.a4On }, set: { store.a4Set(on: $0) })).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tasks folder").font(.ui(13, weight: .semibold))
                HStack(spacing: 8) {
                    Text((store.a4Folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(store.a4Folder)
                    Button("Choose\u{2026}") {
                        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false; o.directoryURL = URL(fileURLWithPath: store.a4Folder)
                        if o.runModal() == .OK, let u = o.url { store.a4Set(folder: u.path) }
                    }
                }
                Text(FileManager.default.fileExists(atPath: store.a4Folder) || store.access == .sample
                     ? "Found \(count) tasks that aren't done. Tasks with a Due property show on the calendar; the rest sit under No date, by project."
                     : "That folder isn't on this Mac.")
                    .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 480, alignment: .leading)
    }
}

extension Store {
    // Made-up A4 tasks for the pictures (Monday `mon`).
    func loadSampleA4(_ mon: Date) {
        let projects = [("a4-launch", "A4: Dateline launch"), ("a4-home", "A4: Home"), ("a4-reading", "A4: Reading Vault")]
        lists += projects.map { CalInfo(id: $0.0, title: $0.1, account: a4Account, color: a4Color, writable: false) }
        func t(_ list: String, _ title: String, _ day: Int?, status: String = "open", priority: String = "normal", notes: String = "") {
            todos.append(ToDo(id: "a4-\(title)", listID: list, title: title, due: day.map { addDays(mon, $0) }, notes: notes, a4: A4Task(status: status, priority: priority, file: "/sample/" + title + ".md")))
        }
        t("a4-launch", "Choose a license for Dateline", 0, priority: "high", notes: "Compare MIT and GPL, then add the file to the repo.")
        t("a4-home", "Pay the water bill", -2, status: "in-progress")
        t("a4-reading", "Answer buyer questions", 1)
        t("a4-launch", "Bring the GitHub page up to date", 3)
        for s in ["Sign the app", "Check the code is safe to share"] { t("a4-launch", s, nil) }
        for s in ["Fix the gate latch", "Sort the garage", "Renew the car papers"] { t("a4-home", s, nil) }
    }
}
