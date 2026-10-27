// Phase 5, places and travel (approved mockups, 2026-10-27): a map in each event with a place, one map of all places (P),
// drive time before an event with a "time to leave" alert, and sunrise, sunset and the moon on each day.
// Maps, place search and drive times use Apple Maps (internet, no account, no key). Sun and moon are worked out here.
import SwiftUI
import AppKit
import MapKit
import CoreLocation
import UserNotifications

struct Geo: Codable, Equatable, Hashable {
    var lat: Double, lon: Double
    var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

// Where the drive to an event starts.
// Saved by name, so the shown words can change without losing saved events.
enum From: String, Codable, CaseIterable {
    case here, home, work, before
    var label: String { ["here": "Where I am then", "home": "Home", "work": "Work", "before": "The event before"][rawValue]! }
}

let tamarindo = Geo(lat: 10.30, lon: -85.84)  // the mockups' town, for the pictures and the self-checks

// MARK: where you are

// The Mac's location, asked for once (the Mac shows its own permission box). The last one is kept, so sun times work offline.
@MainActor
final class Here: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Here()
    @Published var spot: Geo? = (UserDefaults.standard.array(forKey: "lastSpot") as? [Double]).flatMap { $0.count == 2 ? Geo(lat: $0[0], lon: $0[1]) : nil }
    private var manager: CLLocationManager?

    func start() {
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager = m
        m.requestWhenInUseAuthorization()
        m.requestLocation()
    }

    func refresh() { manager?.requestLocation() }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations list: [CLLocation]) {
        guard let c = list.last?.coordinate else { return }
        Task { @MainActor in
            self.spot = Geo(lat: c.latitude, lon: c.longitude)
            UserDefaults.standard.set([c.latitude, c.longitude], forKey: "lastSpot")
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}  // no fix: the last saved spot stays
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways { m.requestLocation() }  // on the Mac, "allowed" reads as always
    }
}

func distanceText(_ meters: Double) -> String { meters < 1000 ? "\(Int(meters / 10) * 10) m" : String(format: "%.1f km", meters / 1000) }

func openInMaps(_ g: Geo, name: String, directions: Bool) {
    let m = MKMapItem(placemark: MKPlacemark(coordinate: g.coord))
    m.name = name
    m.openInMaps(launchOptions: directions ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : nil)
}

// MARK: sun and moon (pure maths, covered by --selftest)

private let rad = Double.pi / 180
private func julian(_ t: Date) -> Double { t.timeIntervalSince1970 / 86400 + 2440587.5 }
private func date(julian j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }

