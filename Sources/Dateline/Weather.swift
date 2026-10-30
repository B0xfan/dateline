// Phase 8: the weather forecast on each day header and at an event's place, from Open-Meteo (free for an app that
// isn't sold, no sign-up; it asks for the "Weather data by Open-Meteo.com" line, which is in the Weather settings).
// About 16 days ahead; further out shows nothing. Sample mode and the off-screen pictures use made-up weather, never the network.
import SwiftUI
import CoreLocation

struct WxDay: Equatable { var code: Int, hi: Double, lo: Double, rain: Int }
struct WxHour: Equatable { var code: Int, temp: Double, rain: Int, wind: Double }
struct Forecast: Equatable {
    var days: [String: WxDay] = [:]    // "2026-10-30", in the Mac's time zone
    var hours: [String: WxHour] = [:]  // "2026-10-30T15:00"
}

enum WeatherPrefs {
    private static let d = UserDefaults.standard
    static var on = d.object(forKey: "weatherOn") as? Bool ?? true { didSet { save(on, "weatherOn") } }
    static var fahrenheit = d.object(forKey: "weatherF") as? Bool ?? false { didSet { save(fahrenheit, "weatherF") } }
    /// The town for the day headers; empty = where the Mac is.
    static var town = d.string(forKey: "weatherTown") ?? "" { didSet { save(town, "weatherTown") } }
    static var townGeo = (d.array(forKey: "weatherTownGeo") as? [Double]).flatMap { $0.count == 2 ? Geo(lat: $0[0], lon: $0[1]) : nil } { didSet { if let g = townGeo { save([g.lat, g.lon], "weatherTownGeo") } else if Look.saves { d.removeObject(forKey: "weatherTownGeo") } } }
    private static func save(_ v: Any, _ key: String) { if Look.saves { d.set(v, forKey: key) } }
    static func reset() { on = true; fahrenheit = false; town = ""; townGeo = nil }
}

/// Open-Meteo's answer to a Forecast. Pure, so the self-test can check it. Nil for anything that isn't a forecast.
func parseForecast(_ data: Data) -> Forecast? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let d = j["daily"] as? [String: Any], let h = j["hourly"] as? [String: Any],
          let dt = d["time"] as? [String], let dc = d["weather_code"] as? [Any], let hi = d["temperature_2m_max"] as? [Any],
          let lo = d["temperature_2m_min"] as? [Any], let dr = d["precipitation_probability_max"] as? [Any],
          let ht = h["time"] as? [String], let hc = h["weather_code"] as? [Any], let tt = h["temperature_2m"] as? [Any],
          let hr = h["precipitation_probability"] as? [Any], let hw = h["wind_speed_10m"] as? [Any] else { return nil }
    func num(_ a: [Any], _ i: Int) -> Double? { i < a.count ? (a[i] as? NSNumber)?.doubleValue : nil }  // a gap comes back as null
    var f = Forecast()
    for (i, t) in dt.enumerated() {
        guard let c = num(dc, i), let a = num(hi, i), let b = num(lo, i) else { continue }
        f.days[t] = WxDay(code: Int(c), hi: a, lo: b, rain: Int(num(dr, i) ?? 0))
    }
    for (i, t) in ht.enumerated() {
        guard let c = num(hc, i), let a = num(tt, i) else { continue }
        f.hours[t] = WxHour(code: Int(c), temp: a, rain: Int(num(hr, i) ?? 0), wind: num(hw, i) ?? 0)
    }
    return f.days.isEmpty ? nil : f
}

/// WMO weather code to an SF Symbol and plain words.
func wxLook(_ code: Int) -> (symbol: String, words: String) {
    switch code {
    case 0: return ("sun.max.fill", "Clear")
    case 1, 2: return ("cloud.sun.fill", "Partly cloudy")
    case 3: return ("cloud.fill", "Cloudy")
    case 45, 48: return ("cloud.fog.fill", "Fog")
    case 51...57: return ("cloud.drizzle.fill", "Drizzle")
    case 61...67, 80...82: return ("cloud.rain.fill", code == 61 || code == 80 ? "Light rain" : "Rain")
    case 71...77, 85, 86: return ("cloud.snow.fill", "Snow")
    case 95...99: return ("cloud.bolt.rain.fill", "Thunderstorms")
    default: return ("cloud.fill", "Cloudy")
    }
}

