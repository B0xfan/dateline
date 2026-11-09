// The widget extension behind the watch face pieces and the Smart Stack card. It reads the watch's own calendars and
// reminders (the watch app asked for access; its pieces share it) and the drive times the watch app left in the app group.
import SwiftUI
import WidgetKit
import DatelineCore

@main
struct DatelineWidgets: WidgetBundle {
    var body: some Widget { NextPiece(); CountdownPiece(); DatePiece(); TasksPiece() }
}

// WidgetKit makes each widget with init(), so one small type per piece.
struct NextPiece: Widget { var body: some WidgetConfiguration { piece("next", "Next event", "Your next event: time and name, or a line along the top.", [.accessoryRectangular, .accessoryInline]) } }
struct CountdownPiece: Widget { var body: some WidgetConfiguration { piece("countdown", "Countdown", "How long until your next event.", [.accessoryCircular]) } }
struct DatePiece: Widget { var body: some WidgetConfiguration { piece("date", "Date", "Today's date.", [.accessoryCircular]) } }
struct TasksPiece: Widget { var body: some WidgetConfiguration { piece("tasks", "Tasks left", "Tasks still open today.", [.accessoryCircular]) } }

func piece(_ kind: String, _ name: String, _ about: String, _ families: [WidgetFamily]) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { e in PieceView(kind: kind, e: e) }
        .configurationDisplayName(name).description(about).supportedFamilies(families)
}

struct PieceView: View {
    let kind: String, e: FaceEntry
    @Environment(\.widgetFamily) var family
    @Environment(\.showsWidgetContainerBackground) var inStack  // true in the Smart Stack, false on a face
    var body: some View {
        FacePiece(kind: kind == "next" ? (family == .accessoryInline ? .inline : inStack ? .card : .box) : FaceKind(rawValue: kind) ?? .date, e: e)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> FaceEntry { .placeholder }
    func getSnapshot(in context: Context, completion: @escaping (FaceEntry) -> Void) {
        if context.isPreview { return completion(.placeholder) }
        Task { @MainActor in completion(await read().first ?? .placeholder) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FaceEntry>) -> Void) {
        Task { @MainActor in completion(Timeline(entries: await read(), policy: .after(Date().addingTimeInterval(3600)))) }
    }

    @MainActor private func read() async -> [FaceEntry] {
        let now = Date(), src = AppleCalendar()
        let colors = Dictionary(src.calendars().map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        let tasks = await withCheckedContinuation { c in src.readReminders { c.resume(returning: $0) } }
        return FaceEntry.timeline(now: now, items: src.events(from: now, to: addDays(cal.startOfDay(for: now), 1)), colors: colors, drive: Shared.drive, tasks: tasks)
    }
}
