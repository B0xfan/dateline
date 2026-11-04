// Phase 5, places and travel (approved mockups, 2026-10-27): a map in each event with a place, one map of all places (P),
// drive time before an event with a "time to leave" alert, and sunrise, sunset and the moon on each day.
// Maps, place search and drive times use Apple Maps (internet, no account, no key). Sun and moon are worked out here.
import SwiftUI
import AppKit
import MapKit
import CoreLocation
import UserNotifications

struct MoonDot: View {
    let phase: MoonDay
    var body: some View {
        switch phase {
        case .full: Circle().fill(Color(red: 0.95, green: 0.85, blue: 0.54)).overlay(Circle().strokeBorder(.black.opacity(0.12)))
        case .new: Circle().fill(Palette.text3)
        case .firstHalf, .lastHalf:
            Circle().fill(Palette.lineSoft).overlay(alignment: phase == .firstHalf ? .trailing : .leading) {
                Rectangle().fill(Color(red: 0.95, green: 0.85, blue: 0.54)).frame(width: 4)
            }.clipShape(Circle()).overlay(Circle().strokeBorder(Palette.text3.opacity(0.6)))
        }
    }
}

// The line under a day's name: "☀ 5:32 AM · 5:21 PM · Full moon". Narrow columns drop words first.
struct SunRow: View {
    let day: Date, at: Geo
    var body: some View {
        if let s = sunTimes(day, at: at) {
            let moon = moonDay(day)
            ViewThatFits(in: .horizontal) {
                line(timeText(s.rise, short: false) + " · " + timeText(s.set, short: false), moon, words: true)
                line(timeText(s.rise, short: false) + " · " + timeText(s.set, short: false), moon, words: false)
                line(clock(s.rise) + " · " + clock(s.set), moon, words: false)
                Color.clear.frame(height: 0)  // no room: left out
            }
            .font(.ui(11)).foregroundStyle(Palette.text3)
        }
    }
    func line(_ t: String, _ moon: MoonDay?, words: Bool) -> some View {
        HStack(spacing: 4) {
            Text("☀ " + t).fixedSize()
            if let moon {
                Text("·").fixedSize()
                MoonDot(phase: moon).frame(width: 12, height: 12).help(moon.name)
                if words { Text(moon.name).fixedSize() }
            }
        }
    }
    func clock(_ d: Date) -> String { dateText(d, "h:mm") }
}