/// The weather icon: grey cloud (multicolor's white cloud vanishes on the light look), yellow sun, blue rain.
struct WxIcon: View {
    let code: Int
    var body: some View {
        let sym = wxLook(code).symbol
        let tint: Color = sym.contains("rain") || sym.contains("drizzle") || sym.contains("snow") ? .blue : sym.contains("fog") ? Palette.text3 : .yellow
        if sym.hasPrefix("cloud") { Image(systemName: sym).symbolRenderingMode(.palette).foregroundStyle(Palette.text3, tint) }
        else { Image(systemName: sym).foregroundStyle(tint) }
    }
}

/// A temperature in the chosen unit, rounded: "29°".
func degrees(_ c: Double, fahrenheit: Bool = WeatherPrefs.fahrenheit) -> String { "\(Int((fahrenheit ? c * 9 / 5 + 32 : c).rounded()))°" }

func wxDayKey(_ d: Date) -> String { dateText(d, "yyyy-MM-dd") }
func wxHourKey(_ d: Date) -> String { dateText(d, "yyyy-MM-dd'T'HH:00") }

@MainActor
final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()
    static var sample = false  // --sample and the off-screen pictures
    @Published private(set) var forecasts: [String: Forecast] = [:]
    private var fetched: [String: Date] = [:]  // when to ask again
    private var busy: Set<String> = []

    /// Rounded to about 1 km, so nearby places share one forecast.
    private func key(_ g: Geo) -> String { String(format: "%.2f,%.2f", g.lat, g.lon) }

    /// The forecast for a spot; starts a fetch when there is none or it is over an hour old.
    func forecast(_ g: Geo) -> Forecast? {
        let k = key(g)
        if Self.sample { return Self.made }
        if busy.contains(k) == false, (fetched[k].map { Date() > $0 } ?? true) { load(g, k) }
        return forecasts[k]
    }

    private func load(_ g: Geo, _ k: String) {
        busy.insert(k)
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [.init(name: "latitude", value: String(format: "%.2f", g.lat)), .init(name: "longitude", value: String(format: "%.2f", g.lon)),
                        .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                        .init(name: "hourly", value: "weather_code,temperature_2m,precipitation_probability,wind_speed_10m"),
                        .init(name: "timezone", value: cal.timeZone.identifier), .init(name: "forecast_days", value: "16")]
        Task {
            let got = try? await URLSession.shared.data(from: u.url!)
            busy.remove(k)
            if let got, (got.1 as? HTTPURLResponse)?.statusCode == 200, let f = parseForecast(got.0) { forecasts[k] = f; fetched[k] = Date().addingTimeInterval(3600) }
            else { fetched[k] = Date().addingTimeInterval(300) }  // a dead network is asked again in 5 minutes, not on every redraw
        }
    }

    /// The made-up week the mockups show (Tamarindo, late October).
    static let made: Forecast = {
        var f = Forecast()
        let start = sampleToday.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        let week: [(Int, Double, Double, Int)] = [(2, 31, 24, 10), (61, 29, 24, 70), (0, 32, 24, 0), (95, 28, 23, 80), (2, 30, 24, 20), (0, 32, 25, 0), (61, 29, 24, 60)]
        for i in -3..<16 {
            let d = addDays(start, i), w = week[((i % 7) + 7) % 7]
            f.days[wxDayKey(d)] = WxDay(code: w.0, hi: w.1, lo: w.2, rain: w.3)
            for h in 0..<24 {
                let t = cal.date(byAdding: .hour, value: h, to: d)!
                let wet = w.3 > 40 && h >= 14
                f.hours[wxHourKey(t)] = WxHour(code: wet ? 61 : (h < 6 || h > 18 ? 0 : w.0 == 0 ? 0 : 2), temp: w.2 + (w.1 - w.2) * max(0, sin(Double(h - 6) / 12 * .pi)), rain: wet ? w.3 : w.3 / 4, wind: 12)
            }
        }
        return f
    }()
}

/// Where the day headers' weather is for: the town picked in Settings, else where the Mac is.
@MainActor func headerSpot() -> Geo? { WeatherPrefs.town.isEmpty ? Here.shared.spot : WeatherPrefs.townGeo }

/// The icon with the high and low under a day's name. Hover for the day hour by hour.
struct WxChip: View {
    let day: Date, at: Geo
    @ObservedObject private var wx = WeatherStore.shared
    @State private var hover = false
    var body: some View {
        if let f = wx.forecast(at), let d = f.days[wxDayKey(day)] {
            HStack(spacing: 3) {
                WxIcon(code: d.code).font(.ui(11))
                Text(degrees(d.hi)).foregroundStyle(Palette.text2)
                Text(degrees(d.lo)).foregroundStyle(Palette.text3)
            }
            .font(.ui(11)).monospacedDigit().fixedSize()
            .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 4).fill(hover ? Palette.accentSoft : .clear))
            .onHover { hover = $0 }
            .popover(isPresented: $hover, arrowEdge: .bottom) { WxHours(day: day, f: f, d: d) }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(wxLook(d.code).words), high \(degrees(d.hi)), low \(degrees(d.lo))")
        }
    }
}

