// One event (approved mockup "Event details"): when to leave, the details, notes, directions and delete. Edit opens the edit sheet.
import SwiftUI
import UIKit
import MapKit
import DatelineCore

struct DetailsView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @ObservedObject private var weather = WeatherStore.shared
    let id: String
    @State private var editing = false
    @State private var askDelete = false
    @State private var problem: String?

    var body: some View {
        Group {
            if let it = app.item(id) { content(it) } else { Text("This event is gone.").foregroundStyle(T.text2).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(T.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { if app.demoEdit { app.demoEdit = false; editing = true } }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
    }

    private func content(_ it: Item) -> some View {
        let c = store.color(it)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Bar(color: c, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.shownTitle).font(.title2.bold())
                        Text(whenText(it.start, it.end, allDay: it.allDay)).font(.subheadline).foregroundStyle(T.text2)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                if let m = app.drive[it.id] {
                    HStack(spacing: 12) {
                        Image(systemName: "car").font(.title3).foregroundStyle(Palette.tags[3])
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Leave by \(timeText(it.start.addingTimeInterval(-Double(m) * 60)))").fontWeight(.semibold)
                            Text(driveLine(it, m)).font(.footnote).foregroundStyle(T.text2)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Palette.tags[3].opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16).padding(.top, 16)
                }
                SectionLabel("Details")
                Card {
                    Row(label: "Where") {
                        Text(it.place.isEmpty ? "None" : it.place).foregroundStyle(it.place.isEmpty ? T.text2 : T.text)
                    }
                    Row(label: "Calendar") { Dot(color: c); Text(store.calendar(it.calendarID)?.title ?? "") }
                    Row(label: "Show as") { Text(it.showAs.rawValue) }
                    Row(label: "Alerts", last: it.tags.isEmpty) { Text(alertsLine(it)) }
                    if !it.tags.isEmpty {
                        Row(label: "Tags", last: true) {
                            ForEach(it.tags, id: \.self) { t in
                                Text(t).font(.footnote).padding(.horizontal, 10).padding(.vertical, 2).background(T.line, in: Capsule())
                            }
                        }
                    }
                }
                if let call = callLink(it) {
                    SectionLabel("Video call")
                    Card {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(call.service).fontWeight(.semibold)
                                Text((call.url.host ?? "") + call.url.path).font(.footnote).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Button("Join") { UIApplication.shared.open(call.url) }.buttonStyle(.borderedProminent).accessibilityLabel("Join \(call.service) call")
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                if let g = it.geo, !it.place.isEmpty {
                    SectionLabel("Map")
                    Card {
                        Map(initialPosition: .region(MKCoordinateRegion(center: g.coord, latitudinalMeters: 1200, longitudinalMeters: 1200)), interactionModes: []) {
                            Marker(it.place, coordinate: g.coord).tint(c)
                        }
                        .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Map of \(it.place)")
                        if let w = weatherLine(it, g) { Text(w).font(.footnote).foregroundStyle(T.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10) }
                    }
                }
                if !it.notes.isEmpty {
                    SectionLabel("Notes")
                    Card {
                        Text(notesShown(it.notes)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                HStack(spacing: 10) {
                    if it.geo != nil || !it.place.isEmpty {
                        Button { directions(it) } label: { Text("Directions").frame(maxWidth: .infinity, minHeight: 50).background(T.bg2, in: RoundedRectangle(cornerRadius: 12)) }
                            .foregroundStyle(T.tint)
                    }
                    if store.calendar(it.calendarID)?.writable == true {
                    Button { askDelete = true } label: { Text("Delete").frame(maxWidth: .infinity, minHeight: 50).background(T.bg2, in: RoundedRectangle(cornerRadius: 12)) }
                        .foregroundStyle(T.late)
                    }
                }
                .font(.callout.weight(.semibold)).buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.top, 20)
            }
            .padding(.bottom, 120)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing, onDismiss: app.sheetClosed) { EditSheet(it).environmentObject(app).environmentObject(store) }
        .confirmationDialog("Delete \(it.title)?", isPresented: $askDelete, titleVisibility: .visible) {
            // A repeating event asks which ones go; the core's delete takes "this and every later" as `series`.
            if store.isRepeating(it) {
                Button("This event only", role: .destructive) { delete(it, series: false) }
                Button("All future events", role: .destructive) { delete(it, series: true) }
            } else {
                Button("Delete", role: .destructive) { delete(it, series: false) }
            }
        }
    }

    private func delete(_ it: Item, series: Bool) {
        if let f = app.delete(it, series: series) { if store.trialOver { app.showUnlock = true } else { problem = f.message } } else { app.path.removeAll { $0 == it.id } }
    }

    private func weatherLine(_ it: Item, _ g: Geo) -> String? {
        guard WeatherPrefs.on, let f = WeatherStore.shared.forecast(g) else { return nil }
        if !it.allDay, let h = f.hours[wxHourKey(it.start)] { return "\(degrees(h.temp)) and \(wxLook(h.code).words.lowercased()) at \(timeText(it.start)) · \(h.rain)% chance of rain" }
        return f.days[wxDayKey(it.start)].map { "\(wxLook($0.code).words), high \(degrees($0.hi)), low \(degrees($0.lo))" }
    }

    private func driveLine(_ it: Item, _ m: Int) -> String {
        var s = "\(m) min drive"
        if let g = it.geo, let h = WeatherStore.shared.forecast(g)?.hours[wxHourKey(it.start)] { s += " · \(degrees(h.temp)) and \(wxLook(h.code).words.lowercased())" }
        return s
    }

    private func alertsLine(_ it: Item) -> String {
        var parts = it.alerts.map { alertText(max(0, Int(it.start.timeIntervalSince($0) / 60))) }
        if app.drive[it.id] != nil && (it.leave ?? WorkWeek.leave) { parts.append(parts.isEmpty ? "When to leave" : "and when to leave") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    /// The Mac's checklist lines as ticks.
    private func notesShown(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { l in
            l.hasPrefix("[x] ") ? "☑︎ " + String(l.dropFirst(4)) : l.hasPrefix("[ ] ") ? "☐ " + String(l.dropFirst(4)) : l.hasPrefix("- ") ? "• " + String(l.dropFirst(2)) : String(l)
        }.joined(separator: "\n")
    }

    private func directions(_ it: Item) {
        if let g = it.geo { openInMaps(g, name: it.place, directions: true); return }
        var u = URLComponents(string: "https://maps.apple.com/")!
        u.queryItems = [.init(name: "daddr", value: it.place)]
        if let url = u.url { UIApplication.shared.open(url) }
    }
}
