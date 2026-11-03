// A4 tasks in Dateline: task notes in John's vault shown beside Apple Reminders (approved design, 2026-10-31).
// A change goes into the note itself, touching only the lines it changes. Finishing a task goes through A4's own task engine in the running Obsidian, because only that files it in the Archive and moves a repeating task on.
// Sample mode (every test and picture) keeps made-up tasks in memory and never reads the vault.
import SwiftUI

struct A4Task: Equatable {
    var status = "open"
    var priority = "normal"
    var file = ""  // the note's full path
    var repeating = false
    var sphere = ""  // "work" or "personal", from the task's project note; it picks the calendar
    var ring = false  // a time just given in Dateline rings at that time, as a first time does in A4; an undo never sets this, so it can't wake a silenced task
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

// The clock time in a stored date, in minutes: "2026-11-03T11:00" is 660. The same reading as A4's timeOf.
func a4Minutes(_ s: String) -> Int? {
    guard let r = s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}", options: .regularExpression),
          let h = Int(s[r].suffix(5).prefix(2)), let m = Int(s[r].suffix(2)), h <= 23, m <= 59 else { return nil }
    return h * 60 + m
}

// A repeating task's time when its day has none: the clock in its rule's DTSTART. Midnight counts as none. The same reading as A4's ruleTimeOf.
func a4RuleMinutes(_ rule: String) -> Int? {
    guard let r = rule.range(of: "DTSTART(;[^:\\n]*)?[:=][0-9]{8}T[0-9]{4}", options: [.regularExpression, .caseInsensitive]),
          let h = Int(rule[r].suffix(4).prefix(2)), let m = Int(rule[r].suffix(2)), h <= 23, m <= 59, h + m > 0 else { return nil }
    return h * 60 + m
}

// A date as A4 stores it: the day, with the clock time when there is one.
func a4When(_ d: Date, timed: Bool) -> String {
    guard timed else { return a4Day(d) }
    let c = cal.dateComponents([.hour, .minute], from: d)
    return a4Day(d) + String(format: "T%02d:%02d", c.hour!, c.minute!)
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

func a4Body(_ f: (lines: [String], end: Int)) -> String { f.lines[(f.end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }

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
    let rule = a4Value(f, "recurrence"), repeating = !rule.isEmpty
    // A repeating task's `scheduled` is its current occurrence, the day A4 Today shows it on.
    let scheduled = a4Value(f, "scheduled"), due = a4Value(f, "due")
    let raw = repeating && !scheduled.isEmpty ? scheduled : due
    let minutes = repeating ? a4Minutes(scheduled) ?? a4RuleMinutes(rule) : a4Minutes(due)
    let day = a4ParseDay(raw)
    let when = day.map { d in minutes.flatMap { cal.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: d) } ?? d }
    let name = (file as NSString).lastPathComponent
    let title = a4Value(f, "title")
    let project = a4List(f, "projects").first.map(a4Project) ?? "Inbox"
    let body = a4Body(f)
    let priority = a4Value(f, "priority")
    return ToDo(id: "a4:" + file, listID: "a4:" + project, title: title.isEmpty ? String(name.dropLast(3)) : title, due: when, timed: when != nil && minutes != nil, done: done || (repeating && a4List(f, "complete_instances").contains(String(raw.prefix(10)))), notes: String(body.prefix(2000)),
                a4: A4Task(status: status.isEmpty ? "open" : status, priority: priority.isEmpty ? "normal" : priority, file: file, repeating: repeating))
}

// Each project note's side of life, by its name in lower case, as Obsidian's links ignore case.
func a4Spheres(_ folder: String) -> [String: String] {
    guard FileManager.default.fileExists(atPath: folder), let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }  // a missing folder would otherwise walk from the current one
    var found: [String: String] = [:], unclear: Set<String> = []
    for case let u as URL in walk where u.pathExtension == "md" {
        guard let f = (try? String(contentsOf: u, encoding: .utf8)).flatMap(a4Front) else { continue }
        let side = a4Value(f, "sphere"), name = u.deletingPathExtension().lastPathComponent.lowercased()
        if side.isEmpty { continue }
        if let was = found[name], was != side { unclear.insert(name) }  // two notes, one name: no guessing
        found[name] = side
    }
    return found.filter { !unclear.contains($0.key) }
}

// Every task in the folder. Project notes sit in the vault's Projects room unless told otherwise; `sides` false skips reading them when no calendar is picked.
func a4Scan(_ folder: String, now: Date, projects: String? = nil, sides: Bool = true) -> [ToDo] {
    guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    let room = projects ?? a4Vault(folder + "/x").map { $0 + "/04 Inner World/My Life/Projects" }
    let spheres = sides ? room.map(a4Spheres) ?? [:] : [:]
    return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.compactMap { u in
        guard var t = (try? String(contentsOf: u, encoding: .utf8)).flatMap({ a4Read($0, file: u.path, now: now) }) else { return nil }
        t.a4?.sphere = spheres[t.listID.dropFirst(3).lowercased()] ?? ""
        return t
    }
}

