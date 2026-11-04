// Phase 5, places and travel (approved mockups, 2026-10-27): a map in each event with a place, one map of all places (P),
// drive time before an event with a "time to leave" alert, and sunrise, sunset and the moon on each day.
// Maps, place search and drive times use Apple Maps (internet, no account, no key). Sun and moon are worked out here.
import SwiftUI
import MapKit
import CoreLocation
import UserNotifications

public struct Geo: Codable, Equatable, Hashable {
    public var lat: Double, lon: Double
    public var coord: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    public var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

// Where the drive to an event starts.
// Saved by name, so the shown words can change without losing saved events.
public enum From: String, Codable, CaseIterable {
    case here, home, work, before
    public var label: String { ["here": "Where I am then", "home": "Home", "work": "Work", "before": "The event before"][rawValue]! }
}

public let tamarindo = Geo(lat: 10.30, lon: -85.84)  // the mockups' town, for the pictures and the self-checks

// MARK: where you are

// The Mac's location, asked for once (the Mac shows its own permission box). The last one is kept, so sun times work offline.
@MainActor
public final class Here: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = Here()
    @Published public var spot: Geo? = (UserDefaults.standard.array(forKey: "lastSpot") as? [Double]).flatMap { $0.count == 2 ? Geo(lat: $0[0], lon: $0[1]) : nil }
    private var manager: CLLocationManager?

    public func start() {
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager = m
        m.requestWhenInUseAuthorization()
        m.requestLocation()
    }

    public func refresh() { manager?.requestLocation() }

    public nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations list: [CLLocation]) {
        guard let c = list.last?.coordinate else { return }
        Task { @MainActor in
            self.spot = Geo(lat: c.latitude, lon: c.longitude)
            UserDefaults.standard.set([c.latitude, c.longitude], forKey: "lastSpot")
        }
    }
    public nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}  // no fix: the last saved spot stays
    public nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways { m.requestLocation() }  // on the Mac, "allowed" reads as always
        #if os(iOS)
        if m.authorizationStatus == .authorizedWhenInUse { m.requestLocation() }  // the first ask fails while the iPhone's permission box is up
        #endif
    }
}

public func distanceText(_ meters: Double) -> String { meters < 1000 ? "\(Int(meters / 10) * 10) m" : String(format: "%.1f km", meters / 1000) }

public func openInMaps(_ g: Geo, name: String, directions: Bool) {
    let m = MKMapItem(placemark: MKPlacemark(coordinate: g.coord))
    m.name = name
    m.openInMaps(launchOptions: directions ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : nil)
}

// MARK: sun and moon (pure maths, covered by --selftest)

private let rad = Double.pi / 180
private func julian(_ t: Date) -> Double { t.timeIntervalSince1970 / 86400 + 2440587.5 }
private func date(julian j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400) }

// Sunrise and sunset on `day` (the sunrise equation, to about a minute). Nil when the sun stays up or down all day.
public func sunTimes(_ day: Date, at g: Geo) -> (rise: Date, set: Date)? {
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
public func moonAngle(_ t: Date) -> Double {
    let d = julian(t) - 2451545
    let g = 357.528 + 0.9856003 * d, mm = 134.963 + 13.064993 * d, dd = 297.850 + 12.190749 * d, f = 93.272 + 13.229350 * d
    let sun = 280.460 + 0.9856474 * d + 1.915 * sin(g * rad) + 0.020 * sin(2 * g * rad)
    let moon = 218.316 + 13.176396 * d + 6.289 * sin(mm * rad) + 1.274 * sin((2 * dd - mm) * rad) + 0.658 * sin(2 * dd * rad)
        + 0.214 * sin(2 * mm * rad) - 0.186 * sin(g * rad) - 0.114 * sin(2 * f * rad)
    let a = (moon - sun).truncatingRemainder(dividingBy: 360)
    return a < 0 ? a + 360 : a
}

public enum MoonDay {
    case new, firstHalf, full, lastHalf
    public var name: String { self == .new ? "New moon" : self == .full ? "Full moon" : "Half moon" }
}

// The moon phase that happens during `day` (local time), if any.
public func moonDay(_ day: Date) -> MoonDay? {
    let a = moonAngle(cal.startOfDay(for: day)), b = moonAngle(addDays(cal.startOfDay(for: day), 1))
    for (target, p) in [(0.0, MoonDay.new), (90, .firstHalf), (180, .full), (270, .lastHalf)] {
        var x = a - target; if x > 180 { x -= 360 }; if x <= -180 { x += 360 }
        let move = (b - a + 360).truncatingRemainder(dividingBy: 360)
        if x < 0 && x + move >= 0 { return p }
    }
    return nil
}

@MainActor
public final class Trips {
    public init() {}
    private struct Check { let minutes: Int?; let at: Date; let start: Date; let geo: Geo; let origin: Geo }
    private var checks: [String: Check] = [:]
    private var spots: [Bool: Geo] = [:]  // Home (false) and Work (true) from Contacts, read once per run of the app
    private var running = false, again = false
    private var asked = false  // notification permission asked this run

    // `list`: the events to plan, soonest first. `all`: every coming event, for "the event before".
    // Returns true when a call came in during this round, so the caller plans again with the newest events.
    public func run(_ list: [Item], all: [Item], store: Store, done: @escaping ([String: Int]) -> Void) async -> Bool {
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
            if let g = prev?.geo { return g }
            return Here.shared.spot
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
            c.sound = nil  // Dateline plays the sound picked in Settings, Alerts
            c.categoryIdentifier = "leave"
            c.userInfo = ["lat": it.geo!.lat, "lon": it.geo!.lon, "place": it.place]
            let t = UNCalendarNotificationTrigger(dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: at), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "leave|" + it.id, content: c, trigger: t))
        }
    }
}

// The buttons on the leave alert: Directions opens Apple Maps, In 5 min shows it again, Dismiss closes it.
public final class LeaveAlerts: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = LeaveAlerts()

    public func install() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories([UNNotificationCategory(identifier: "leave", actions: [
            UNNotificationAction(identifier: "directions", title: "Directions", options: [.foreground]),
            UNNotificationAction(identifier: "snooze", title: "In 5 min", options: []),
            UNNotificationAction(identifier: "dismiss", title: "Dismiss", options: []),
        ], intentIdentifiers: [], options: [])])
    }

    // Shown as a banner even when Dateline is the app in front.
    public func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    public func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
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
            await MainActor.run { DispatchQueue.main.asyncAfter(deadline: .now() + 300) { Alerts.play("leave") } }
        default: break
        }
    }
}

@MainActor
public final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published public var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    public override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let g = Here.shared.spot { completer.region = MKCoordinateRegion(center: g.coord, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
    }

    public func query(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).count < 2 { results = []; completer.cancel() } else { completer.queryFragment = text }
    }

    public nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        let r = Array(c.results.prefix(5))
        Task { @MainActor in self.results = r }
    }
    public nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { Task { @MainActor in self.results = [] } }

    // The picked suggestion's name ("Casa Luna, Tamarindo") and spot on the map.
    public func pick(_ s: MKLocalSearchCompletion) async -> (String, Geo)? {
        results = []
        guard let m = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: s)).start().mapItems.first else { return nil }
        let name = m.name ?? s.title, town = m.placemark.locality ?? ""
        let c = m.placemark.coordinate
        return (town.isEmpty || name.contains(town) ? name : name + ", " + town, Geo(lat: c.latitude, lon: c.longitude))
    }
}

