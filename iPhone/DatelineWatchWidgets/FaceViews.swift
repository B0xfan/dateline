// The watch face pieces and the Smart Stack card (approved watch mockup 4, John 2026-11-09), shared by the widget extension
// and the watch app (whose debug build draws them for the cloud pictures, as the simulator can't put a piece on a face).
import SwiftUI
import WidgetKit
import DatelineCore

/// The watch app and its face pieces share drive times through the app group (the pieces can't ask Apple Maps themselves).
enum Shared {
    static let group = UserDefaults(suiteName: "group.com.johnhesch.dateline")
    static var drive: [String: Int] { group?.dictionary(forKey: "drive") as? [String: Int] ?? [:] }
    static func save(drive: [String: Int]) { group?.set(drive, forKey: "drive") }
}

/// What the pieces show at one minute: the event on now or next today, the one after it, and tasks still open today.
struct FaceEntry: TimelineEntry {
    let date: Date
    var next: Item? = nil
    var color: Color = .gray
    var leave: Date? = nil  // start minus the drive time, when the watch app knows one
    var then: Item? = nil
    var tasks = 0
    var relevance: TimelineEntryRelevance? = nil
    var noAccess = false  // calendars not allowed yet: say so instead of a false "Nothing more today"

    static var placeholder: FaceEntry {
        let s = Date().addingTimeInterval(2 * 3600)
        return FaceEntry(date: Date(), next: Item(id: "p", calendarID: "", title: "Lunch with Sam", start: s, end: s.addingTimeInterval(3600), allDay: false, place: "", notes: "", showAs: .busy), color: .green, tasks: 3)
    }

    /// One entry a minute for the next 90 minutes (so the countdowns can be plain text), then one at each start, end and
    /// Smart Stack moment in the next 24 hours, and each midnight for the date. Each entry shows its own day's events. The pieces reload every hour, and sooner when the watch app sees a change.
    /// shortcut: a reload watchOS holds back past 90 minutes leaves the countdown text still until the next start; switch to Text(timerInterval:) if that shows up.
    static func timeline(now: Date, items: [Item], colors: [String: Color], drive: [String: Int], tasks: [ToDo]) -> [FaceEntry] {
        let start = cal.date(bySetting: .second, value: 0, of: now) ?? now, until = now.addingTimeInterval(86400)
        let timed = items.filter { !$0.allDay && $0.end > now && $0.start < until }.sorted { $0.start < $1.start }
        let leave = { (it: Item) in drive[it.id].map { it.start.addingTimeInterval(-Double($0) * 60) } }
        // Smart Stack: to the top from 15 minutes before leaving (or 30 before the start) until it starts.
        let rises = { (it: Item) in leave(it).map { $0.addingTimeInterval(-900) } ?? it.start.addingTimeInterval(-1800) }
        var dates = Set((0..<90).map { start.addingTimeInterval(Double($0) * 60) })
        for it in timed { dates.formUnion([it.start, it.end, rises(it)]) }
        dates.formUnion([cal.startOfDay(for: addDays(now, 1)), cal.startOfDay(for: until)])
        return dates.filter { $0 >= start && $0 < until }.sorted().map { d in
            let left = openToday(tasks, at: d).count
            // the entry's own day: what is on now, and what is still to come that day
            let rest = timed.filter { $0.end > d && (cal.isDate($0.start, inSameDayAs: d) || $0.start <= d) }
            guard let it = pickNext(rest, at: d) else { return FaceEntry(date: d, tasks: left) }
            let rel = d >= rises(it) && d < it.start ? TimelineEntryRelevance(score: 100, duration: it.start.timeIntervalSince(d)) : nil
            return FaceEntry(date: d, next: it, color: colors[it.calendarID] ?? .gray, leave: leave(it), then: rest.first { $0.start > it.start }, tasks: left, relevance: rel)
        }
    }
}

/// The event to show from events not yet over, soonest first: the one on now, unless another starts before it ends
/// (an all-morning block must not hide the 10:00 dentist).
func pickNext(_ rest: [Item], at d: Date) -> Item? {
    guard let cur = rest.first, cur.start <= d, let up = rest.first(where: { $0.start > d }), up.start < cur.end else { return rest.first }
    return up
}

/// Tasks still open today, late ones included: the Tasks piece's count.
func openToday(_ tasks: [ToDo], at d: Date) -> [ToDo] { tasks.filter { !$0.done && [.overdue, .today].contains(taskGroup($0, now: d)) } }

