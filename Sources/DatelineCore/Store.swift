// Everything the window reads: the calendars and events from a calendar source (CalendarSource.swift), plus Dateline's own extras, sets and accounts.
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct CalInfo: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var account: String
    public var color: Color
    public var writable: Bool
    public init(id: String, title: String, account: String, color: Color, writable: Bool) { self.id = id; self.title = title; self.account = account; self.color = color; self.writable = writable }
}

public struct Item: Identifiable, Equatable {
    public var id: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var place: String
    public var notes: String
    public var showAs: ShowAs
    // Kept by Dateline on this Mac only (Phase 3), never written to the calendar: works on invites from others too.
    public var emoji = ""
    public var color: Int? = nil  // a place in Palette.tags; nil = the calendar's color
    public var tags: [String] = []
    public var rich: Data? = nil  // the notes with their formatting (RTF); the calendar gets the plain text
    public var geo: Geo? = nil  // where the place is on the map (Phase 5); saved in the calendar with the place, so the phone sees it too
    // Phase 5 travel, kept by Dateline on this Mac: no drive time, the leave alert (nil = the Settings default), where the drive starts.
    public var noTravel = false, leave: Bool? = nil, from: From = .here
    public var alerts: [Date] = []  // when the calendar's own alerts go off (Phase 6 plays the picked sound with them)
    public var link = ""  // the event's own web link (Phase 8: a pasted Zoom, Meet or Teams link goes here)
    public var files: [Attach] = []  // Phase 8 attachments, only on calendars of an account signed in through Dateline
    public var shownTitle: String { emoji.isEmpty ? title : emoji + " " + title }
    public init(id: String, calendarID: String, title: String, start: Date, end: Date, allDay: Bool, place: String, notes: String, showAs: ShowAs, emoji: String = "", color: Int? = nil, tags: [String] = [], rich: Data? = nil, geo: Geo? = nil, noTravel: Bool = false, leave: Bool? = nil, from: From = .here, alerts: [Date] = [], link: String = "", files: [Attach] = []) { self.id = id; self.calendarID = calendarID; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.place = place; self.notes = notes; self.showAs = showAs; self.emoji = emoji; self.color = color; self.tags = tags; self.rich = rich; self.geo = geo; self.noTravel = noTravel; self.leave = leave; self.from = from; self.alerts = alerts; self.link = link; self.files = files }
}

// One attached file. `id`: iCloud's managed id or the Google Drive file id (nil = a plain link someone else put in the event).
public struct Attach: Equatable { public var name: String; public var url: String; public var size: Int? = nil; public var id: String? = nil; public var type = ""
    public init(name: String, url: String, size: Int? = nil, id: String? = nil, type: String = "") { self.name = name; self.url = url; self.size = size; self.id = id; self.type = type } }

// What Dateline adds to one event, saved on this Mac by the event's identifier.
public struct Extra: Codable, Equatable {
    public var emoji = "", color: Int? = nil, tags: [String] = [], rich: Data? = nil
    public var plain: String? = nil  // the notes text `rich` was made from; if the notes changed elsewhere, the formatting is dropped
    public var noTravel: Bool? = nil, leave: Bool? = nil, from: From? = nil  // optional, so extras saved before Phase 5 still read back
    public var isEmpty: Bool { emoji.isEmpty && color == nil && tags.isEmpty && rich == nil && noTravel == nil && leave == nil && from == nil }
    public init(emoji: String = "", color: Int? = nil, tags: [String] = [], rich: Data? = nil, plain: String? = nil, noTravel: Bool? = nil, leave: Bool? = nil, from: From? = nil) { self.emoji = emoji; self.color = color; self.tags = tags; self.rich = rich; self.plain = plain; self.noTravel = noTravel; self.leave = leave; self.from = from }
}

