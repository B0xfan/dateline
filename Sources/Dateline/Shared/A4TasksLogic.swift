// A4 tasks in Dateline: task notes in John's vault shown beside Apple Reminders (approved design, 2026-10-31).
// A change goes into the note itself, touching only the lines it changes. Finishing a task goes through A4's own task engine in the running Obsidian, because only that files it in the Archive and moves a repeating task on.
// Sample mode (every test and picture) keeps made-up tasks in memory and never reads the vault.
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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
    f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx"  // the app's zone, so the cloud self-test (UTC) agrees with the Mac
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
    #if os(macOS)
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.standardOutput = pipe; p.standardError = pipe
    guard (try? p.run()) != nil else { return nil }
    let killer = DispatchWorkItem { p.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return p.terminationReason == .uncaughtSignal ? nil : (p.terminationStatus, String(decoding: data, as: UTF8.self))
    #else
    return nil  // the iPhone cannot start programs; A4 tasks are a Mac feature
    #endif
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

