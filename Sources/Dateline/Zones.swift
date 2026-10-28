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

// The sidebar card under Coming up.
struct ZoneCard: View {
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TIME ZONES").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
            line("Here", cal.timeZone, zoneCity(cal.timeZone.identifier))
            ForEach(Zones.list) { z in
                let tz = TimeZone(identifier: z.tz) ?? cal.timeZone
                line(z.nick.isEmpty ? z.city : z.nick, tz, (z.nick.isEmpty ? "" : z.city + " · ") + zoneDiff(tz, at: now))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.win))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
        .padding(.horizontal, 8).padding(.top, 10)
    }

    func line(_ name: String, _ tz: TimeZone, _ sub: String) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(name).font(.ui(12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(zoneTime(now, tz, "h:mm a")).font(.ui(12.5, weight: .semibold)).monospacedDigit()
            }
            HStack {
                Text(sub).lineLimit(1)
                Spacer(minLength: 4)
                Text(zoneTime(now, tz, "EEE"))
            }.font(.ui(11)).foregroundStyle(Palette.text3)
        }
    }
}

// The Time zones tab in Settings.
struct ZoneSettings: View {
    @ObservedObject var app: AppState
    @State private var list = Zones.list
    @State private var text = ""
    @State private var missed = false
    @State private var card = Zones.card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(list) { z in
                        let tz = TimeZone(identifier: z.tz) ?? cal.timeZone
                        HStack(spacing: 10) {
                            TextField(z.city, text: Binding(get: { z.nick }, set: { v in edit(z.id) { $0.nick = v } })).textFieldStyle(.roundedBorder).frame(width: 130)
                            Text(z.place).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(zoneOffset(tz, at: app.now)).monospacedDigit().foregroundStyle(Palette.text2).frame(width: 92, alignment: .trailing)
                            Button { save(list.filter { $0.id != z.id }) } label: { Text("✕").foregroundStyle(Palette.text3) }.buttonStyle(.plain).frame(width: 20).help("Remove")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                        .overlay(alignment: .bottom) { if z.id != list.last?.id { Palette.lineSoft.frame(height: 1) } }
                        .draggable(z.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let from = list.firstIndex(where: { $0.id == ids.first }), let to = list.firstIndex(of: z) else { return false }
                            var l = list; l.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to); save(l)
                            return true
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
            }
            if list.count < Zones.most {
                HStack(spacing: 6) {
                    Text("+").foregroundStyle(Palette.accent)
                    TextField("Add a city: type a name, like Lisbon", text: $text).textFieldStyle(.plain).onSubmit(add)
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                if missed { Text("No city found with that name. Try the nearest big city.").font(.system(size: 11.5)).foregroundStyle(Palette.now) }
            }
            Text("The nickname is what the sidebar shows; leave it empty to show the city. Drag rows to reorder. Up to 6 places. Clocks change for summer time by themselves.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Toggle("Show the Time zones card in the sidebar", isOn: Binding(get: { card }, set: { card = $0; Zones.card = $0; app.objectWillChange.send() })).toggleStyle(.switch).controlSize(.small)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 620)
    }

    func edit(_ id: String, _ change: (inout Zone) -> Void) {
        var l = list
        if let i = l.firstIndex(where: { $0.id == id }) { change(&l[i]); save(l) }
    }

    func save(_ l: [Zone]) { list = l; Zones.list = l; app.objectWillChange.send() }  // the sidebar reads Zones as it draws

    func add() {
        let q = text
        Task {
            guard let z = await findZone(q) else { missed = true; return }
            missed = false; text = ""
            if list.count < Zones.most { save(list + [z]) }
        }
    }
}