// The lines that change when `old` becomes `new` in the note `text`. Finishing is not here: that goes through A4's engine.
func a4Changes(old: ToDo, new: ToDo, text: String, now: Date) -> [(String, String?)] {
    guard let o = old.a4, let n = new.a4 else { return [] }
    var set: [(String, String?)] = []
    if old.due != new.due || old.timed != new.timed {
        if n.repeating, let f = a4Front(text) {
            // The day moves and whatever follows it stays, so a time from the rule isn't copied into the note.
            set.append(("scheduled", new.due.map { a4Day($0) + a4Value(f, "scheduled").dropFirst(10) } ?? ""))
            // A repeating task's Due moves by the same days, so its gap from the current day survives a move and its undo.
            let due = a4Value(f, "due")
            if let was = old.due, let now = new.due, let d = a4ParseDay(due), let by = cal.dateComponents([.day], from: cal.startOfDay(for: was), to: cal.startOfDay(for: now)).day {
                set.append(("due", a4Day(addDays(d, by)) + due.dropFirst(10)))
            }
        } else {
            // The same clock keeps what follows the day as written; only a new time is rebuilt.
            let front = a4Front(text), stored = front.map { a4Value($0, "due") } ?? ""
            let sameTime = old.timed == new.timed && (!new.timed || (old.due != nil && new.due != nil && sameClock(old.due!, on: new.due!) == new.due!))
            set.append(("due", new.due.map { sameTime ? a4Day($0) + stored.dropFirst(10) : a4When($0, timed: new.timed) } ?? ""))
            // What A4 does when a task gets a time: the half of the day follows it, and a first time rings at that time.
            if new.timed, let d = new.due {
                set.append(("planned_half", cal.component(.hour, from: d) < 13 ? "am" : "pm"))
                // shortcut: any reminders value we can't read as plainly empty is left alone, so such a note gets no ring; send the change through A4's engine if that bites.
                if n.ring, !old.timed, front.map({ ["", "[]"].contains(a4Value($0, "reminders")) && a4List($0, "reminders").isEmpty }) != false {
                    set.append(("reminders", "[{id: rem_\(Int(now.timeIntervalSince1970 * 1000)), type: relative, relatedTo: due, offset: PT0M}]"))
                }
            }
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

// MARK: A4 tasks with a time, kept as real events on the calendar John picked (John, 2026-11-02)
// Dateline does the copying, so it happens while Dateline is running. A repeating task stays a task. The link lives in Dateline, not the note.

struct A4Link: Codable, Equatable {
    var event: String
    var calendar: String
    var start: Date  // the last time task and event agreed, which tells which one moved
    var title: String
    var misses = 0  // reads in a row that should have held the event and didn't
    var dismissed = false  // the event was deleted: the task shows as a task and no event comes back
    var finished = false  // seen done, so its note leaving the folder is A4 filing it
    var away = false  // its note has left the folder; if it comes back, so does the link
    var pushed: Date? = nil  // where Dateline last sent the event, so a task changed again before they agree still counts as the task moving
    var zone = TimeZone.current.identifier  // a note's time has no zone: away from this one, task and event would seem to differ, so they wait
}

enum A4Step: Equatable {
    case create(ToDo, calendar: String)
    case moveEvent(Item, to: Date, title: String)
    case moveTask(ToDo, to: Date)
    case dropEvent(Item)
}

let a4CreateCap = 20  // new events per pass, so a surprise in the folder can't flood a calendar
let a4DropCap = 5  // events removed per pass: the one thing here that can't be undone

// What to do to bring tasks and events together. Pure: covered by --selftest. If both moved, the note wins.
// A move is recorded only once both sides agree, so one that fails to send is simply tried again.
// `seen`: whether this read could have held a calendar's events; one that couldn't says nothing about a missing event.
func a4Plan(tasks: [ToDo], links: [String: A4Link], events: [Item], calendarFor: (ToDo) -> String?, now: Date, seen: (String) -> Bool = { _ in true }) -> (links: [String: A4Link], steps: [A4Step]) {
    func wanted(_ t: ToDo) -> Bool { t.timed && t.a4?.repeating == false && !t.done }
    var links = links, steps: [A4Step] = []
    var byFile: [String: ToDo] = [:]
    for t in tasks { if let f = t.a4?.file { byFile[f] = t } }
    var newcomers = byFile.filter { links[$0.key] == nil && wanted($0.value) }
    var claimed = Set(links.values.map(\.event)), drops = 0
    for (file, was) in links.sorted(by: { $0.key < $1.key }) {
        var l = was
        guard let t = byFile[file] else {
            // A renamed note keeps its Due, so it shows up as one new task at the same time, in the same read.
            let same = newcomers.filter { $0.value.due == l.start }
            if !l.away, !l.finished, same.count == 1, let n = same.first?.key {
                links[file] = nil; links[n] = l; newcomers[n] = nil
            } else if l.start < addDays(now, -90) {
                links[file] = nil
            } else {
                l.away = true; links[file] = l  // filed or gone; the event stays, and the link in case the note comes back
            }
            continue
        }
        l.away = false
        if t.a4?.repeating == true { links[file] = nil; continue }
        if l.zone != TimeZone.current.identifier { links[file] = l; continue }
        let own = events.first { $0.id == l.event }
        let found = own ?? events.first { $0.title == l.title && $0.start == l.start && !claimed.contains($0.id) }  // moved to another calendar, it can have a new identifier
        if !t.timed {
            // Only after three reads, so a half-typed time saved by Obsidian doesn't cost the event. Unread calendar: wait.
            if l.dismissed || t.done { links[file] = nil; continue }
            if !seen(l.calendar) { links[file] = l; continue }
            l.misses += 1
            if l.misses < 3 || (found != nil && drops >= a4DropCap) { links[file] = l; continue }
            if let found { steps.append(.dropEvent(found)); drops += 1 }
            links[file] = nil; continue
        }
        if t.done { l.finished = true; links[file] = l; continue }
        l.finished = false
        if l.dismissed && own == nil { links[file] = l; continue }  // an undo or a late sync can bring it back
        l.dismissed = false
        guard let e = found else {
            if seen(l.calendar), l.start > addDays(now, -59) { l.misses += 1 }  // the read goes back 60 days
            if l.misses >= 3 { l.dismissed = true }
            links[file] = l
            continue
        }
        l.event = e.id; l.calendar = e.calendarID; l.misses = 0
        claimed.insert(e.id)
        if t.due == e.start { l.start = e.start; l.pushed = nil }
        if t.title == e.title { l.title = e.title }
        let taskMoved = t.due != e.start && (t.due != l.start || e.start == l.pushed), retitled = t.title != e.title && t.title != l.title
        if taskMoved { l.pushed = t.due }
        links[file] = l
        if taskMoved || retitled {
            steps.append(.moveEvent(e, to: taskMoved ? t.due! : e.start, title: retitled ? t.title : e.title))
        } else if t.due != e.start && !e.allDay {
            steps.append(.moveTask(t, to: e.start))
        }
    }
    var fresh: [A4Step] = []
    for t in newcomers.values.filter({ $0.due! >= now }).sorted(by: { $0.id < $1.id }) {
        guard let id = calendarFor(t), seen(id) else { continue }  // no calendar for its side of life, or not read yet: it stays a task
        // Already there (the links were lost): take it up rather than make a second one.
        if let e = events.first(where: { $0.title == t.title && $0.start == t.due && !claimed.contains($0.id) }) {
            links[t.a4!.file] = A4Link(event: e.id, calendar: e.calendarID, start: e.start, title: t.title); claimed.insert(e.id)
        } else { fresh.append(.create(t, calendar: id)) }
    }
    return (links, steps + fresh.prefix(a4CreateCap))
}

extension Store {
    // Shows once: on the calendar as its event, not also as a task block.
    func a4OnCalendar(_ t: ToDo) -> Bool {
        guard let f = t.a4?.file, let l = a4Links[f] else { return false }
        return !l.dismissed && !hidden.contains(l.calendar) && a4HasRead(l.calendar)  // only when the event can be on screen; else the task shows
    }

    func a4Pick(calendar: String?, work: Bool) {
        if work { a4WorkCalendar = calendar } else { a4Calendar = calendar }
        if access != .sample { UserDefaults.standard.set(calendar, forKey: work ? "a4WorkCalendar" : "a4Calendar") }
        reloadA4()
    }

    // The calendar a task goes on: its project's side of life picks. A task with no project, or one not marked either way, has none, so a work task can't land on the family calendar by guess.
    func a4Target(_ t: ToDo) -> String? {
        let id = t.a4?.sphere == "work" ? a4WorkCalendar : t.a4?.sphere == "personal" ? a4Calendar : nil
        return id.flatMap { id in calendars.first { $0.id == id && $0.writable } }?.id
    }

    // Reads the events off the main thread, then brings them and the tasks together.
    func a4Sync() {
        guard a4On, a4Calendar != nil || a4WorkCalendar != nil || !a4Links.isEmpty, access != .sample, a4CanSeeEvents, !a4Syncing, a4Busy == 0 else { return }
        a4Syncing = true
        let now = Date(), from = now.addingTimeInterval(-60 * 86400), to = now.addingTimeInterval(2 * 365 * 86400), read = canRead
        Task {
            let mac = read ? await source.eventsInBackground(from: from, to: to).map(decorated) : []
            a4Syncing = false
            a4Apply(events: mac + accEvents(from: from, to: to), now: Date())
        }
    }

    func a4Apply(events: [Item], now: Date) {
        if trialOver { return }  // paused, not half done: a note moved while the event can't follow would leave them apart
        let plan = a4Plan(tasks: todos.filter { $0.a4 != nil }, links: a4Links, events: events, calendarFor: a4Target, now: now, seen: a4HasRead)
        var links = plan.links, failure: Failure?
        for step in plan.steps {
            switch step {
            case let .create(t, calendar):
                var p = Parsed(start: t.due!, end: t.due!.addingTimeInterval(3600))
                // No alert of its own: A4's reminders job rings for the task.
                p.title = t.title; p.notes = (try? String(contentsOfFile: t.a4!.file, encoding: .utf8)).flatMap(a4Front).map(a4Body) ?? t.notes
                switch add(p, calendarID: calendar) {
                // shortcut: on Google or iCloud a send that fails later reads as a deleted event, so the task stays a task; wait for the send if that bites.
                case .success(let e): links[t.a4!.file] = A4Link(event: e.id, calendar: e.calendarID, start: t.due!, title: t.title)
                case .failure(let f): failure = f
                }
            case let .moveEvent(e, to, title):
                var n = e; n.start = to; n.end = to.addingTimeInterval(e.end.timeIntervalSince(e.start)); n.title = title
                if let f = update(n) { failure = f }
            case let .moveTask(t, to):
                var n = t; n.due = to
                if let f = updateA4(n, old: t) { failure = f } else { links[t.a4!.file]?.start = to }  // the note is written, so they agree now
            case .dropEvent(let e):
                if let f = delete(e) { failure = f }
            }
        }
        if links != a4Links { a4Links = links; saveA4Links() }
        // Once per message: a failed step is tried again at every pass.
        if failure?.message != a4LastError { a4LastError = failure?.message; if let failure { onError?("A4 tasks on the calendar: " + failure.message) } }
    }
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
        let n = a4Fetch, on = a4On, folder = a4Folder, sides = a4Calendar != nil || a4WorkCalendar != nil
        Task.detached(priority: .utility) {
            let found = on ? a4Scan(folder, now: Date(), sides: sides) : []
            await MainActor.run { if n == self.a4Fetch, self.a4Busy == 0 { self.showA4(found); if !found.isEmpty { self.a4Sync() } } }
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
        if access == .sample {
            guard let i = todos.firstIndex(where: { $0.id == t.id }) else { return Failure("That task is gone.") }
            todos[i] = t; return nil
        }
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
func a4Check(_ folder: String, projects: String? = nil) -> Int32 {
    if a4Vault(folder + "/x") != nil { print("refused: that folder is in an Obsidian vault; this check changes the files it is given, so give it a copy"); return 2 }
    let now = Date()
    var fails = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL:", what) } }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".md") }.sorted() ?? []
    let tasks = a4Scan(folder, now: now, projects: projects)
    print("work: \(tasks.filter { $0.a4?.sphere == "work" }.count), personal: \(tasks.filter { $0.a4?.sphere == "personal" }.count), neither: \(tasks.filter { $0.a4?.sphere == "" }.count)")
    print("notes: \(files.count), shown as tasks: \(tasks.count), not done: \(tasks.filter { !$0.done }.count), with a date: \(tasks.filter { $0.due != nil }.count), repeating: \(tasks.filter { $0.a4?.repeating == true }.count), projects: \(Set(tasks.map(\.listID)).count)")
    let becoming = a4Plan(tasks: tasks, links: [:], events: [], calendarFor: { $0.a4?.sphere.isEmpty == false ? $0.a4?.sphere : nil }, now: now).steps.compactMap { if case .create(let t, _) = $0 { return t.title } else { return nil } }
    print("would become events: \(becoming)")
    for t in tasks {
        guard let a = t.a4, let text = try? String(contentsOfFile: a.file, encoding: .utf8) else { expect(false, "reads back: \(t.id)"); continue }
        expect(!t.title.isEmpty, "has a title: \(t.id)")
        var n = t; n.due = addDays(t.timed ? t.due! : cal.startOfDay(for: now), 3); n.a4?.priority = a.priority == "high" ? "low" : "high"; n.a4?.status = a.status == "blocked" ? "open" : "blocked"
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
        expect(back.due == n.due && back.timed == t.timed && back.a4?.priority == n.a4?.priority && back.a4?.status == n.a4?.status, "the change reads back: \(t.id)")
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
    expect(t?.title == "Fix the gate" && t?.listID == "a4:Home" && t?.timed == true && t?.notes == "Fix it.\n---\nmore" && t?.done == false, "a4: reads a note")
    expect(t?.due == cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 30)) && isOverdue(t!, now: now) && taskRowDay(t!, now: now) == cal.startOfDay(for: now), "a4: an overdue task shows on today")
    expect(a4Read("no properties", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: open\n---\n", file: "/v/x.md", now: now) == nil, "a4: a note that isn't a task is skipped")
    expect(a4Read("---\nstatus: someday\ntags: [task]\n---\n", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: open\ntags:\n  - task\n  - archived\n---\n", file: "/v/x.md", now: now) == nil, "a4: Someday and archived are skipped")
    expect(a4Read("---\nstatus: done\ncompletedDate: 2026-10-01\ntags: [task]\n---\n", file: "/v/x.md", now: now) == nil && a4Read("---\nstatus: done\ncompletedDate: 2026-10-30\ntags: [task]\n---\n", file: "/v/x.md", now: now)?.done == true, "a4: done tasks stay a week")
    let rep = a4Read("---\nstatus: open\ndue: 2026-10-25\nscheduled: 2026-10-31\nrecurrence: DTSTART:20260904;FREQ=DAILY\ntags: [task]\n---\n", file: "/v/r.md", now: now)
    expect(rep?.a4?.repeating == true && rep?.due == cal.startOfDay(for: now), "a4: a repeating task sits on its current occurrence")
    expect(a4Edit(note, [("due", "2026-11-02T09:30"), ("completedDate", "2026-10-31")]) == note.replacingOccurrences(of: "due: 2026-10-25T09:30", with: "due: 2026-11-02T09:30").replacingOccurrences(of: "  - task\n---", with: "  - task\ncompletedDate: 2026-10-31\n---"), "a4: an edit touches only its lines")
    expect(a4Edit("---\ndue: 2026-10-25\ncompletedDate: 2026-10-30\n---\n---\n", [("due", ""), ("completedDate", nil)]) == "---\ndue:\n---\n---\n", "a4: empties Due, removes the rest, leaves the text alone")
    expect(a4Edit("no block", [("due", "x")]) == nil, "a4: never edits a note with no properties")
    var moved = t!; moved.due = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 30))
    expect(a4Changes(old: t!, new: moved, text: note, now: now).first?.1 == "2026-11-02T09:30", "a4: moving the day keeps the clock time")
    var r2 = rep!; r2.due = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))
    let shifted = a4Changes(old: rep!, new: r2, text: "---\ndue: 2026-10-25\nscheduled: 2026-10-31\n---\n", now: now)
    expect(shifted[0].0 == "scheduled" && shifted[0].1 == "2026-11-02" && shifted[1].0 == "due" && shifted[1].1 == "2026-10-27", "a4: moving a repeating task keeps the gap to its Due")
    expect(a4Read("---\nstatus: open\nscheduled: 2026-10-31\nrecurrence: FREQ=DAILY\ncomplete_instances:\n  - 2026-10-31\ntags: [task]\n---\n", file: "/v/r.md", now: now)?.done == true, "a4: a repeating day already ticked shows ticked")
    var cleared = t!; cleared.due = nil
    expect(a4Edit("---\ndue: 2026-10-25\nplanned_day: 2026-10-25\nplanned_half: am\n---\n", a4Changes(old: t!, new: cleared, text: note, now: now))?.contains("planned_") == false, "a4: clearing Due takes the task off A4's planned day")
    var reopened = a4Read("---\nstatus: done\ncompletedDate: 2026-10-30\ntags: [task]\n---\n", file: "/v/x.md", now: now)!; let was = reopened; reopened.a4?.status = "open"; reopened.done = false
    expect(a4Changes(old: was, new: reopened, text: "", now: now).contains { $0.0 == "completedDate" && $0.1 == nil }, "a4: reopening removes the done day")
    // A task with a clock time sits in the grid at that time; the time is read the way A4 reads it.
    func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
    func read(_ props: String) -> ToDo? { a4Read("---\nstatus: open\n\(props)\ntags: [task]\n---\n", file: "/v/a.md", now: now) }
    let appt = read("due: 2026-11-03T11:00")!
    expect(appt.timed && appt.due == at(3, 11, 0) && taskRowDay(appt, now: now) == nil, "a4: a task with a time goes in the grid, not the Tasks row")
    expect(read("due: \"2026-11-03T11:00:00.000-06:00\"")?.due == at(3, 11, 0), "a4: a quoted time with seconds reads as written")
    let dayOnly = read("due: 2026-11-03")!
    expect(!dayOnly.timed && taskRowDay(dayOnly, now: now) == at(3, 0, 0), "a4: a task with only a day stays in the Tasks row")
    expect(read("due: 2026-11-03T25:00")?.timed == false && read("due: 2026-11-03T25:00")?.due == at(3, 0, 0), "a4: a broken time counts as no time")
    expect(read("due: 2026-11-03T-1:00")?.timed == false, "a4: a time that isn't digits counts as no time")
    expect(read("scheduled: 2026-11-03\nrecurrence: DTSTART:20261012T090000Z;FREQ=DAILY")?.due == at(3, 9, 0), "a4: a repeating task with no time on its day takes its rule's")
    expect(read("scheduled: 2026-11-03T14:30\nrecurrence: DTSTART:20261012T090000Z;FREQ=DAILY")?.due == at(3, 14, 30), "a4: a repeating task's own time beats its rule's")
    expect(read("scheduled: 2026-11-03\nrecurrence: DTSTART:20261012T000000Z;FREQ=DAILY")?.timed == false, "a4: a rule at midnight means no time")
    var slot = appt; slot.due = at(4, 14, 15)
    expect(a4Changes(old: appt, new: slot, text: "", now: now).first?.1 == "2026-11-04T14:15", "a4: a new day and time are written to Due")
    var timedNow = dayOnly; timedNow.due = at(3, 9, 0); timedNow.timed = true
    expect(a4Changes(old: dayOnly, new: timedNow, text: "", now: now).first?.1 == "2026-11-03T09:00", "a4: adding a time writes it")
    let midnight = read("due: 2026-11-03T00:00")!; var noTime = midnight; noTime.timed = false
    expect(midnight.timed && a4Changes(old: midnight, new: noTime, text: "", now: now).first?.1 == "2026-11-03", "a4: taking off a midnight time is a change")
    let repText = "---\nstatus: open\ndue: 2026-11-01\nscheduled: 2026-11-03T11:00\nrecurrence: FREQ=DAILY\ntags: [task]\n---\n"
    let repTimed = a4Read(repText, file: "/v/r.md", now: now)!; var repMoved = repTimed; repMoved.due = at(4, 11, 0)
    let repSet = a4Changes(old: repTimed, new: repMoved, text: repText, now: now)
    expect(repSet[0].1 == "2026-11-04T11:00" && repSet[1].1 == "2026-11-02", "a4: a repeating task moved a day keeps its time and the gap to its Due")
    expect(a4Edit(repText, repSet).flatMap { a4Read($0, file: "/v/r.md", now: now) }?.due == at(4, 11, 0), "a4: a moved time reads back")
    let ruleText = "---\nstatus: open\nscheduled: 2026-11-03\nrecurrence: DTSTART:20261012T090000Z;FREQ=DAILY\ntags: [task]\n---\n"
    let ruleTask = a4Read(ruleText, file: "/v/r.md", now: now)!; var ruleMoved = ruleTask; ruleMoved.due = at(4, 9, 0)
    expect(a4Changes(old: ruleTask, new: ruleMoved, text: ruleText, now: now).first?.1 == "2026-11-04", "a4: a time from the rule isn't copied into the note")
    // A first time rings, as in A4; the half of the day follows the time.
    let dayText = "---\nstatus: open\ndue: 2026-11-03\nplanned_half: am\ntags: [task]\n---\n"
    var pm = dayOnly; pm.due = at(3, 14, 15); pm.timed = true; pm.a4?.ring = true
    let pmNote = a4Edit(dayText, a4Changes(old: dayOnly, new: pm, text: dayText, now: now)) ?? ""
    expect(pmNote.contains("due: 2026-11-03T14:15\n") && pmNote.contains("planned_half: pm\n") && pmNote.contains("relatedTo: due, offset: PT0M}]\n") && a4Read(pmNote, file: "/v/a.md", now: now) != nil, "a4: a first time rings and picks the half of the day")
    let hasBell = "---\nstatus: open\ndue: 2026-11-03\nreminders:\n  - id: rem_1\n    type: absolute\ntags: [task]\n---\n"
    expect(!a4Changes(old: dayOnly, new: pm, text: hasBell, now: now).contains { $0.0 == "reminders" }, "a4: a reminder already there is left alone")
    var undone = pm; undone.a4?.ring = false
    expect(!a4Changes(old: dayOnly, new: undone, text: dayText, now: now).contains { $0.0 == "reminders" }, "a4: an undo that brings a time back adds no ring")
    expect(!a4Changes(old: dayOnly, new: pm, text: "---\ndue: 2026-11-03\nreminders: [\n  {id: x}\n]\n---\n", now: now).contains { $0.0 == "reminders" }, "a4: a reminder list over several lines is left alone")
    let secs = read("due: 2026-11-03T11:00:00.000-06:00")!; var secsMoved = secs; secsMoved.due = at(4, 11, 0)
    expect(a4Changes(old: secs, new: secsMoved, text: "---\ndue: 2026-11-03T11:00:00.000-06:00\n---\n", now: now).first?.1 == "2026-11-04T11:00:00.000-06:00", "a4: a move keeps the time as written")
    var later = appt; later.due = at(3, 15, 0)
    expect(!a4Changes(old: appt, new: later, text: "---\ndue: 2026-11-03T11:00\n---\n", now: now).contains { $0.0 == "reminders" }, "a4: changing a time adds no reminder")
    expect(sameClock(at(1, 11, 30), on: at(5, 0, 0)) == at(5, 11, 30), "the time stays when the day changes")
    // A4 tasks with a time, as real events.
    func task(_ file: String, _ due: Date?, timed: Bool = true, done: Bool = false, repeating: Bool = false, title: String = "Vet") -> ToDo {
        ToDo(id: "a4:" + file, listID: "a4:H", title: title, due: due, timed: timed, done: done, a4: A4Task(file: file, repeating: repeating))
    }
    func ev(_ start: Date, id: String = "e1", title: String = "Vet") -> Item { Item(id: id, calendarID: "c", title: title, start: start, end: start.addingTimeInterval(1800), allDay: false, place: "", notes: "", showAs: .busy) }
    let dueAt = at(3, 11, 0), link = A4Link(event: "e1", calendar: "c", start: dueAt, title: "Vet")
    func plan(_ ts: [ToDo], _ ls: [String: A4Link] = [:], _ es: [Item] = [], calendar: String? = "c") -> (links: [String: A4Link], steps: [A4Step]) { a4Plan(tasks: ts, links: ls, events: es, calendarFor: { _ in calendar }, now: now) }
    let vetTask = task("/a", dueAt)
    expect(plan([vetTask]).steps == [.create(vetTask, calendar: "c")], "a4 link: a new task with a time makes an event")
    expect(plan([vetTask], calendar: nil).steps.isEmpty, "a4 link: no calendar picked, no event")
    expect(plan([task("/a", at(3, 11, 0), done: true), task("/b", at(3, 11, 0), repeating: true), task("/c", at(3, 0, 0), timed: false), task("/d", cal.date(byAdding: .day, value: -1, to: now)!)]).steps.isEmpty, "a4 link: done, repeating, no time and past tasks make none")
    expect(plan((0..<30).map { task("/\($0)", dueAt) }).steps.count == a4CreateCap, "a4 link: new events per pass are capped")
    expect(plan([vetTask], ["/a": link], [ev(dueAt)]).steps.isEmpty, "a4 link: nothing moved, nothing to do")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(dueAt)]).steps == [.moveEvent(ev(dueAt), to: at(4, 9, 0), title: "Vet")], "a4 link: the task moved, so the event follows")
    expect(plan([vetTask], ["/a": link], [ev(at(4, 9, 0))]).steps == [.moveTask(vetTask, to: at(4, 9, 0))], "a4 link: the event moved, so the task follows")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(at(5, 9, 0))]).steps == [.moveEvent(ev(at(5, 9, 0)), to: at(4, 9, 0), title: "Vet")], "a4 link: both moved, the note wins")
    expect(plan([task("/a", dueAt, title: "Vet visit")], ["/a": link], [ev(dueAt)]).steps == [.moveEvent(ev(dueAt), to: dueAt, title: "Vet visit")], "a4 link: a new title reaches the event")
    expect(plan([vetTask], ["/a": link], [ev(dueAt, title: "My name")]).steps.isEmpty, "a4 link: a new title on the event stays")
    let untimed = plan([task("/a", at(3, 0, 0), timed: false)], ["/a": link], [ev(dueAt)])
    expect(untimed.steps.isEmpty && untimed.links["/a"]?.misses == 1, "a4 link: a time gone for one read leaves the event, in case it was half typed")
    let threeReads = plan([task("/a", at(3, 0, 0), timed: false)], ["/a": { var m = link; m.misses = 2; return m }()], [ev(dueAt)])
    expect(threeReads.steps == [.dropEvent(ev(dueAt))] && threeReads.links.isEmpty, "a4 link: the time stays off, the event goes")
    let manyOff = Dictionary(uniqueKeysWithValues: (0..<9).map { ("/\($0)", A4Link(event: "e\($0)", calendar: "c", start: dueAt, title: "Vet", misses: 2)) })
    expect(plan((0..<9).map { task("/\($0)", at(3, 0, 0), timed: false) }, manyOff, (0..<9).map { ev(dueAt, id: "e\($0)") }).steps.count == a4DropCap, "a4 link: events removed per pass are capped")
    let pushedOnce = plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(dueAt)]).links
    expect(plan([vetTask], pushedOnce, [ev(at(4, 9, 0))]).steps == [.moveEvent(ev(at(4, 9, 0)), to: dueAt, title: "Vet")], "a4 link: a task changed back before they agree isn't overwritten")
    expect(plan([task("/a", at(4, 9, 0))], pushedOnce, [ev(dueAt)]).steps == [.moveEvent(ev(dueAt), to: at(4, 9, 0), title: "Vet")], "a4 link: a send that failed is tried again, the note unchanged")
    expect(plan([vetTask], [:], [ev(dueAt)]).steps.isEmpty && plan([vetTask], [:], [ev(dueAt)]).links["/a"]?.event == "e1", "a4 link: an event already there is taken up, not made twice")
    expect(plan([vetTask, task("/b", dueAt)], ["/b": link], [ev(dueAt)]).steps == [.create(vetTask, calendar: "c")], "a4 link: an event another task owns isn't taken")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": { var m = link; m.zone = "Asia/Tokyo"; return m }()], [ev(dueAt)]).steps.isEmpty, "a4 link: away from the note's time zone nothing moves")
    expect(plan([vetTask], ["/a": { var m = link; m.dismissed = true; return m }()], [ev(dueAt)]).links["/a"]?.dismissed == false, "a4 link: an event that comes back is linked again")
    expect(a4Plan(tasks: [vetTask], links: [:], events: [], calendarFor: { _ in "c" }, now: now, seen: { _ in false }).steps.isEmpty, "a4 link: no event made on a calendar not read yet")
    expect(plan([task("/a", dueAt, done: true)], ["/a": link], [ev(at(5, 9, 0))]).steps.isEmpty, "a4 link: a finished task's event is left alone")
    let filed = plan([], ["/a": link], [ev(dueAt)])
    expect(filed.steps.isEmpty && filed.links["/a"]?.away == true, "a4 link: a filed task leaves its event in place")
    expect(plan([vetTask], filed.links, [ev(dueAt)]).steps.isEmpty && plan([vetTask], filed.links, [ev(dueAt)]).links["/a"]?.away == false, "a4 link: a note that comes back finds its event, not a second one")
    let finishedLink = plan([task("/a", dueAt, done: true)], ["/a": link], [ev(dueAt)]).links
    expect(plan([task("/new", dueAt, title: "Dentist")], finishedLink, [ev(dueAt)]).steps.count == 1 && plan([task("/new", dueAt, title: "Dentist")], finishedLink, [ev(dueAt)]).links["/new"] == nil, "a4 link: a new task at a finished task's time gets its own event")
    expect(plan([task("/x", dueAt), task("/y", dueAt)], ["/a": link], [ev(dueAt)]).links["/a"] != nil, "a4 link: two new tasks at that time aren't taken for a rename")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(dueAt)]).links["/a"]?.start == dueAt, "a4 link: a move isn't recorded until the event has it, so a failed send is tried again")
    expect(plan([task("/a", at(4, 9, 0))], ["/a": link], [ev(at(4, 9, 0))]).links["/a"]?.start == at(4, 9, 0), "a4 link: agreeing records the time")
    expect(plan([task("/a", dueAt, title: "Vet visit")], ["/a": link], [ev(at(5, 9, 0))]).steps == [.moveEvent(ev(at(5, 9, 0)), to: at(5, 9, 0), title: "Vet visit")], "a4 link: a new title doesn't snap a moved event back")
    expect(a4Plan(tasks: [vetTask], links: ["/a": link], events: [], calendarFor: { _ in "c" }, now: now, seen: { _ in false }).links["/a"]?.misses == 0, "a4 link: a calendar not read yet counts no miss")
    let renamed = plan([task("/new", dueAt)], ["/a": link], [ev(dueAt)])
    expect(renamed.steps.isEmpty && renamed.links["/new"] == link, "a4 link: a renamed note keeps its event")
    let otherCal = plan([vetTask], ["/a": link], [ev(dueAt, id: "e2")])
    expect(otherCal.steps.isEmpty && otherCal.links["/a"]?.event == "e2", "a4 link: an event moved to another calendar stays linked")
    var left = ["/a": link]
    for _ in 0..<2 { left = plan([vetTask], left).links }
    expect(left["/a"]?.dismissed == false && plan([vetTask], left).links["/a"]?.dismissed == true, "a4 link: a missing event counts as deleted after three reads")
    var gone = link; gone.dismissed = true
    expect(plan([vetTask], ["/a": gone]).steps.isEmpty, "a4 link: a deleted event doesn't come back")
    expect(plan([vetTask], ["/a": { var m = link; m.misses = 2; return m }()], [ev(dueAt)]).links["/a"]?.misses == 0, "a4 link: finding it again resets the count")
    // The project's note says work or personal.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("a4-sphere-\(UUID().uuidString)").path
    let fm = FileManager.default, taskDir = root + "/Tasks", projectDir = root + "/Projects/Deep"
    try? fm.createDirectory(atPath: taskDir, withIntermediateDirectories: true); try? fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    expect(a4Spheres(root + "/not there").isEmpty && a4Spheres("").isEmpty, "a4 link: no projects folder, nothing is read")
    try? "---\ntype: project\nsphere: work\n---\n".write(toFile: projectDir + "/client.md", atomically: true, encoding: .utf8)
    try? "---\nsphere: \"personal\"\n---\n".write(toFile: projectDir + "/Home.md", atomically: true, encoding: .utf8)
    try? "---\ntype: project\n---\n\nsphere: work in the text\n".write(toFile: projectDir + "/Unmarked.md", atomically: true, encoding: .utf8)
    try? "---\nsphere: work\n---\n".write(toFile: projectDir + "/Both.md", atomically: true, encoding: .utf8)
    try? "---\nsphere: personal\n---\n".write(toFile: root + "/Projects/Both.md", atomically: true, encoding: .utf8)
    for (name, project) in [("a", "Client"), ("b", "Home"), ("c", "Unmarked"), ("d", "Nowhere"), ("e", "Both")] {
        try? "---\nstatus: open\nprojects:\n  - \"[[x/\(project)]]\"\ntags:\n  - task\n---\n".write(toFile: taskDir + "/\(name).md", atomically: true, encoding: .utf8)
    }
    let sides = Dictionary(uniqueKeysWithValues: a4Scan(taskDir, now: now, projects: root + "/Projects").map { (($0.a4!.file as NSString).lastPathComponent, $0.a4!.sphere) })
    try? fm.removeItem(atPath: root)
    expect(sides == ["a.md": "work", "b.md": "personal", "c.md": "", "d.md": "", "e.md": ""], "a4 link: a task takes its project's side of life")
    expect(a4Project("[[a/b/Home.md|H]]") == "Home" && a4Project("Plain") == "Plain", "a4: project names")
    expect(a4Stamp(now).hasPrefix("2026-10-31T09:00:00.000") && a4Stamp(now).count == 29, "a4: A4's time stamp")
    MainActor.assumeIsolated {
        // The calendar follows the project, and an unmarked task goes nowhere.
        let routed = Store(sample: true), writable = routed.calendars.filter(\.writable)
        routed.a4WorkCalendar = writable[0].id; routed.a4Calendar = writable[1].id
        var w = task("/w", at(3, 11, 0)); w.a4?.sphere = "work"
        var h = task("/h", at(3, 11, 0)); h.a4?.sphere = "personal"
        expect(routed.a4Target(w) == writable[0].id && routed.a4Target(h) == writable[1].id && routed.a4Target(task("/n", at(3, 11, 0))) == nil, "a4 link: work and personal tasks go on their own calendars, others on none")
        routed.a4WorkCalendar = nil
        expect(routed.a4Target(w) == nil, "a4 link: no work calendar picked, a work task stays a task")
        // The whole round on sample calendars: event made, shown once, each side moves the other.
        let linked = AppState(store: Store(sample: true), today: now)
        let ls = linked.store, vet = ls.todos.first { $0.title == "Vet appointment" }!, target = ls.calendars.first { $0.writable && !ls.hidden.contains($0.id) }!
        ls.a4Calendar = target.id
        @MainActor func events() -> [Item] { ls.between(addDays(now, -60), addDays(now, 400)) }
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        @MainActor func theEvent() -> Item? { events().first { $0.title == "Vet appointment" } }
        expect(theEvent()?.start == vet.due && theEvent()?.calendarID == target.id && ls.a4OnCalendar(vet), "a4 link: the event is made and the task shows once")
        let firstCount = events().count
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        expect(events().count == firstCount, "a4 link: a second pass makes no second event")
        var pushed = theEvent()!; pushed.start = addDays(pushed.start, 1); pushed.end = addDays(pushed.end, 1)
        ls.update(pushed)
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        expect(ls.todos.first { $0.id == vet.id }?.due == pushed.start, "a4 link: moving the event moves the task")
        var back = ls.todos.first { $0.id == vet.id }!; back.due = vet.due
        ls.todos = ls.todos.map { $0.id == back.id ? back : $0 }
        ls.a4Apply(events: events(), now: addDays(vet.due!, -1))
        expect(theEvent()?.start == vet.due, "a4 link: moving the task moves the event")
        let d = UserDefaults.standard, before = (d.object(forKey: "a4On") as? Bool, d.string(forKey: "a4Folder"))
        let a = AppState(store: Store(sample: true), today: now)
        a.store.a4Set(on: false, folder: "/selftest")
        expect((d.object(forKey: "a4On") as? Bool, d.string(forKey: "a4Folder")) == before, "a4: tests never change the saved A4 settings")
        a.store.use(CalSet(name: "W", calendars: [], lists: []))
        expect(a.store.lists.filter { $0.account == a4Account }.allSatisfy { !a.store.hiddenLists.contains($0.id) }, "a4: a saved set never hides A4 projects")
        let s = a.store.todos.first { $0.a4 != nil && $0.due != nil }!
        a.drop(taskID: s.id, at: at(4, 14, 15))
        expect(a.store.todos.first { $0.id == s.id }.map { $0.timed && $0.due == at(4, 14, 15) } == true, "a4: a task dropped on the grid takes that time")
        if let i = a.store.todos.firstIndex(where: { $0.id == s.id }) { a.store.todos[i].a4?.repeating = true }
        a.drop(taskID: s.id, at: at(5, 9, 0))
        expect(a.store.todos.first { $0.id == s.id }?.due == at(5, 14, 15), "a4: a repeating task dropped on the grid takes the day and keeps its time")
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
                    Button { app.panels.openTaskID = nil } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.accessibilityLabel("Close").buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 8)
                HStack(alignment: .top, spacing: 8) {
                    TaskCircle(done: task.done, color: a4Color, size: 16) { let was = task.done; task.done.toggle(); task.a4?.status = task.done ? "done" : "open"; app.saveTask(task); if info.repeating { task.done = was; task.a4?.status = info.status } }.padding(.top, 4)
                    Text(task.title).font(.ui(17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                row("Project") { HStack(spacing: 8) { Circle().fill(a4Color).frame(width: 8, height: 8); Text((store.taskList(task.listID)?.title ?? "").replacingOccurrences(of: "A4: ", with: "")) } }
                row("Due") {
                    if let d = task.due {
                        DatePicker("", selection: Binding(get: { d }, set: { v in
                            task.due = task.timed ? sameClock(d, on: v) : cal.startOfDay(for: v); save()
                        }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        if info.repeating {
                            if task.timed { Text(timeText(d)) }
                        } else if task.timed {
                            DatePicker("", selection: Binding(get: { d }, set: { task.due = $0; save() }), displayedComponents: .hourAndMinute).labelsHidden()
                            Button { task.timed = false; task.due = cal.startOfDay(for: d); save() } label: { Image(systemName: "clock.badge.xmark") }.accessibilityLabel("Take the time off").buttonStyle(.plain).foregroundStyle(Palette.text3).help("Keep the day, take the time off")
                        } else {
                            Button("add time") { task.timed = true; task.a4?.ring = true; task.due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d); save() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }
                        if !info.repeating { Button { task.due = nil; task.timed = false; save() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear due").buttonStyle(.plain).foregroundStyle(Palette.text3).help("Clear the Due property") }
                    } else {
                        Button("Add a date") { task.due = cal.startOfDay(for: app.now); save() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    }
                }
                row("Status") {
                    Menu {
                        ForEach(A4Task.statuses, id: \.0) { s in Button(s.1) { setStatus(s.0) } }
                    } label: { Text(A4Task.statuses.first { $0.0 == info.status }?.1 ?? info.status) }.menuStyle(.borderlessButton).fixedSize()
                }
                row("Priority") {
                    Menu {
                        ForEach(A4Task.priorities, id: \.self) { p in Button(p.capitalized) { task.a4?.priority = p; save() } }
                    } label: { Text(info.priority.capitalized) }.menuStyle(.borderlessButton).fixedSize()
                }
                Text("NOTE").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 16).padding(.bottom, 4)
                Text(task.notes.isEmpty ? "No text in this note." : task.notes).font(.ui(13)).foregroundStyle(task.notes.isEmpty ? Palette.text3 : Palette.text2)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                Button("Open in Obsidian") { openInObsidian(info.file) }.padding(.top, 12)
                Text("Saved in your A4 vault, so Obsidian sees each change. Change the title, the note's text and a repeating task's time in Obsidian.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            .padding(16)
        }
        .background(Palette.win)
        .onChange(of: store.todos) { _, list in
            // Changed in Obsidian, or by a tick in the calendar, while open.
            if let fresh = list.first(where: { $0.id == task.id }), fresh != task { task = fresh }
        }
    }

    // A refused save puts the panel back to what the note says, so a later edit can't carry the refused change along.
    func save() { app.saveTask(task); if let fresh = store.todos.first(where: { $0.id == task.id }), fresh != task { task = fresh } }

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
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 52, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 8)
    }
}

struct A4Settings: View {
    @ObservedObject var store: Store
    func calendarPicker(_ label: String, work: Bool, selection: String?) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: { store.a4Pick(calendar: $0, work: work) })) {
            Text("No calendar").tag(String?.none)
            ForEach(store.calendars.filter(\.writable)) { c in Text(c.title + "  (" + c.account + ")").tag(String?.some(c.id)) }
        }.fixedSize()
    }
    var body: some View {
        let count = store.todos.filter { $0.a4 != nil && !$0.done }.count
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show A4 tasks on the calendar", isOn: Binding(get: { store.a4On }, set: { store.a4Set(on: $0) })).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 8) {
                Text("Tasks folder").font(.ui(13, weight: .semibold))
                HStack(spacing: 8) {
                    Text((store.a4Folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(store.a4Folder)
                    Button("Choose\u{2026}") {
                        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false; o.directoryURL = URL(fileURLWithPath: store.a4Folder)
                        if o.runModal() == .OK, let u = o.url { store.a4Set(folder: u.path) }
                    }
                }
                calendarPicker("Work tasks go on", work: true, selection: store.a4WorkCalendar).padding(.top, 8)
                calendarPicker("Personal tasks go on", work: false, selection: store.a4Calendar)
                Text("Each A4 task with a date and time becomes a real event, an hour long, on the calendar for its project: work or personal. Move the event, even to another calendar, and the task's Due follows; change the task and the event follows. Repeating tasks, and tasks whose project isn't marked work or personal, stay tasks. It happens while Dateline is running.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                Text(FileManager.default.fileExists(atPath: store.a4Folder) || store.access == .sample
                     ? "Found \(count) tasks that aren't done. Tasks with a Due property show on the calendar; the rest sit under No date, by project."
                     : "That folder isn't on this Mac.")
                    .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
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
        func t(_ list: String, _ title: String, _ day: Int?, hour: Int? = nil, status: String = "open", priority: String = "normal", notes: String = "") {
            todos.append(ToDo(id: "a4-\(title)", listID: list, title: title, due: day.map { d in cal.date(byAdding: .hour, value: hour ?? 0, to: addDays(mon, d))! }, timed: hour != nil, notes: notes, a4: A4Task(status: status, priority: priority, file: "/sample/" + title + ".md", sphere: list == "a4-launch" ? "work" : "personal")))
        }
        t("a4-launch", "Choose a license for Dateline", 0, priority: "high", notes: "Compare MIT and GPL, then add the file to the repo.")
        t("a4-home", "Pay the water bill", -2, status: "in-progress")
        t("a4-reading", "Answer buyer questions", 1)
        t("a4-launch", "Bring the GitHub page up to date", 3)
        t("a4-home", "Vet appointment", 1, hour: 11)
        for s in ["Sign the app", "Check the code is safe to share"] { t("a4-launch", s, nil) }
        for s in ["Fix the gate latch", "Sort the garage", "Renew the car papers"] { t("a4-home", s, nil) }
    }
}