// Sunrise and sunset on `day` (the sunrise equation, to about a minute). Nil when the sun stays up or down all day.
func sunTimes(_ day: Date, at g: Geo) -> (rise: Date, set: Date)? {
    let noon = julian(cal.startOfDay(for: day).addingTimeInterval(12 * 3600))
    let n = (noon - 2451545 + g.lon / 360).rounded()  // the solar noon nearest this day's local noon
    let j = n - g.lon / 360
    let m = (357.5291 + 0.98560028 * j).truncatingRemainder(dividingBy: 360)
    let c = 1.9148 * sin(m * rad) + 0.02 * sin(2 * m * rad) + 0.0003 * sin(3 * m * rad)
    let l = (m + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
    let transit = 2451545 + j + 0.0053 * sin(m * rad) - 0.0069 * sin(2 * l * rad)
    let dec = asin(sin(l * rad) * sin(23.4397 * rad))
    let cosW = (sin(-0.833 * rad) - sin(g.lat * rad) * sin(dec)) / (cos(g.lat * rad) * cos(dec))
    guard abs(cosW) <= 1 else { return nil }
    let w = acos(cosW) / rad / 360
    return (date(julian: transit - w), date(julian: transit + w))
}

// How far the moon is ahead of the sun, 0 to 360 degrees (0 new, 90 half, 180 full, 270 half). Main terms only, to within an hour or so.
func moonAngle(_ t: Date) -> Double {
    let d = julian(t) - 2451545
    let g = 357.528 + 0.9856003 * d, mm = 134.963 + 13.064993 * d, dd = 297.850 + 12.190749 * d, f = 93.272 + 13.229350 * d
    let sun = 280.460 + 0.9856474 * d + 1.915 * sin(g * rad) + 0.020 * sin(2 * g * rad)
    let moon = 218.316 + 13.176396 * d + 6.289 * sin(mm * rad) + 1.274 * sin((2 * dd - mm) * rad) + 0.658 * sin(2 * dd * rad)
        + 0.214 * sin(2 * mm * rad) - 0.186 * sin(g * rad) - 0.114 * sin(2 * f * rad)
    let a = (moon - sun).truncatingRemainder(dividingBy: 360)
    return a < 0 ? a + 360 : a
}

enum MoonDay {
    case new, firstHalf, full, lastHalf
    var name: String { self == .new ? "New moon" : self == .full ? "Full moon" : "Half moon" }
}

// The moon phase that happens during `day` (local time), if any.
func moonDay(_ day: Date) -> MoonDay? {
    let a = moonAngle(cal.startOfDay(for: day)), b = moonAngle(addDays(cal.startOfDay(for: day), 1))
    for (target, p) in [(0.0, MoonDay.new), (90, .firstHalf), (180, .full), (270, .lastHalf)] {
        var x = a - target; if x > 180 { x -= 360 }; if x <= -180 { x += 360 }
        let move = (b - a + 360).truncatingRemainder(dividingBy: 360)
        if x < 0 && x + move >= 0 { return p }
    }
    return nil
}

struct MoonDot: View {
    let phase: MoonDay
    var body: some View {
        switch phase {
        case .full: Circle().fill(Color(red: 0.95, green: 0.85, blue: 0.54)).overlay(Circle().strokeBorder(.black.opacity(0.12)))
        case .new: Circle().fill(Palette.text3)
        case .firstHalf, .lastHalf:
            Circle().fill(Palette.lineSoft).overlay(alignment: phase == .firstHalf ? .trailing : .leading) {
                Rectangle().fill(Color(red: 0.95, green: 0.85, blue: 0.54)).frame(width: 5.5)
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
            }
            .font(.ui(10.5)).foregroundStyle(Palette.text3)
        }
    }
    func line(_ t: String, _ moon: MoonDay?, words: Bool) -> some View {
        HStack(spacing: 4) {
            Text("☀ " + t).fixedSize()
            if let moon {
                Text("·").fixedSize()
                MoonDot(phase: moon).frame(width: 10, height: 10).help(moon.name)
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
                        Text("☀ " + t).font(.ui(10.5)).foregroundStyle(amber).padding(.horizontal, 4).background(Palette.win).offset(x: 4, y: y - 8)
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
final class Trips {
    private struct Check { let minutes: Int?; let at: Date; let start: Date; let geo: Geo; let origin: Geo }
    private var checks: [String: Check] = [:]
    private var spots: [Bool: Geo] = [:]  // Home (false) and Work (true) from Contacts, read once per run of the app
    private var running = false, again = false
    private var asked = false  // notification permission asked this run

    // `list`: the events to plan, soonest first. `all`: every coming event, for "the event before".
    // Returns true when a call came in during this round, so the caller plans again with the newest events.
    func run(_ list: [Item], all: [Item], store: Store, done: @escaping ([String: Int]) -> Void) async -> Bool {
        guard !running else { again = true; return false }
        running = true; again = false; defer { running = false }
        let now = Date()
        var asks = 0
        for it in list where asks < 15 {  // shortcut: at most 15 Apple Maps asks per round (it limits them); the rest wait for the next round, 5 minutes on
            let geo = it.geo!, c = checks[it.id]
            // Start not known yet (location not in, or no Home/Work address): nothing saved, so the next round tries again.
            guard let origin = await origin(it, all: all, store: store) else { continue }
            let stale = c == nil || c!.start != it.start || c!.geo != geo || c!.origin.location.distance(from: origin.location) > 1000
                || now.timeIntervalSince(c!.at) > 6 * 3600
                || (it.start.timeIntervalSince(now) < 3600 && c!.at < it.start.addingTimeInterval(-3600))  // again in the last hour, for traffic
            guard stale else { continue }
            asks += 1
            let r = MKDirections.Request()
            r.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coord))
            r.destination = MKMapItem(placemark: MKPlacemark(coordinate: geo.coord))
            r.transportType = .automobile
            r.arrivalDate = it.start
            // Apple Maps did not answer (offline, too many asks): nothing saved, so the next round tries again.
            guard let eta = try? await MKDirections(request: r).calculateETA() else { continue }
            // Under 2 minutes away: already there, no block and no alert.
            let m = Int((eta.expectedTravelTime / 60).rounded(.up))
            checks[it.id] = Check(minutes: m >= 2 ? m : nil, at: now, start: it.start, geo: geo, origin: origin)
        }
        let ids = Set(list.map(\.id))
        checks = checks.filter { ids.contains($0.key) }
        var out: [String: Int] = [:]
        for (id, c) in checks { if let m = c.minutes { out[id] = m } }
        done(out)
        await alerts(list.filter { ($0.leave ?? WorkWeek.leave) && out[$0.id] != nil }, minutes: out)
        return again
    }

    private func origin(_ it: Item, all: [Item], store: Store) async -> Geo? {
        switch it.from {
        case .here: return Here.shared.spot
        case .before:
            let prev = all.filter { $0.geo != nil && !$0.allDay && $0.id != it.id && $0.end <= it.start && cal.isDate($0.end, inSameDayAs: it.start) }.max { $0.end < $1.end }
            return prev?.geo ?? Here.shared.spot
        case .home, .work:
            let work = it.from == .work
            if let s = spots[work] { return s }
            guard case .success(let p) = await store.meAddress(work: work) else { return nil }  // not kept, so it is tried again
            let s = Geo(lat: p.lat, lon: p.lon)
            spots[work] = s
            return s
        }
    }

    // One alert per event at "start minus drive time"; alerts for events no longer planned are taken back.
    private func alerts(_ list: [Item], minutes: [String: Int]) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let want = list.compactMap { it -> (Item, Int, Date)? in
            let m = minutes[it.id]!, at = it.start.addingTimeInterval(-Double(m) * 60)
            return at > now ? (it, m, at) : nil
        }
        if !want.isEmpty && !asked {
            asked = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let keep = Set(want.map { "leave|" + $0.0.id })
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("leave|") && !keep.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for (it, m, at) in want {
            let c = UNMutableNotificationContent()
            c.title = "Time to leave for \(it.title)"
            c.body = "\(m) min drive to \(it.place). Leave now to arrive at \(timeText(it.start, short: true))."
            c.sound = .default
            c.categoryIdentifier = "leave"
            c.userInfo = ["lat": it.geo!.lat, "lon": it.geo!.lon, "place": it.place]
            let t = UNCalendarNotificationTrigger(dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: at), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "leave|" + it.id, content: c, trigger: t))
        }
    }
}

// The buttons on the leave alert: Directions opens Apple Maps, In 5 min shows it again, Dismiss closes it.
final class LeaveAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LeaveAlerts()

    func install() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories([UNNotificationCategory(identifier: "leave", actions: [
            UNNotificationAction(identifier: "directions", title: "Directions", options: [.foreground]),
            UNNotificationAction(identifier: "snooze", title: "In 5 min", options: []),
            UNNotificationAction(identifier: "dismiss", title: "Dismiss", options: []),
        ], intentIdentifiers: [], options: [])])
    }

    // Shown as a banner even when Dateline is the app in front.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let n = r.notification.request
        switch r.actionIdentifier {
        case "directions", UNNotificationDefaultActionIdentifier:
            let u = n.content.userInfo
            if let lat = u["lat"] as? Double, let lon = u["lon"] as? Double {
                let name = u["place"] as? String ?? ""
                await MainActor.run { openInMaps(Geo(lat: lat, lon: lon), name: name, directions: true) }
            }
        case "snooze":
            try? await c.add(UNNotificationRequest(identifier: "snooze|" + UUID().uuidString, content: n.content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)))
        default: break
        }
    }
}

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
            .padding(.horizontal, 7).padding(.top, 2)
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
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let g = Here.shared.spot { completer.region = MKCoordinateRegion(center: g.coord, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
    }

    func query(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).count < 2 { results = []; completer.cancel() } else { completer.queryFragment = text }
    }

    nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        let r = Array(c.results.prefix(5))
        Task { @MainActor in self.results = r }
    }
    nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { Task { @MainActor in self.results = [] } }

    // The picked suggestion's name ("Casa Luna, Tamarindo") and spot on the map.
    func pick(_ s: MKLocalSearchCompletion) async -> (String, Geo)? {
        results = []
        guard let m = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: s)).start().mapItems.first else { return nil }
        let name = m.name ?? s.title, town = m.placemark.locality ?? ""
        let c = m.placemark.coordinate
        return (town.isEmpty || name.contains(town) ? name : name + ", " + town, Geo(lat: c.latitude, lon: c.longitude))
    }
}

