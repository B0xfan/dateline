// Dateline's desktop (Mac) and Home Screen (iPhone) widgets, approved mockup John 2026-11-27: Today, Up next, Tasks,
// This week and Month. They read the copy the app leaves in the app group (WidgetLogic.swift); none reads calendars itself.
// Each widget picks its own calendar set; a tick in Tasks goes back to the app, which saves it like a click on the task.
import SwiftUI
import WidgetKit
import AppIntents
import DatelineCore

#if !RENDER  // the picture check (scripts/render-widgets.sh) brings its own main
@main
#endif
struct DatelineWidgets: WidgetBundle {
    var body: some Widget { TodayWidget(); NextWidget(); TasksWidget(); WeekWidget(); MonthWidget() }
}

// MARK: - Calendar set choice

struct SetEntity: AppEntity {
    var id: String
    var name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar set"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = SetQuery()
}

struct SetQuery: EntityQuery {
    static let all = SetEntity(id: "", name: "All calendars")
    func entities(for identifiers: [String]) async throws -> [SetEntity] { try await suggestedEntities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [SetEntity] { [Self.all] + (WidgetShare.read()?.sets ?? []).map { SetEntity(id: $0.id, name: $0.name) } }
    func defaultResult() async -> SetEntity? { Self.all }
}

struct PickSet: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Calendar set"
    static var description = IntentDescription("Which calendars this widget shows.")
    @Parameter(title: "Calendar set") var set: SetEntity?
}

struct TickTask: AppIntent {
    static var title: LocalizedStringResource = "Mark task done"
    static var isDiscoverable = false
    @Parameter(title: "Task") var id: String
    init() {}
    init(id: String) { self.id = id }
    func perform() async throws -> some IntentResult { WidgetShare.tick(id); return .result() }
}

struct AddEvent: AppIntent {
    static var title: LocalizedStringResource = "Add to Dateline"
    static var isDiscoverable = false
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { WidgetShare.ask("add"); return .result() }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    var date: Date
    var snap: WSnap
    var family: WidgetFamily = .systemMedium  // carried here, not read from the environment, so the picture check can set it
    var empty = false  // the app has not written anything yet
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample(Date()), family: context.family) }
    func snapshot(for p: PickSet, in context: Context) async -> Entry { context.isPreview ? placeholder(in: context) : entries(p, context.family).first! }
    func timeline(for p: PickSet, in context: Context) async -> Timeline<Entry> { Timeline(entries: entries(p, context.family), policy: .atEnd) }

    // A new entry when an event starts or ends (Up next moves on) and at midnight, for the next 12 hours.
    private func entries(_ p: PickSet, _ family: WidgetFamily) -> [Entry] {
        let now = Date()
        guard let all = WidgetShare.read() else { return [Entry(date: now, snap: WSnap(), family: family, empty: true)] }
        let snap = all.only(p.set?.id.isEmpty == false ? p.set?.id : nil)
        let end = now.addingTimeInterval(12 * 3600)
        var times = Set(snap.events.flatMap { [$0.start, $0.end] }.filter { $0 > now && $0 < end })
        times.insert(addDays(cal.startOfDay(for: now), 1))
        return ([now] + times.sorted().prefix(30)).map { Entry(date: $0, snap: snap, family: family) }
    }
}

