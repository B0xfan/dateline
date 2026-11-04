// Phase 6 (approved mockups, 2026-10-28): the full screen alert and the alert sounds. Saved on this Mac.
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum Alerts {
    private static let d = UserDefaults.standard
    public static let leads = ["When it starts", "1 min before", "5 min before"], leadMinutes = [0, 1, 5]
    public static let kinds = [("events", "Events", "Glass"), ("tasks", "Tasks", "Pop"), ("leave", "Time to leave", "Submarine"), ("full", "Full screen", "Hero")]
    // The Mac's own sounds, so nothing is downloaded.
    public static let sounds = ["No sound"] + ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .map { ($0 as NSString).deletingPathExtension }.sorted()

    public static var full = d.object(forKey: "fullAlert") as? Bool ?? true { didSet { save(full, "fullAlert") } }
    public static var lead = d.object(forKey: "fullLead") as? Int ?? 0 { didSet { save(lead, "fullLead") } }
    // nil until the first change: then only calendars called Work are on.
    public static var fullCalendars = (d.array(forKey: "fullCalendars") as? [String]).map(Set.init) { didSet { save(Array(fullCalendars ?? []), "fullCalendars") } }
    public static var sound = d.dictionary(forKey: "alertSounds") as? [String: String] ?? [:] { didSet { save(sound, "alertSounds") } }

    private static func save(_ v: Any, _ key: String) { if Look.saves { d.set(v, forKey: key) } }

    public static func covers(_ c: CalInfo) -> Bool { fullCalendars?.contains(c.id) ?? (c.title.caseInsensitiveCompare("Work") == .orderedSame) }
    public static func soundName(_ kind: String) -> String { sound[kind] ?? kinds.first { $0.0 == kind }!.2 }

    public static func play(_ kind: String) { play(name: soundName(kind)) }
    public static func play(name: String) {
        #if os(macOS)  // the iPhone gets its sounds from notifications
        guard name != "No sound", let s = NSSound(named: NSSound.Name(name)) else { return }
        s.stop(); s.play()
        #endif
    }

    // The mockup's choices, for the off-screen pictures and the self-checks; never saved.
    public static func reset() { Look.saves = false; full = true; lead = 0; fullCalendars = nil; sound = [:] }
}

// Events whose full screen alert time (start minus `lead` minutes) falls after `from`, up to `to`.
public func fullScreenDue(_ items: [Item], from: Date, to: Date, lead: Int, covers: (String) -> Bool) -> [Item] {
    items.filter { it in
        let t = it.start.addingTimeInterval(-Double(lead * 60))
        return !it.allDay && t > from && t <= to && covers(it.calendarID)
    }.sorted { $0.start < $1.start }
}

public func anyIn(_ dates: [Date], from: Date, to: Date) -> Bool { dates.contains { $0 > from && $0 <= to } }

// "STARTING NOW", "IN 5 MIN", "STARTED 5 MIN AGO" (after a snooze).
public func startWord(_ start: Date, now: Date) -> String {
    let s = start.timeIntervalSince(now)
    if abs(s) < 30 { return "STARTING NOW" }
    return s > 0 ? "IN \(span((s / 60).rounded(.up) * 60).uppercased())" : "STARTED \(span(-s).uppercased()) AGO"
}