// Night hours faintly tinted and a dashed line at sunrise and sunset, behind a full 24-hour day column. `labels`: the first column names them.
struct SunHours: View {
    let day: Date, at: Geo, labels: Bool
    var body: some View {
        if let s = sunTimes(day, at: at) {
            let rise = CGFloat(s.rise.timeIntervalSince(day) / 3600) * hourH, set = CGFloat(s.set.timeIntervalSince(day) / 3600) * hourH
            let amber = Color(red: 0.85, green: 0.55, blue: 0.1)
            ZStack(alignment: .topLeading) {
                Canvas { c, size in
                    let night = Color(red: 0.55, green: 0.42, blue: 0.85).opacity(0.06)
                    c.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rise)), with: .color(night))
                    c.fill(Path(CGRect(x: 0, y: set, width: size.width, height: size.height - set)), with: .color(night))
                    for y in [rise, set] {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        c.stroke(p, with: .color(amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                if labels {
                    ForEach([(rise, "Sunrise " + timeText(s.rise, short: false)), (set, "Sunset " + timeText(s.set, short: false))], id: \.1) { y, t in
                        Text("☀ " + t).font(.ui(11)).foregroundStyle(amber).padding(.horizontal, 4).background(Palette.win).offset(x: 4, y: y - 8)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: travel time and the leave alert

// Drive times for the coming week's events with a place, from Apple Maps, and the leave alerts that go with them.
@MainActor
extension AppState {
    // Every few minutes and whenever the coming events change: drive times for the next 7 days' events with a place.
    func planTravel() {
        let now = sampleToday ?? Date()
        let all = store.soon.filter { !store.hidden.contains($0.calendarID) }
        let list = all.filter { $0.geo != nil && !$0.allDay && !$0.noTravel && $0.start > now && $0.start < now.addingTimeInterval(7 * 86400) }.sorted { $0.start < $1.start }
        if store.access == .sample { drive = Dictionary(uniqueKeysWithValues: list.map { ($0.id, 25) }); return }  // the mockup's 25 min, no Apple Maps
        guard store.access == .granted else { return }
        Task { if await trips.run(list, all: all, store: store, done: { m in if self.drive != m { self.drive = m } }) { planTravel() } }
    }
}

// The striped block just before an event: the drive there.
struct TravelBlock: View {
    let minutes: Int, color: Color
    var body: some View {
        Text("🚗 \(minutes) min").font(.ui(11)).foregroundStyle(Palette.text2).lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).fill(ImagePaint(image: stripes(color), scale: 1)))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .clipped()
            .allowsHitTesting(false)
    }
}

// MARK: picking a place

// Apple Maps suggestions as you type a place, near where you are.
@MainActor
// The Place field in the event details: type, then pick from the Apple Maps list. Plain text with no pick saves without a map.
struct PlaceField: View {
    @Binding var item: Item
    var field: FocusState<String?>.Binding
    let commit: () -> Void
    @StateObject private var search = PlaceSearch()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("📍")
                TextField("Add a place", text: Binding(get: { item.place }, set: { v in
                    guard v != item.place else { return }
                    item.place = v; item.geo = nil  // typed by hand: no longer the picked spot
                    search.query(v)
                })).textFieldStyle(.plain).focused(field, equals: "place").onSubmit { search.results = []; commit() }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            if field.wrappedValue == "place" && !search.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results, id: \.self) { s in
                        Button {
                            Task { if let (name, g) = await search.pick(s) { item.place = name; item.geo = g; commit() } }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).lineLimit(1)
                                if !s.subtitle.isEmpty { Text(s.subtitle).font(.ui(11)).foregroundStyle(Palette.text3).lineLimit(1) }
                            }.padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pop).shadow(color: .black.opacity(0.12), radius: 6, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                .padding(.top, 4)
            }
        }
    }
}

// The pin on the maps: a drop with an optional number.
struct Pin: View {
    let color: Color
    var number: Int? = nil
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: size / 2, bottomLeadingRadius: 0, bottomTrailingRadius: size / 2, topTrailingRadius: size / 2)
                .fill(color).frame(width: size, height: size).rotationEffect(.degrees(-45))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .overlay(UnevenRoundedRectangle(topLeadingRadius: size / 2, bottomLeadingRadius: 0, bottomTrailingRadius: size / 2, topTrailingRadius: size / 2)
                    .strokeBorder(Palette.win, lineWidth: 2).rotationEffect(.degrees(-45)))
            if let number { Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
        }.frame(width: size * 1.42, height: size * 1.42)
    }
}

