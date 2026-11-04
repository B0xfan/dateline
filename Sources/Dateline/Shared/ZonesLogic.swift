// Phase 6 (approved mockup, 2026-10-28): favorite time zones with nicknames, in the sidebar and in Settings. Saved on this Mac.
import SwiftUI
import CoreLocation

struct Zone: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var nick = ""
    var tz: String  // "America/New_York"; the Mac moves the clock for summer time
    var place: String  // "New York, United States"
    var city: String { place.components(separatedBy: ",").first ?? place }
}

enum Zones {
    private static let d = UserDefaults.standard
    static var list = d.data(forKey: "timeZones").flatMap { try? JSONDecoder().decode([Zone].self, from: $0) } ?? [] {
        didSet { if Look.saves, let v = try? JSONEncoder().encode(list) { d.set(v, forKey: "timeZones") } }
    }
    static var card = d.object(forKey: "zoneCard") as? Bool ?? true { didSet { if Look.saves { d.set(card, forKey: "zoneCard") } } }
    static let most = 6

    // The mockup's places, for the off-screen pictures; never saved.
    static func reset() {
        Look.saves = false; card = true
        list = [Zone(nick: "Mom", tz: "America/New_York", place: "New York, United States"),
                Zone(tz: "Europe/London", place: "London, United Kingdom"), Zone(tz: "Asia/Tokyo", place: "Tokyo, Japan")]
    }
}

// How far a place is from here: "2 h ahead", "5 h 30 min behind", "same time".
func zoneDiff(_ tz: TimeZone, at now: Date, here: TimeZone = cal.timeZone) -> String {
    let s = tz.secondsFromGMT(for: now) - here.secondsFromGMT(for: now)
    guard s != 0 else { return "same time" }
    return span(TimeInterval(abs(s))) + (s > 0 ? " ahead" : " behind")
}

// "+2 h", "-5 h 30 min", "+0 h" for the Settings rows.
func zoneOffset(_ tz: TimeZone, at now: Date, here: TimeZone = cal.timeZone) -> String {
    let s = tz.secondsFromGMT(for: now) - here.secondsFromGMT(for: now)
    return (s < 0 ? "-" : "+") + (s == 0 ? "0 h" : span(TimeInterval(abs(s))))
}

// The Mac's own name for its zone's place: "America/Costa_Rica" is "Costa Rica".
func zoneCity(_ id: String) -> String { (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ") }

func zoneTime(_ d: Date, _ tz: TimeZone, _ format: String) -> String { dateText(d, format, in: tz) }

// A typed city, through Apple Maps ("Lisbon, Portugal"); offline, a Mac zone named after it ("Lisbon" is Europe/Lisbon).
func findZone(_ text: String) async -> Zone? {
    let q = text.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return nil }
    if let p = try? await CLGeocoder().geocodeAddressString(q).first, let tz = p.timeZone {
        return Zone(tz: tz.identifier, place: [p.locality ?? p.name ?? q, p.country].compactMap { $0 }.joined(separator: ", "))
    }
    return TimeZone.knownTimeZoneIdentifiers.first { zoneCity($0).caseInsensitiveCompare(q) == .orderedSame }.map { Zone(tz: $0, place: zoneCity($0)) }
}