func config<V: View>(_ kind: String, _ name: String, _ about: String, _ families: [WidgetFamily], @ViewBuilder _ view: @escaping (Entry) -> V) -> some WidgetConfiguration {
    AppIntentConfiguration(kind: kind, intent: PickSet.self, provider: Provider()) { e in
        Group { if e.empty { Text("Open Dateline once to fill this widget.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) } else { view(e) } }
            .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName(name).description(about).supportedFamilies(families)
}

// WidgetKit makes each widget with init(), so one small type per widget.
struct TodayWidget: Widget { var body: some WidgetConfiguration { config("today", "Today", "Today's events, with weather and when to leave.", [.systemSmall, .systemMedium, .systemLarge]) { TodayView(e: $0) } } }
struct NextWidget: Widget { var body: some WidgetConfiguration { config("next", "Up next", "Your next event, and a button to add one.", [.systemSmall]) { NextView(e: $0) } } }
struct TasksWidget: Widget { var body: some WidgetConfiguration { config("tasks", "Tasks", "Tasks due today and late ones. Tick them off here.", [.systemSmall, .systemMedium, .systemLarge]) { TasksView(e: $0) } } }
struct WeekWidget: Widget { var body: some WidgetConfiguration { config("week", "This week", "The next seven days at a glance.", [.systemMedium, .systemLarge]) { WeekView(e: $0) } } }
struct MonthWidget: Widget { var body: some WidgetConfiguration { config("month", "Month", "This month, with dots on busy days.", [.systemSmall, .systemLarge]) { MonthView(e: $0) } } }

// MARK: - Pieces

/// A link inside a widget. The picture check cannot draw a real Link (it draws a stop sign), so there it is the plain content.
struct Tap<C: View>: View {
    let url: URL
    @ViewBuilder let content: () -> C
    init(_ url: URL, @ViewBuilder content: @escaping () -> C) { self.url = url; self.content = content }
    #if RENDER
    var body: some View { content() }
    #else
    var body: some View { Link(destination: url, label: content) }
    #endif
}

let accent = Color(hex: "#2f6fde"), nowRed = Color(hex: "#e5484d")

func link(_ day: Date) -> URL { URL(string: "dateline://day/\(wxDayKey(day))")! }
func link(_ ev: WSnap.Ev) -> URL {
    URL(string: "dateline://event/\(ev.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? "")?day=\(wxDayKey(ev.start))")!
}
func when(_ ev: WSnap.Ev) -> String {
    ev.allDay ? "All day" : timeText(ev.start, short: true) + (ev.leave.map { " · leave \(timeText($0))" } ?? "")
}

struct Row: View {
    let ev: WSnap.Ev
    var body: some View {
        Tap(link(ev)) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: ev.color)).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ev.title).fontWeight(.semibold).lineLimit(1)
                    Text(when(ev)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DayHead: View {
    let day: Date, weather: String?
    var big = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateText(day, "EEEE").uppercased()).font(.caption2.bold()).foregroundStyle(nowRed)
            Text(dateText(day, "d")).font(.system(size: big ? 34 : 26, weight: .semibold)).minimumScaleFactor(0.6)
            if let weather { Text(weather).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

// MARK: - Today

struct TodayView: View {
    let e: Entry
    var family: WidgetFamily { e.family }
    var body: some View {
        let day = cal.startOfDay(for: e.date)
        let list = e.snap.on(day).filter { $0.allDay || $0.end > e.date }
        let fits = family == .systemLarge ? 8 : family == .systemMedium ? 3 : 2
        let head = DayHead(day: day, weather: e.snap.weather[wxDayKey(day)], big: family != .systemSmall)
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(list.prefix(fits), id: \.id) { Row(ev: $0) }
            if list.isEmpty { Text("Nothing else today").foregroundStyle(.secondary) }
            if list.count > fits { Text("+\(list.count - fits) more").foregroundStyle(.secondary) }
        }.font(.caption)
        Group {
            if family == .systemMedium { HStack(alignment: .top, spacing: 14) { head; rows; Spacer(minLength: 0) } }
            else { VStack(alignment: .leading, spacing: 8) { head; rows; Spacer(minLength: 0) }.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .widgetURL(link(day))
    }
}

// MARK: - Up next

struct NextView: View {
    let e: Entry
    var body: some View {
        let n = e.snap.next(after: e.date)
        VStack(alignment: .leading, spacing: 3) {
            Text(n.map { $0.start <= e.date ? "NOW" : "NEXT" } ?? "NEXT").font(.caption2.bold()).foregroundStyle(.secondary)
            if let n {
                Text(n.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text((cal.isDate(n.start, inSameDayAs: e.date) ? "" : dateText(n.start, "EEE") + " ") + timeText(n.start, short: true)).font(.caption).foregroundStyle(.secondary)
                if let l = n.leave, l > e.date { Text("Leave \(timeText(l))").font(.caption.weight(.semibold)).foregroundStyle(nowRed) }
            } else {
                Text("Nothing coming up").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(intent: AddEvent()) { Text("+ Add").font(.caption.weight(.semibold)).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(n.map(link) ?? link(e.date))
    }
}

// MARK: - Tasks

struct TasksView: View {
    let e: Entry
    var family: WidgetFamily { e.family }
    var body: some View {
        let list = e.snap.due(now: e.date)
        let fits = family == .systemLarge ? 10 : family == .systemMedium ? 4 : 3
        let start = cal.startOfDay(for: e.date)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TASKS").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(list.filter { !$0.done }.count)").font(.caption2.bold()).foregroundStyle(.secondary)
            }
            ForEach(list.prefix(fits), id: \.id) { t in
                HStack(spacing: 6) {
                    Button(intent: TickTask(id: t.id)) {
                        Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? accent : .secondary)
                    }.buttonStyle(.plain)
                    Text(t.title).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let d = t.due, d < start, !t.done { Text(dateText(d, "MMM d")).foregroundStyle(nowRed) }
                    else if t.timed, let d = t.due { Text(timeText(d, short: true)).foregroundStyle(.secondary) }
                }
            }
            if list.isEmpty { Text("All done for today").foregroundStyle(.secondary) }
            if list.count > fits { Text("+\(list.count - fits) more").foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .widgetURL(link(e.date))
    }
}

// MARK: - This week

struct WeekView: View {
    let e: Entry
    var family: WidgetFamily { e.family }
    var body: some View {
        let today = cal.startOfDay(for: e.date)
        let days = (0..<7).map { addDays(today, $0) }
        let per = family == .systemLarge ? 3 : 1
        VStack(alignment: .leading, spacing: family == .systemLarge ? 5 : 2) {
            ForEach(days, id: \.self) { d in
                let list = e.snap.on(d)
                Tap(link(d)) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(dateText(d, "EEE d")).font(.caption.bold()).foregroundStyle(d == today ? nowRed : .primary).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(list.prefix(per), id: \.id) { ev in
                                HStack(spacing: 4) {
                                    Circle().fill(Color(hex: ev.color)).frame(width: 6, height: 6)
                                    Text((ev.allDay ? "" : timeText(ev.start, short: true) + " ") + ev.title).lineLimit(1)
                                }
                            }
                            if list.isEmpty { Text("Free").foregroundStyle(.tertiary) }
                        }
                        Spacer(minLength: 0)
                        if list.count > per { Text("+\(list.count - per)").foregroundStyle(.secondary) }
                    }
                    .font(.caption2)
                    .frame(maxHeight: family == .systemLarge ? .infinity : nil, alignment: .topLeading)  // the large size spreads the week down the widget
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Month

struct MonthView: View {
    let e: Entry
    var family: WidgetFamily { e.family }
    var body: some View {
        let today = cal.startOfDay(for: e.date)
        let first = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        let gridStart = startOfWeek(first)
        let weeks = Int(ceil(Double(cal.dateComponents([.day], from: gridStart, to: addDays(first, cal.range(of: .day, in: .month, for: first)!.count)).day!) / 7))
        let big = family == .systemLarge
        VStack(alignment: .leading, spacing: big ? 6 : 2) {
            Text(dateText(today, big ? "MMMM yyyy" : "MMMM").uppercased()).font(.caption2.bold()).foregroundStyle(nowRed)
            Grid(horizontalSpacing: 0, verticalSpacing: big ? 4 : 1) {
                GridRow { ForEach(0..<7, id: \.self) { i in Text(dateText(addDays(gridStart, i), "EEEEE")).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                ForEach(0..<weeks, id: \.self) { w in
                    GridRow {
                        ForEach(0..<7, id: \.self) { i in
                            let d = addDays(gridStart, w * 7 + i)
                            let inMonth = cal.isDate(d, equalTo: first, toGranularity: .month)
                            let busy = inMonth ? e.snap.on(d).prefix(3).map(\.color) : []
                            Tap(link(d)) {
                                VStack(spacing: 1) {
                                    Text(dateText(d, "d")).fontWeight(d == today ? .bold : .regular)
                                        .foregroundStyle(d == today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                                        .frame(width: big ? 22 : 16, height: big ? 22 : 16)
                                        .background(d == today ? nowRed : .clear, in: Circle())
                                    HStack(spacing: 1) { ForEach(Array(busy.enumerated()), id: \.offset) { Circle().fill(Color(hex: $0.element)).frame(width: 3, height: 3) } }.frame(height: 3)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .font(big ? .caption : .system(size: 9))
            if big {
                Divider()
                ForEach(e.snap.on(today).prefix(3), id: \.id) { Row(ev: $0).font(.caption) }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Gallery preview

extension WSnap {
    /// What the widget gallery shows before you add one: made-up events, never your own.
    static func sample(_ now: Date) -> WSnap {
        var s = WSnap()
        let t = cal.startOfDay(for: now)
        func at(_ d: Int, _ h: Double) -> Date { addDays(t, d).addingTimeInterval(h * 3600) }
        s.events = [
            .init(id: "a", title: "Team call", cal: "w", color: "#2f6fde", start: at(0, 9), end: at(0, 9.5)),
            .init(id: "b", title: "Dentist", cal: "p", color: "#e5484d", place: "Main St", start: at(0, 14), end: at(0, 15), leave: at(0, 13.6)),
            .init(id: "c", title: "Dinner with Sam", cal: "p", color: "#30a46c", start: at(0, 19), end: at(0, 21)),
            .init(id: "d", title: "Market day", cal: "p", color: "#f5a623", start: at(2, 0), end: at(3, 0), allDay: true),
            .init(id: "e", title: "Yoga", cal: "p", color: "#8e4ec6", start: at(3, 7), end: at(3, 8)),
        ]
        s.tasks = [.init(id: "1", title: "Pay the water bill", list: "l", due: at(-1, 0)), .init(id: "2", title: "Call the plumber", list: "l", due: at(0, 0)),
                   .init(id: "3", title: "Book flights", list: "l", due: at(0, 0))]
        s.weather[wxDayKey(t)] = "29° · sunny"
        return s
    }
}