// The small map in the event details: a picture from Apple Maps (no scrolling), the address, how far, and Open in Maps.
struct SmallMap: View {
    let geo: Geo, name: String, color: Color
    var from: (String, Geo)?  // where the drive starts, for "2.4 km from Home"
    @Environment(\.colorScheme) private var scheme
    @State private var picture: NSImage?
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let picture { Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill) } else { Palette.side }
                Pin(color: color, size: 20).offset(y: -14)
            }
            .frame(height: 132).frame(maxWidth: .infinity).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            .contentShape(Rectangle()).onTapGesture { openInMaps(geo, name: name, directions: true) }
            .help("Open in Apple Maps")
            HStack {
                Text(foot).lineLimit(1)
                Spacer(minLength: 6)
                Button("Open in Maps ↗") { openInMaps(geo, name: name, directions: true) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }.font(.ui(12)).foregroundStyle(Palette.text2)
        }
        .task(id: "\(geo.lat),\(geo.lon),\(scheme == .dark)") { await load() }
    }

    var foot: String {
        let far = from.map { distanceText($0.1.location.distance(from: geo.location)) + " from " + $0.0 }
        return [address.isEmpty ? nil : address, far].compactMap { $0 }.joined(separator: " · ")
    }

    func load() async {
        let o = MKMapSnapshotter.Options()
        o.region = MKCoordinateRegion(center: geo.coord, latitudinalMeters: 900, longitudinalMeters: 1800)
        o.size = CGSize(width: 300, height: 130)
        o.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        picture = try? await MKMapSnapshotter(options: o).start().image
        if let p = try? await CLGeocoder().reverseGeocodeLocation(geo.location).first {
            address = [p.thoroughfare, p.locality].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

// MARK: the map of all places (P)

struct PlacesMap: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State private var month = false
    @State private var selected: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var list: [Item] = []

    var body: some View {
        let span = month ? cal.dateInterval(of: .month, for: app.anchor)! : DateInterval(start: startOfWeek(app.anchor), duration: 7 * 86400)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Places · " + dateText(span.start, "MMM d") + " to " + dateText(span.end.addingTimeInterval(-1), "MMM d")).font(.ui(15, weight: .semibold))
                Seg(options: ["This week", "This month"], selected: month ? "This month" : "This week", small: true) { month = $0 == "This month"; selected = nil; position = .automatic }
                Spacer()
                Button("Done") { app.panels.mapOpen = false }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 52).background(Palette.bar).overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(list.count) EVENT\(list.count == 1 ? "" : "S") WITH A PLACE").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.bottom, 4)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(Circle().fill(store.color(it)))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(it.shownTitle).lineLimit(1)
                                        Text(dateText(it.start, "EEE") + " " + (it.allDay ? "all day" : timeText(it.start, short: true)) + " · " + it.place).font(.ui(11)).foregroundStyle(Palette.text3).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(selected == it.id ? Palette.accentSoft : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(it) }
                                .onTapGesture { selected = it.id; position = .region(MKCoordinateRegion(center: it.geo!.coord, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Events without a place are left out. Only the calendars you have shown are on the map.")
                        .font(.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(8)
                }
                .padding(12).frame(width: 272).background(Palette.side).overlay(alignment: .trailing) { Palette.line.frame(width: 1) }
                Map(position: $position) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                        Annotation("", coordinate: it.geo!.coord, anchor: .bottom) {
                            VStack(spacing: 4) {
                                if selected == it.id { callout(it) }
                                Pin(color: store.color(it), number: i + 1, size: selected == it.id ? 30 : 24)
                                    .onTapGesture(count: 2) { open(it) }
                                    .onTapGesture { selected = selected == it.id ? nil : it.id }
                            }
                        }
                    }
                    UserAnnotation()
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .background(Palette.win)
        // Read once per week or month (and when the events change), not on every redraw while the map moves.
        .task(id: [span.start, span.end] + store.items.map(\.start)) { list = store.between(span.start, span.end).filter { $0.geo != nil && !store.hidden.contains($0.calendarID) } }
    }

    func callout(_ it: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(it.shownTitle).font(.ui(13, weight: .semibold))
            Text(dateText(it.start, "EEE MMM d") + (it.allDay ? "" : ", " + timeText(it.start, short: true) + " to " + timeText(it.end, short: true)))
            Text(([it.place] + (app.drive[it.id].map { ["\($0) min drive"] } ?? [])).joined(separator: " · ")).foregroundStyle(Palette.text2)
        }
        .font(.ui(12)).padding(.horizontal, 12).padding(.vertical, 8).frame(width: 212, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pop).shadow(color: .black.opacity(0.2), radius: 13, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .onTapGesture(count: 2) { open(it) }
    }

    // Double-click: close the map and open the event's details on its day.
    func open(_ it: Item) {
        app.panels.mapOpen = false
        if !app.visibleDays.contains(cal.startOfDay(for: it.start)) { app.anchor = cal.startOfDay(for: it.start) }
        app.selectedID = it.id
        app.panels.panelOpen = true
    }
}

