// Event search (John's OK 2026-11-06, drawn after BusyCal): the toolbar field (Command F) lists matches on the right side, coming ones first, then past ones newest first.
import SwiftUI
import DatelineCore

// Titles, places and notes in shown calendars, as the iPhone's search does.
func searchEvents(_ text: String, in pool: [Item], hidden: Set<String>, now: Date) -> (coming: [Item], past: [Item]) {
    let q = text.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return ([], []) }
    let hits = pool.filter { it in !hidden.contains(it.calendarID) && [it.shownTitle, it.place, it.notes].contains { $0.localizedCaseInsensitiveContains(q) } }
    return (hits.filter { $0.end >= now }.sorted { $0.start < $1.start }, hits.filter { $0.end < now }.sorted { $0.start > $1.start })
}

struct SearchResults: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @ObservedObject var panels: Panels
    @State private var pool: [Item] = []
    @State private var reads = 0  // bumped when the calendar changes, so a deleted or moved event leaves the list
    @State private var found: (coming: [Item], past: [Item]) = ([], [])
    let cap = 50  // each part shows this many

    var body: some View {
        let count = found.coming.count + found.past.count
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(count == 1 ? "1 result" : "\(count) results").font(.ui(15, weight: .semibold))
                Spacer()
                Button { panels.search = ""; panels.searching = false } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }
                    .accessibilityLabel("Close search").buttonStyle(.plain).foregroundStyle(Palette.text3)
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            List(selection: Binding(get: { panels.searchPick }, set: { id in panels.searchPick = id; if let it = id.flatMap(find) { show(it) } })) {
                if !found.coming.isEmpty { Section("Coming up") { ForEach(found.coming.prefix(cap)) { row($0, past: false) } } }
                if !found.past.isEmpty { Section("Past") { ForEach(found.past.prefix(cap)) { row($0, past: true) } } }
            }
            .scrollContentBackground(.hidden)
            // Double-click or Return opens the details; one click only shows the day.
            .contextMenu(forSelectionType: String.self, menu: { _ in }) { ids in if let it = ids.first.flatMap(find) { app.openEvent(it) } }
            .overlay { if count == 0 { ContentUnavailableView.search(text: panels.search) } }
            Text(count > found.coming.prefix(cap).count + found.past.prefix(cap).count ? "Showing the first \(cap) coming and \(cap) past. Type more to narrow it." : "Titles, places and notes, a year back and a year ahead.")
                .font(.ui(11)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true).padding(16)
        }
        .onChange(of: panels.searchSubmits) { _, _ in  // Return in the field shows the first match, again each time
            if let it = (found.coming + found.past).first { panels.searchPick = it.id; show(it) }
        }
        .onReceive(store.$items.dropFirst()) { _ in reads += 1 }
        .task(id: reads) {
            let read = await store.betweenInBackground(addDays(app.now, -365), addDays(app.now, 366))
            if !Task.isCancelled { pool = read; refresh() }
        }
        .onChange(of: panels.search) { _, _ in refresh() }
        .onChange(of: store.hidden) { _, _ in refresh() }
    }

    func refresh() { found = searchEvents(panels.search, in: pool, hidden: store.hidden, now: app.now) }
    func find(_ id: String) -> Item? { pool.first { $0.id == id } }

    // Shows the event's day with it picked, the results staying put.
    func show(_ it: Item) {
        if !app.visibleDays.contains(cal.startOfDay(for: it.start)) { app.anchor = cal.startOfDay(for: it.start) }
        app.selectedID = it.id
    }

    func row(_ it: Item, past: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(store.color(it)).frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.shownTitle).font(.ui(13, weight: .semibold)).lineLimit(1)
                Text(([dateText(it.start, "EEE, MMM d, yyyy")] + (it.allDay ? [] : [timeText(it.start)]) + (it.place.isEmpty ? [] : [it.place])).joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
            }
        }
        .opacity(past ? 0.6 : 1)
        .tag(it.id)
    }
}
