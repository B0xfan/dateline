// Desktop and Home Screen widgets (approved mockup, John 2026-11-27): the app writes what they show into the shared app group,
// the widgets read it, and a tick in the Tasks widget comes back as a request the app carries out with its own task code.
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// What every widget may show, already merged from all calendars, accounts and task lists. Filtered per widget by its calendar set.
public struct WSnap: Codable, Equatable {
    public struct Ev: Codable, Equatable {
        public var id, title, cal, color, place: String
        public var start, end: Date
        public var allDay: Bool
        public var leave: Date?  // when to leave, if the app knows the drive time
        public init(id: String, title: String, cal: String, color: String, place: String = "", start: Date, end: Date, allDay: Bool = false, leave: Date? = nil) { self.id = id; self.title = title; self.cal = cal; self.color = color; self.place = place; self.start = start; self.end = end; self.allDay = allDay; self.leave = leave }
    }
    public struct Job: Codable, Equatable {
        public var id, title, list: String
        public var due: Date?
        public var timed = false, done = false
        public var a4 = false  // an A4 project task: a calendar set never hides those (Store.use)
        public init(id: String, title: String, list: String, due: Date?, timed: Bool = false, done: Bool = false, a4: Bool = false) { self.id = id; self.title = title; self.list = list; self.due = due; self.timed = timed; self.done = done; self.a4 = a4 }
    }
    public struct Group: Codable, Equatable {
        public var id, name: String
        public var calendars: [String]
        public var lists: [String]?
        public init(id: String, name: String, calendars: [String], lists: [String]? = nil) { self.id = id; self.name = name; self.calendars = calendars; self.lists = lists }
    }
    public var events: [Ev] = []
    public var tasks: [Job] = []
    public var sets: [Group] = []
    public var weather: [String: String] = [:]  // "2026-11-27": "31° · clear"
    public init() {}

    /// What a widget showing `set` holds; nil or a set since deleted shows everything.
    public func only(_ set: String?) -> WSnap {
        guard let g = sets.first(where: { $0.id == set }) else { return self }
        var s = self
        let c = Set(g.calendars)
        s.events = events.filter { c.contains($0.cal) }
        if let l = g.lists.map(Set.init) { s.tasks = tasks.filter { $0.a4 || l.contains($0.list) } }
        return s
    }

    /// The day's events: all-day ones first, then by start.
    public func on(_ day: Date) -> [Ev] {
        let a = cal.startOfDay(for: day), b = addDays(a, 1)
        return events.filter { $0.start < b && ($0.end > a || ($0.start >= a && $0.end == $0.start)) }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }

    /// The next timed event not yet over (one under way counts).
    public func next(after now: Date) -> Ev? { events.filter { !$0.allDay && $0.end > now }.min { $0.start < $1.start } }

    /// Tasks due today or earlier, late ones first; a ticked one stays (struck through) until the app has saved it.
    public func due(now: Date) -> [Job] {
        let end = addDays(cal.startOfDay(for: now), 1)
        return tasks.filter { $0.due.map { $0 < end } == true }.sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture) < ($1.done ? 1 : 0, $1.due ?? .distantFuture) }
    }
}