struct WxHours: View {
    let day: Date, f: Forecast, d: WxDay
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dateText(day, "EEEE") + (WeatherPrefs.town.isEmpty ? "" : ", " + WeatherPrefs.town)).font(.ui(12, weight: .semibold))
            Text(wxLook(d.code).words + (d.rain > 0 ? ", \(d.rain)% chance of rain" : "")).font(.ui(11.5)).foregroundStyle(Palette.text3)
            ForEach([6, 9, 12, 15, 18, 21], id: \.self) { h in
                let t = cal.date(byAdding: .hour, value: h, to: cal.startOfDay(for: day))!
                if let w = f.hours[wxHourKey(t)] {
                    HStack(spacing: 6) {
                        Text(timeText(t, short: true)).frame(width: 44, alignment: .leading)
                        WxIcon(code: w.code).frame(width: 18)
                        Text(degrees(w.temp)).frame(width: 34, alignment: .leading)
                        Text("\(w.rain)%").foregroundStyle(Palette.text3)
                    }.font(.ui(11.5)).monospacedDigit()
                }
            }
        }
        .padding(12).frame(width: 220, alignment: .leading)
    }
}

/// In the event panel under the map: the forecast at the place, at the event's start.
struct WxAtPlace: View {
    let geo: Geo, start: Date, allDay: Bool
    @ObservedObject private var wx = WeatherStore.shared
    var body: some View {
        if WeatherPrefs.on, let f = wx.forecast(geo) {
            let h = allDay ? nil : f.hours[wxHourKey(start)]
            if let d = f.days[wxDayKey(start)] {
                let code = h?.code ?? d.code
                HStack(spacing: 10) {
                    WxIcon(code: code).font(.system(size: 24)).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.map { "\(degrees($0.temp)), \(wxLook(code).words.lowercased()) at \(timeText(start))" } ?? "\(wxLook(code).words), high \(degrees(d.hi)), low \(degrees(d.lo))")
                        Text("\(h?.rain ?? d.rain)% chance of rain" + (h.map { " · wind \(Int($0.wind.rounded())) km/h" } ?? ""))
                            .font(.ui(11)).foregroundStyle(Palette.text3)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                .padding(.top, 8)
            }
        }
    }
}

/// Settings, Weather tab.
struct WeatherSettings: View {
    @ObservedObject var app: AppState
    @State private var on = WeatherPrefs.on
    @State private var f = WeatherPrefs.fahrenheit
    @State var town = WeatherPrefs.town
    @State private var note = ""
    @State var found: [Town] = []
    @State private var foundFor = ""  // the text `found` answers
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show the weather on days and events", isOn: Binding(get: { on }, set: { on = $0; WeatherPrefs.on = $0; changed() })).toggleStyle(.switch).controlSize(.small)
            HStack {
                Text("Temperature")
                Seg(options: ["Celsius", "Fahrenheit"], selected: f ? "Fahrenheit" : "Celsius", small: true) { f = $0 == "Fahrenheit"; WeatherPrefs.fahrenheit = f; changed() }.fixedSize()
            }.disabled(!on)
            HStack(alignment: .top) {
                Text("Town for the days").padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Where this Mac is", text: $town).textFieldStyle(.roundedBorder).frame(width: 260)
                        .onSubmit { if let t = found.first, foundFor == town.trimmingCharacters(in: .whitespaces) { pick(t) } else if town.trimmingCharacters(in: .whitespaces).isEmpty { pick(nil) } }
                    // Matches as you type (as in LifeWorld), from Open-Meteo's free town search.
                    ForEach(found) { t in
                        Button { pick(t) } label: { Text(t.label).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    }
                }.frame(width: 260)
            }.disabled(!on)
            .task(id: town) {
                guard !WeatherStore.sample else { return }  // the pictures never reach the network
                let t = town.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t == WeatherPrefs.town { found = []; note = ""; if t.isEmpty, !WeatherPrefs.town.isEmpty { pick(nil) }; return }
                try? await Task.sleep(for: .milliseconds(300))  // wait for a pause in the typing
                guard !Task.isCancelled else { return }
                let list = await searchTowns(t)
                guard !Task.isCancelled else { return }  // the text changed while this search ran
                found = list; foundFor = t
                note = found.isEmpty ? "No town called \u{201C}\(t)\u{201D} found. Try another spelling." : ""
            }
            Text(note.isEmpty ? "Leave it empty to use where this Mac is. Events with a place always show the weather at that place." : note)
                .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Link("Weather data by Open-Meteo.com", destination: URL(string: "https://open-meteo.com/")!).font(.system(size: 11.5))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 620)
    }

    /// nil = back to where this Mac is.
    func pick(_ t: Town?) {
        WeatherPrefs.town = t?.label ?? ""; WeatherPrefs.townGeo = t?.geo
        town = WeatherPrefs.town; found = []; note = ""
        changed()
    }

    // The weather pieces watch the weather store, not the window, so both are told (a unit change showed only after a restart).
    func changed() { app.objectWillChange.send(); WeatherStore.shared.objectWillChange.send() }
}