// The Place field in the event details: type, then pick from the Apple Maps list. Plain text with no pick saves without a map.
struct PlaceField: View {
    @Binding var item: Item
    var field: FocusState<String?>.Binding
    let commit: () -> Void
    @StateObject private var search = PlaceSearch()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("📍")
                TextField("Add a place", text: Binding(get: { item.place }, set: { v in
                    guard v != item.place else { return }
                    item.place = v; item.geo = nil  // typed by hand: no longer the picked spot
                    search.query(v)
                })).textFieldStyle(.plain).focused(field, equals: "place").onSubmit { search.results = []; commit() }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            if field.wrappedValue == "place" && !search.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results, id: \.self) { s in
                        Button {
                            Task { if let (name, g) = await search.pick(s) { item.place = name; item.geo = g; commit() } }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).lineLimit(1)
                                if !s.subtitle.isEmpty { Text(s.subtitle).font(.ui(11)).foregroundStyle(Palette.text3).lineLimit(1) }
                            }.padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pop).shadow(color: .black.opacity(0.12), radius: 6, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
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
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                if let picture { Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill) } else { Palette.side }
                Pin(color: color, size: 20).offset(y: -14)
            }
            .frame(height: 130).frame(maxWidth: .infinity).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            .contentShape(Rectangle()).onTapGesture { openInMaps(geo, name: name, directions: true) }
            .help("Open in Apple Maps")
            HStack {
                Text(foot).lineLimit(1)
                Spacer(minLength: 6)
                Button("Open in Maps ↗") { openInMaps(geo, name: name, directions: true) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }.font(.ui(11.5)).foregroundStyle(Palette.text2)
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
            HStack(spacing: 10) {
                Text("Places · " + dateText(span.start, "MMM d") + " to " + dateText(span.end.addingTimeInterval(-1), "MMM d")).font(.ui(15, weight: .semibold))
                Seg(options: ["This week", "This month"], selected: month ? "This month" : "This week", small: true) { month = $0 == "This month"; selected = nil; position = .automatic }
                Spacer()
                Button("Done") { app.mapOpen = false }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).frame(height: 52).background(Palette.bar).overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(list.count) EVENT\(list.count == 1 ? "" : "S") WITH A PLACE").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 6).padding(.bottom, 6)
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
                                .padding(6).background(RoundedRectangle(cornerRadius: 7).fill(selected == it.id ? Palette.accentSoft : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(it) }
                                .onTapGesture { selected = it.id; position = .region(MKCoordinateRegion(center: it.geo!.coord, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Events without a place are left out. Only the calendars you have shown are on the map.")
                        .font(.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(6)
                }
                .padding(10).frame(width: 270).background(Palette.side).overlay(alignment: .trailing) { Palette.line.frame(width: 1) }
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
            Text(it.shownTitle).font(.ui(12.5, weight: .semibold))
            Text(dateText(it.start, "EEE MMM d") + (it.allDay ? "" : ", " + timeText(it.start, short: true) + " to " + timeText(it.end, short: true)))
            Text(([it.place] + (app.drive[it.id].map { ["\($0) min drive"] } ?? [])).joined(separator: " · ")).foregroundStyle(Palette.text2)
        }
        .font(.ui(12)).padding(.horizontal, 10).padding(.vertical, 8).frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.pop).shadow(color: .black.opacity(0.2), radius: 13, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
        .onTapGesture(count: 2) { open(it) }
    }

    // Double-click: close the map and open the event's details on its day.
    func open(_ it: Item) {
        app.mapOpen = false
        if !app.visibleDays.contains(cal.startOfDay(for: it.start)) { app.anchor = cal.startOfDay(for: it.start) }
        app.selectedID = it.id
        app.panelOpen = true
    }
}