// A calendar set (B6, F7): which calendars it shows and where its new events go.
public struct CalSet: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var name: String
    public var calendars: [String]
    public var defaultCalendar: String?
    public var lists: [String]? = nil  // Reminders lists shown (Phase 4); nil = sets saved before Phase 4, which leave lists alone
    public init(id: String = UUID().uuidString, name: String, calendars: [String], defaultCalendar: String?, lists: [String]? = nil) { self.id = id; self.name = name; self.calendars = calendars; self.defaultCalendar = defaultCalendar; self.lists = lists }
}

// The set whose calendars are exactly the ones shown (calendars no longer on this Mac are ignored).
public func activeSet(_ sets: [CalSet], calendars: [String], hidden: Set<String>) -> CalSet? {
    let all = Set(calendars), shown = all.subtracting(hidden)
    if shown == all { return nil }  // "All calendars" is picked, even when a set holds every calendar
    return sets.first { Set($0.calendars).intersection(all) == shown }
}

// An event without Dateline's own extras: what the calendar itself holds.
public func calendarPart(_ it: Item) -> Item {
    var it = it
    it.emoji = ""; it.color = nil; it.tags = []; it.rich = nil; it.noTravel = false; it.leave = nil; it.from = .here
    return it
}
public func sameInCalendar(_ a: Item, _ b: Item) -> Bool { calendarPart(a) == calendarPart(b) }

// Phase 8: the Zoom, Meet or Teams link in an event: its own link first, then the place, then the notes.
public struct Call: Equatable { public let service: String, url: URL
    public init(service: String, url: URL) { self.service = service; self.url = url } }
private let linkFinder = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
public func callLink(_ it: Item) -> Call? { callLink(in: [it.link, it.place, it.notes]) }
public func callLink(in texts: [String]) -> Call? {
    func on(_ h: String, _ d: String) -> Bool { h == d || h.hasSuffix("." + d) }  // never a look-alike such as evilzoom.us
    for text in texts where !text.isEmpty {
        for m in linkFinder?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let u = m.url, let h = u.host?.lowercased() else { continue }
            let path = u.path.lowercased()
            if on(h, "zoom.us"), ["/j/", "/my/", "/w/"].contains(where: path.hasPrefix) { return Call(service: "Zoom", url: u) }
            if h == "meet.google.com", path.count > 4 { return Call(service: "Google Meet", url: u) }
            if on(h, "teams.microsoft.com") || on(h, "teams.live.com"), path.contains("meetup-join") || path.hasPrefix("/meet/") { return Call(service: "Microsoft Teams", url: u) }
        }
    }
    return nil
}

// Each day's events, in the order given: an event is on a day when it starts before the day ends and ends after it starts. `from` and `to` cap an event that runs for years.
public func itemsByDay(_ items: [Item], from: Date, to: Date) -> [Date: [Item]] {
    var out: [Date: [Item]] = [:]
    let first = cal.startOfDay(for: from)
    for it in items {
        var d = max(cal.startOfDay(for: it.start), first)
        while d < it.end && d < to { out[d, default: []].append(it); d = cal.startOfDay(for: addDays(d, 1)) }
    }
    return out
}