public enum WidgetShare {
    #if os(macOS)
    public static let group = "LJZ32VB25F.com.johnhesch.dateline"  // team-prefixed: a Developer ID app needs no profile for it
    #else
    public static let group = "group.com.johnhesch.dateline"  // the watch app already shares this one
    #endif
    public static let tickNote = "com.johnhesch.dateline.widget-tick"
    /// Tests point this at a scratch folder.
    public static var folder: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)

    public static func read() -> WSnap? { load("widgets.json") }
    /// True when the saved copy changed, so the app asks the widgets to redraw only then.
    @discardableResult public static func write(_ s: WSnap) -> Bool { store(s, "widgets.json") }

    /// Tasks ticked in a widget, with when, waiting for the app. One file per tick, so a tick made while the app is
    /// clearing others is never written over.
    public static func ticks() -> [String: Date] {
        guard let f = folder, let names = try? FileManager.default.contentsOfDirectory(atPath: f.path) else { return [:] }
        return names.filter { $0.hasPrefix("tick-") }.reduce(into: [:]) { all, n in
            let one: [String: Date]? = load(n)
            one?.forEach { all[$0.key] = $0.value }
        }
    }
    public static func clearTick(_ id: String) { folder.map { try? FileManager.default.removeItem(at: $0.appendingPathComponent(tickFile(id))) } }
    private static func tickFile(_ id: String) -> String { "tick-" + id.utf8.map { String(format: "%02x", $0) }.joined() + ".json" }

    /// The Tasks widget's tick: shows at once, and tells the app, which saves it (or picks it up when it next starts).
    public static func tick(_ id: String, now: Date = Date()) {
        store([id: now], tickFile(id))
        if var s = read(), let i = s.tasks.firstIndex(where: { $0.id == id }) { s.tasks[i].done = true; write(s) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(tickNote as CFString), nil, nil, true)
    }

    /// The app's side of the ticks: the tasks to tick now, and the ticks left waiting. A tick means "done", never a toggle, so a
    /// task already done is dropped. A tick leaves the list once handed over, so a repeating task never moves on twice; one for a
    /// task not read yet waits up to a day.
    public static func settle(_ waiting: [String: Date], todos: [ToDo], loaded: Bool, now: Date) -> (tick: [ToDo], keep: [String: Date]) {
        var tick: [ToDo] = [], keep: [String: Date] = [:]
        for (id, when) in waiting {
            if let t = todos.first(where: { $0.id == id }) { if !t.done { tick.append(t) } }
            else if !loaded || now.timeIntervalSince(when) < 86400 { keep[id] = when }
        }
        return (tick, keep)
    }

    /// The day a widget link names: dateline://day/2026-11-27 or dateline://event/<id>?day=2026-11-27.
    public static func day(of link: URL) -> Date? {
        let s = link.host == "day" ? link.lastPathComponent : URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "day" }?.value
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = cal; f.timeZone = cal.timeZone
        return s.flatMap(f.date(from:)).map { cal.startOfDay(for: $0) }
    }

    /// The app's side of the ticks, run after every change to the tasks: saves one tick per pass, since a save still under way
    /// turns the next one away; the change it makes runs the next pass. Ticks for tasks already done, or never found, go.
    public static func takeTick(todos: [ToDo], loaded: Bool, now: Date = Date(), save: (ToDo) -> Void) {
        let waiting = ticks()
        guard !waiting.isEmpty else { return }
        let (tick, keep) = settle(waiting, todos: todos, loaded: loaded, now: now)
        waiting.keys.filter { id in keep[id] == nil && !tick.contains { $0.id == id } }.forEach(clearTick)
        if let t = tick.first { clearTick(t.id); save(t) }
    }

    /// iPhone only: the Up next widget's Add button runs in the widget, so it leaves this for the app it opens.
    /// (On the Mac the button is a plain dateline://add link.) Opens the app, which then puts the cursor in its add box.
    public static func ask(_ what: String, now: Date = Date()) {
        store([what: now], "ask.json")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(tickNote as CFString), nil, nil, true)
    }
    /// The app's side: what a widget asked for in the last two minutes, once.
    public static func takeAsk(now: Date = Date()) -> String? {
        guard let a: [String: Date] = load("ask.json"), let (what, when) = a.first else { return nil }
        store([String: Date](), "ask.json")
        return now.timeIntervalSince(when) < 120 ? what : nil
    }

    private static func load<T: Decodable>(_ name: String) -> T? {
        folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    @discardableResult private static func store<T: Encodable>(_ v: T, _ name: String) -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys  // the same data writes the same bytes
        guard let url = folder?.appendingPathComponent(name), let data = try? enc.encode(v), (try? Data(contentsOf: url)) != data else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// "#2f6fde" for a color, as the light look draws it; the widgets read it back with `Color(hex:)`.
public func hexOf(_ c: Color) -> String {
    #if os(macOS)
    var out = "#808080"
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        if let s = NSColor(c).usingColorSpace(.sRGB) { out = String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255)) }
    }
    return out
    #else
    var r: CGFloat = 0.5, g: CGFloat = 0.5, b: CGFloat = 0.5, a: CGFloat = 1
    #if os(iOS)
    UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
    #else  // the watch has one look
    UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    return String(format: "#%02x%02x%02x", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    #endif
}

extension Color {
    public init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x808080
        self.init(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}

extension Store {
    /// The widgets' copy: this week and month so far, the next two months, and the tasks due by today.
    /// `drive`: minutes of driving before an event; `weather`: the day's forecast, nil when off.
    public func widgetSnap(drive: [String: Int], weather: (Date) -> WxDay?, now: Date = Date()) -> WSnap {
        var s = WSnap()
        let today = cal.startOfDay(for: now), first = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let later = addDays(today, 62)
        var seen = Set<String>()
        let all = between(min(first, startOfWeek(now)), today) + soon  // `soon` starts yesterday; the dupes go below
        s.events = all.filter { !isBlocks($0.calendarID) && $0.start < later && seen.insert($0.id + "@\($0.start.timeIntervalSince1970)").inserted }
            .sorted { $0.start < $1.start }
            .map { e in WSnap.Ev(id: e.id, title: e.shownTitle, cal: e.calendarID, color: hexOf(color(e)), place: e.place, start: e.start, end: e.end, allDay: e.allDay,
                                 leave: drive[e.id].map { e.start.addingTimeInterval(-Double($0) * 60) }) }
        let end = addDays(today, 1)
        s.tasks = todos.filter { !hiddenLists.contains($0.listID) && !$0.done && $0.due.map { $0 < end } == true }
            .map { WSnap.Job(id: $0.id, title: $0.title, list: $0.listID, due: $0.due, timed: $0.timed, a4: $0.a4 != nil) }
        s.sets = sets.map { WSnap.Group(id: $0.id, name: $0.name, calendars: $0.calendars, lists: $0.lists) }
        for i in 0..<7 { let d = addDays(today, i); if let w = weather(d) { s.weather[wxDayKey(d)] = "\(degrees(w.hi)) · \(wxLook(w.code).words.lowercased())" } }
        return s
    }
}