/// "in 2 h 21 m", "in 5 m", "now"; `short` gives "2h21", "5m".
func faceCountdown(to d: Date, from now: Date, short: Bool = false) -> String {
    let m = Int((d.timeIntervalSince(now) / 60).rounded(.up))
    guard m > 0 else { return "now" }
    let h = m / 60, r = m % 60
    if short { return h == 0 ? "\(r)m" : "\(h)h\(r < 10 ? "0" : "")\(r)" }
    return h == 0 ? "in \(r) m" : r == 0 ? "in \(h) h" : "in \(h) h \(r) m"
}

/// The first word of the title, for the small round's label: "LUNCH".
private func firstWord(_ s: String) -> String { String(s.split(separator: " ").first ?? "").uppercased() }

enum FaceKind: String { case inline, box, countdown, date, tasks, card }

struct FacePiece: View {
    let kind: FaceKind
    let e: FaceEntry
    var body: some View {
        switch kind {
        case .inline: inline
        case .box: box
        case .card: card
        case .countdown: countdown
        case .date: round(dateText(e.date, "d"), dateText(e.date, "EEE").uppercased(), .red)
        case .tasks: round("\(e.tasks)", "TASKS", .primary)
        }
    }

    /// The line along the top: "Lunch with Sam · in 2 h 21 m", "… · now" while it is on.
    @ViewBuilder var inline: some View {
        if e.noAccess {
            Text("Open Dateline to allow calendars")
        } else if let it = e.next {
            let name = it.title.count > 16 ? it.title.prefix(15) + "…" : Substring(it.title)  // the countdown must stay on the line
            Text("\(name) · \(it.start <= e.date ? "now" : faceCountdown(to: it.start, from: e.date))")
        } else {
            Text("Nothing more today")
        }
    }

    /// The larger box, like the one John circled on his Modular face: time on top, name under it, a bar in the calendar's color.
    var box: some View {
        HStack(spacing: 6) {
            Capsule().fill(e.next == nil ? .gray : e.color).frame(width: 3).frame(maxHeight: .infinity).widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                if e.noAccess {
                    Text("Dateline").font(.headline)
                    Text("Open the app to allow calendars").font(.headline).foregroundStyle(.secondary).lineLimit(2)
                } else if let it = e.next {
                    Text(range(it.start, it.end)).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    Text(it.title).font(.headline).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(dateText(e.date, "EEEE")).font(.headline)
                    Text("Nothing more today").font(.headline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "9:45 – 10:15 AM" (as on John's Modular face), "10 AM – 12 PM".
    private func range(_ a: Date, _ b: Date) -> String {
        let same = dateText(a, "a") == dateText(b, "a")
        return "\(same ? dateText(a, cal.component(.minute, from: a) == 0 ? "h" : "h:mm") : timeText(a, short: true)) – \(timeText(b, short: true))"
    }

    /// The Smart Stack card: the next event, where, and when to leave (or what comes after it).
    var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("DATELINE").font(.caption2.weight(.bold)).foregroundStyle(.red)
            if e.noAccess {
                Text("Open the app to allow calendars").font(.headline).foregroundStyle(.secondary).lineLimit(2)
            } else if let it = e.next {
                Text(it.title).font(.headline).lineLimit(1)
                Text(timeText(it.start) + (it.place.isEmpty ? "" : " · " + it.place)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let l = e.leave, l > e.date {
                    Text("Leave \(timeText(l))").font(.caption).foregroundStyle(Palette.tags[1])
                } else if let t = e.then {
                    Text("Then \(timeText(t.start, short: true)) \(t.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Nothing more today").font(.headline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The small round with a ring that empties as the next event comes closer (full at an hour or more).
    @ViewBuilder var countdown: some View {
        if let it = e.next, it.start > e.date {
            let left = it.start.timeIntervalSince(e.date)
            Gauge(value: min(left, 3600), in: 0...3600) {
                Text(firstWord(it.title))
            } currentValueLabel: {
                Text(faceCountdown(to: it.start, from: e.date, short: true))
            }
            .gaugeStyle(.accessoryCircularCapacity).tint(e.color)
        } else {
            round(e.next == nil ? "–" : "now", e.next.map { firstWord($0.title) } ?? "FREE", .primary)
        }
    }

    private func round(_ big: String, _ small: String, _ tint: Color) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(big).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(tint).widgetAccentable()
                Text(small).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}