@MainActor
public final class Store: ObservableObject {
    @Published public var calendars: [CalInfo] = []
    @Published public var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) {
        didSet {
            guard access != .sample else { return }  // tests and pictures never touch the real choice
            UserDefaults.standard.set(Array(hidden), forKey: "hiddenCalendars")
            // The set by name too, so a launch reopens on it even when a calendar came or went since (empty = all, or a hand-picked mix).
            if !calendars.isEmpty { UserDefaults.standard.set(activeSet?.id ?? "", forKey: "lastSet") }
        }
    }
    @Published public private(set) var items: [Item] = [] { didSet { byDay = itemsByDay(items, from: range.0, to: range.1) } }
    private var byDay: [Date: [Item]] = [:]  // grouped once per load, so day squares don't each scan every event
    // Start of day: a date saved in another time zone isn't midnight here, and would otherwise show an empty day.
    public func shown(on day: Date) -> [Item] { (byDay[cal.startOfDay(for: day)] ?? []).filter { !hidden.contains($0.calendarID) } }
    @Published public private(set) var soon: [Item] = []  // the next 120 days, for the "Coming up" card
    @Published public var access: Access = .unknown
    @Published public var defaultCalendarID: String?
    @Published public var sets: [CalSet] = [] { didSet { save(sets, "calendarSets") } }
    @Published public var recentEmoji: [String] = [] { didSet { save(recentEmoji, "recentEmoji") } }
    public enum Access { case unknown, granted, denied, sample }

    public let source: CalendarSource
    private var range: (Date, Date) = (Date(), Date())
    private var changeReload: Task<Void, Never>?
    // Phase 4: Apple Reminders (Tasks.swift).
    @Published public var lists: [CalInfo] = []
    @Published public var hiddenLists: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenLists") ?? []) {
        didSet { if access != .sample { UserDefaults.standard.set(Array(hiddenLists), forKey: "hiddenLists") } }
    }
    @Published public var todos: [ToDo] = []
    @Published public var taskAccess: Access = .unknown
    public var taskFetch = 0  // only the newest Reminders read is kept
    @Published public var a4On = UserDefaults.standard.object(forKey: "a4On") as? Bool ?? true
    @Published public var a4Folder = UserDefaults.standard.string(forKey: "a4Folder") ?? a4DefaultFolder
    public var a4Fetch = 0  // only the newest read of the A4 folder is kept
    public var a4Busy = 0  // a change on its way through Obsidian: a read now would undo what's on screen
    public var a4Observer: Any?
    // Where A4 tasks with a time go, by their project's side of life; nil keeps that side as tasks.
    @Published public var a4Calendar: String? = UserDefaults.standard.string(forKey: "a4Calendar")  // personal
    @Published public var a4WorkCalendar: String? = UserDefaults.standard.string(forKey: "a4WorkCalendar")
    @Published public var a4Links: [String: A4Link] = [:]  // by the note's path
    public var a4Syncing = false
    public var a4LastError: String?

    // Phase 7: subscribed and ready-made calendars (Subscribed.swift).
    @Published public var subs: [Sub] = [] { didSet { save(subs, "subscriptions") } }
    public var subParsed: [String: [ICalEvent]] = [:]
    public var subTried: [String: Date] = [:]
    public var extras: [String: Extra] = [:] { didSet { save(extras, "eventExtras") } }
    // Phase 8: accounts signed in inside Dateline (Accounts.swift).
    @Published public var accounts: [Account] = [] { didSet { save(accounts, "accounts") } }
    public let accData = AccData()
    public var onError: ((String) -> Void)?  // a change that failed on its way to an account

    public convenience init(sample: Bool) { self.init(source: sample ? SampleCalendar() : AppleCalendar()) }

    public init(source: CalendarSource) {
        self.source = source
        source.shownElsewhere = { [weak self] account, calDAV in self?.shownHere(account, calDAV: calDAV) ?? false }
        if let s = source as? SampleCalendar { loadSample(s); listenForChanges(); return }
        // Only when the saved copy reads back: a copy that fails to read must not be overwritten with an empty one.
        if let v: [CalSet] = load("calendarSets") { sets = v }
        if let v: [String] = load("recentEmoji") { recentEmoji = v }
        if let v: [String: Extra] = load("eventExtras") { extras = v }
        if let v: [String: A4Link] = load("a4Links") { a4Links = v }
        loadAccounts()
        listenForChanges()
        loadSubs { self.requestAccess() }
        requestReminders()
        reloadA4()
        #if os(macOS)  // the iPhone has no A4 vault to re-read when the app comes forward
        a4Observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.reloadA4() }
        }
        #endif
    }

    public func saveA4Links() { save(a4Links, "a4Links") }
    public var a4CanSeeEvents: Bool { canRead || !accounts.isEmpty }
    // Whether the events read just now could have included this calendar's: an account's are held in memory until its first sync.
    public func a4HasRead(_ id: String) -> Bool { isAcc(id) ? accCal(id).map { accData.loaded.contains($0.0.id) } == true : canRead }

    // Dateline's own saved data. Sample mode (every test and picture) keeps it in memory only.
    private func save<T: Encodable>(_ v: T, _ key: String) {
        guard access != .sample, let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    public func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public var activeSet: CalSet? { DatelineCore.activeSet(sets, calendars: calendars.map(\.id), hidden: hidden) }

    // Shows only that set's calendars; nil = all calendars.
    public func use(_ s: CalSet?) {
        hidden = s.map { Set(calendars.map(\.id)).subtracting($0.calendars) } ?? []
        if s == nil { hiddenLists = [] } else if let l = s?.lists, !lists.isEmpty { hiddenLists = Set(lists.filter { $0.account != a4Account }.map(\.id)).subtracting(l) }  // A4 has its own switch in Settings; a set never hides its projects
    }

    // Every tag in use and how many events have it, most used first.
    public var allTags: [(String, Int)] {
        Dictionary(extras.values.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +).sorted { ($1.1, $0.0) < ($0.1, $1.0) }
    }

    public func usedEmoji(_ e: String) { recentEmoji = Array(([e] + recentEmoji.filter { $0 != e }).prefix(16)) }

    // A repeating event's occurrences share their extras.
    private func key(_ id: String) -> String { String(resolve(id).split(separator: "|").first ?? "") }

    public func decorated(_ it: Item) -> Item {
        guard let x = extras[key(it.id)] else { return it }
        var it = it
        it.emoji = x.emoji; it.color = x.color; it.tags = x.tags
        it.noTravel = x.noTravel ?? false; it.leave = x.leave; it.from = x.from ?? .here
        if x.plain == it.notes { it.rich = x.rich }
        return it
    }

    private func setExtras(_ it: Item) {
        let x = Extra(emoji: it.emoji, color: it.color, tags: it.tags, rich: it.rich, plain: it.rich == nil ? nil : it.notes,
                      noTravel: it.noTravel ? true : nil, leave: it.leave, from: it.from == .here ? nil : it.from)
        if extras[key(it.id)] != (x.isEmpty ? nil : x) { extras[key(it.id)] = x.isEmpty ? nil : x }
    }

    public func calendar(_ id: String) -> CalInfo? { calendars.first { $0.id == id } }

    public var canRead: Bool { access == .granted || access == .sample }

    private func requestAccess() {
        source.askForEvents { ok in
            self.access = ok ? .granted : .denied
            guard ok else { self.fetch(); return }  // subscribed calendars and accounts still fill "coming up"
            self.reloadCalendars()
            self.refreshSubs()
        }
    }

    // Changes made in Apple Calendar, Reminders or on another device. One sync sends a burst of these: at most one reload every 0.3 seconds, even while the burst lasts.
    private func listenForChanges() {
        source.onChange {
            guard self.changeReload == nil else { return }
            self.changeReload = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.changeReload = nil
                if self.canRead { self.reloadCalendars() }
                self.reloadReminders()
            }
        }
    }

    private var reopened = false
    public func reloadCalendars() {
        calendars = source.calendars() + accInfos + subInfos
        if !reopened {
            reopened = true
            if let id = UserDefaults.standard.string(forKey: "lastSet"), let s = sets.first(where: { $0.id == id }), activeSet?.id != id { use(s) }
        }
        defaultCalendarID = source.defaultCalendar().flatMap { d in d.elsewhere ? accInfos.first { $0.title == d.title }?.id : d.id }
        pastStale = pastCache != nil
        fetch()
    }

    public func refetch() { fetch() }

    // Loads the events between two dates (the visible view plus a margin).
    public func show(from: Date, to: Date) {
        range = (from, to)
        items = between(from, to)  // "coming up" stays: it doesn't depend on where the view is
    }

    private func fetch() {
        items = between(range.0, range.1)
        refreshSoon()
    }

    public func refreshSoon() {
        let now = sampleToday ?? Date(), later = now.addingTimeInterval(120 * 86400)
        let subSoon = subEvents(from: now.addingTimeInterval(-86400), to: later).filter { sub($0.calendarID)?.kind == nil }  // not a sunrise line every day
        let accSoon = accEvents(from: now.addingTimeInterval(-86400), to: later)
        guard canRead else { soon = subSoon + accSoon; return }  // subscribed calendars and accounts need no calendar access
        soon = source.events(from: now.addingTimeInterval(-86400), to: later).map(decorated) + subSoon + accSoon
    }

    // Events between two dates, read without changing what the window shows (the map of places).
    public func between(_ a: Date, _ b: Date) -> [Item] {
        (((canRead ? source.events(from: a, to: b).map(decorated) : []) + subEvents(from: a, to: b) + accEvents(from: a, to: b))).sorted { $0.start < $1.start }
    }

    // The last year's events, one per title, newest first (quick add's "From your past events").
    private var pastCache: [Item]?
    private var pastStale = false  // the calendars changed since it was read
    private var pastFetch = 0  // only the newest read is kept
    public func past() -> [Item] {
        if let pastCache, !pastStale { return pastCache }
        pastStale = false
        let now = sampleToday ?? Date(), from = now.addingTimeInterval(-365 * 86400)
        // After a calendar change the old list answers now and the new one is read in the background, so typing never waits for it.
        if let pastCache, canRead, !source.calendars().isEmpty {
            pastFetch += 1
            let n = pastFetch
            Task {
                let found = await source.eventsInBackground(from: from, to: now)
                guard n == pastFetch else { return }
                self.pastCache = Self.onePerTitle(found + accEvents(from: from, to: now))
                objectWillChange.send()  // an open quick add picks up the new list
            }
            return pastCache
        }
        let list = (canRead ? source.events(from: from, to: now) : []) + accEvents(from: from, to: now)
        pastFetch += 1  // an older background read must not replace this
        let out = Self.onePerTitle(list)
        pastCache = out
        return out
    }

    private static func onePerTitle(_ list: [Item]) -> [Item] {
        var seen = Set<String>()
        return list.sorted { $0.start > $1.start }.filter { seen.insert($0.title.lowercased()).inserted }
    }

    // An event deleted and then put back by undo gets a new identifier; older undo steps still hold the old one.
    private var replaced: [String: String] = [:]
    private func resolve(_ id: String) -> String {
        var id = id
        while let n = replaced[id] { id = n }
        return id
    }
    private func current(_ it: Item) -> Item { var it = it; it.id = resolve(it.id); return it }

    // The ended trial holds every add, change and delete of an event; made-up calendars never are.
    public var trialOver: Bool { access != .sample && !License.shared.canEdit }

    // Adds a new event; returns the saved item, or an error message.
    @discardableResult
    public func add(_ p: Parsed, calendarID: String?) -> Result<Item, Failure> {
        if trialOver { return .failure(Failure(License.endedMessage)) }
        let calID = calendarID ?? defaultCalendarID ?? calendars.first(where: \.writable)?.id
        guard let calID else { return .failure(Failure("No calendar on this Mac can take new events.")) }
        let it = Item(id: "", calendarID: calID, title: p.title.isEmpty ? "New event" : p.title, start: p.start, end: p.end,
                      allDay: p.allDay, place: p.place, notes: p.notes, showAs: p.showAs, geo: p.geo)
        let repeats = p.repeats.map { (unit: $0.unit, n: $0.n) }
        if isAcc(calID) { return accAdd(it, alertMinutes: p.alertMinutes, repeats: repeats) }
        let saved = source.add(it, alertMinutes: p.alertMinutes, repeats: repeats)
        if case .success = saved { fetch() }
        return saved
    }

    // Saves changes to an event (move, stretch, edits in the details panel). Repeating events change this occurrence only.
    @discardableResult
    public func update(_ it: Item) -> Failure? {
        if trialOver { fetch(); return Failure(License.endedMessage) }  // the fetch puts a dragged event back
        // Only Dateline's extras changed (also on read-only calendars and invites): nothing goes to the calendar.
        if let old = items.first(where: { $0.id == it.id }), sameInCalendar(old, it) { setExtras(it); fetch(); return nil }
        if isSub(it.calendarID) { return Failure("Events in a subscribed calendar can't be changed.") }
        let before = items.first { $0.id == it.id }
        if isAcc(it.calendarID) || before.map({ isAcc($0.calendarID) }) == true {
            if let f = accUpdate(it, old: before) { fetch(); return f }
            setExtras(it); fetch(); return nil
        }
        let oldKey = key(it.id)
        switch source.update(current(it), before: before) {
        case .failure(let f): fetch(); return f
        case .success(let nid):
            // Moving to another calendar can give the event a new identifier: the extras move with it.
            if let nid, nid != oldKey { extras[oldKey] = nil; var moved = it; moved.id = nid; setExtras(moved) } else { setExtras(it) }
            fetch()
            return nil
        }
    }

    // `series`: this and every later occurrence (undo of adding a repeating event).
    @discardableResult
    public func delete(_ it: Item, series: Bool = false) -> Failure? {
        if trialOver { return Failure(License.endedMessage) }
        if isSub(it.calendarID) { return Failure("Events in a subscribed calendar can't be deleted. Remove the whole calendar from the sidebar instead.") }
        if isAcc(it.calendarID) {
            let oneTime = !accRepeats(it)
            if let f = accDelete(it, series: series) { return f }
            if oneTime || series { extras[key(it.id)] = nil }
            fetch(); return nil
        }
        switch source.delete(current(it), series: series) {
        case .failure(let f): return f
        case .success(let oneTime):
            // shortcut: extras of events deleted in Apple Calendar stay saved; clean them up if the saved data ever grows large.
            if oneTime || series { extras[key(it.id)] = nil }  // undo copies them back from `it`
            fetch()
            return nil
        }
    }

    // Undo of a delete: puts the event back as a new copy (the Mac gives it a new identifier).
    public func restore(_ it: Item) -> Item? {
        guard let back = duplicate(it) else { return nil }
        replaced[it.id] = back.id
        return back
    }

    // A new one-time event with everything `it` has (Option drag, undo of a delete).
    public func duplicate(_ it: Item) -> Item? {
        var p = Parsed(start: it.start, end: it.end); p.title = it.title; p.allDay = it.allDay; p.place = it.place; p.geo = it.geo; p.showAs = it.showAs
        guard case .success(let added) = add(p, calendarID: isSub(it.calendarID) ? nil : it.calendarID) else { return nil }  // a copy of a subscribed event goes to your own calendar
        var back = added
        back.notes = it.notes; back.link = it.link; back.emoji = it.emoji; back.color = it.color; back.tags = it.tags; back.rich = it.rich
        back.noTravel = it.noTravel; back.leave = it.leave; back.from = it.from
        if back != added { update(back) }
        source.copyAlerts(from: current(it), to: back)
        return back
    }


    // Made-up calendars and events around the mockup's week, relative to today.
    private func loadSample(_ s: SampleCalendar) {
        access = .sample
        taskAccess = .sample
        calendars = s.calendars()
        defaultCalendarID = s.defaultCalendar()?.id
        lists = s.reminderLists()
        todos = s.tasks
        extras = s.firstExtras
        sets = [CalSet(name: "Work", calendars: ["work"], defaultCalendar: "work"),
                CalSet(name: "Family", calendars: ["family", "personal", "school"], defaultCalendar: "family"),
                CalSet(name: "Just me", calendars: ["personal"], defaultCalendar: "personal")]
        subs = [Sub(id: "sub-sample", url: "https://calendar.example-school.cr/grade5/schedule.ics", name: "Grade 5 schedule", color: 3, updated: sampleToday)]
        subParsed["sub-sample"] = parseICS(sampleICS)
        calendars += subInfos
        fetch()
    }
}

// Set by --render so the pictures always show the mockup's week.
public var sampleToday: Date?

public struct Failure: Error { public let message: String; public init(_ m: String) { message = m } }