struct Town: Identifiable, Equatable { var label: String, geo: Geo; var id: String { label + "\(geo.lat),\(geo.lon)" } }

/// Open-Meteo's town search: up to 8 matches, "Tamarindo, Guanacaste, Costa Rica". Empty on any failure.
func searchTowns(_ text: String) async -> [Town] {
    var u = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    u.queryItems = [.init(name: "name", value: String(text.prefix(80))), .init(name: "count", value: "8"), .init(name: "language", value: "en"), .init(name: "format", value: "json")]
    guard let (data, _) = try? await URLSession.shared.data(from: u.url!) else { return [] }
    return parseTowns(data)
}

/// Pure, so the self-test can check it.
func parseTowns(_ data: Data) -> [Town] {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = j["results"] as? [[String: Any]] else { return [] }
    var seen = Set<String>()
    return r.compactMap { x in
        guard let name = x["name"] as? String, let lat = x["latitude"] as? Double, let lon = x["longitude"] as? Double else { return nil }
        var parts = [name]
        for k in ["admin1", "country"] { if let v = x[k] as? String, !v.isEmpty, !parts.contains(v) { parts.append(v) } }
        let label = parts.joined(separator: ", ")
        return seen.insert(label).inserted ? Town(label: label, geo: Geo(lat: lat, lon: lon)) : nil
    }
}

func weatherSelftest(_ expect: (Bool, String) -> Void) {
    let json = #"{"daily":{"time":["2026-10-30","2026-10-31"],"weather_code":[61,null],"temperature_2m_max":[29.4,33],"temperature_2m_min":[24.2,24.9],"precipitation_probability_max":[70,null]},"hourly":{"time":["2026-10-30T15:00"],"weather_code":[61],"temperature_2m":[27.6],"precipitation_probability":[70],"wind_speed_10m":[12.1]}}"#
    let f = parseForecast(Data(json.utf8))
    expect(f?.days["2026-10-30"] == WxDay(code: 61, hi: 29.4, lo: 24.2, rain: 70), "weather: a day is read from Open-Meteo's answer")
    expect(f?.days["2026-10-31"] == nil, "weather: a day with a gap in the answer is left out, not shown as 0")
    expect(f?.hours["2026-10-30T15:00"]?.temp == 27.6, "weather: an hour is read")
    expect(parseForecast(Data(#"{"error":true,"reason":"bad"}"#.utf8)) == nil, "weather: an error answer is no forecast")
    let towns = parseTowns(Data(#"{"results":[{"name":"Tamarindo","latitude":10.3,"longitude":-85.84,"admin1":"Guanacaste","country":"Costa Rica"},{"name":"Tamarindo","latitude":10.3,"longitude":-85.84,"admin1":"Guanacaste","country":"Costa Rica"},{"name":"Panama","latitude":9,"longitude":-79.5,"country":"Panama"}]}"#.utf8))
    expect(towns.map(\.label) == ["Tamarindo, Guanacaste, Costa Rica", "Panama"], "weather: town matches, repeats and doubled names dropped")
    expect(parseTowns(Data("{}".utf8)).isEmpty, "weather: no matches is an empty list")
    expect(degrees(29.4, fahrenheit: false) == "29°" && degrees(29.4, fahrenheit: true) == "85°", "weather: Celsius and Fahrenheit")
    expect(wxLook(0).symbol == "sun.max.fill" && wxLook(95).words == "Thunderstorms" && wxLook(61).words == "Light rain", "weather: codes to words")
}
