// Phase 8: the weather forecast on each day header and at an event's place, from Open-Meteo (free for an app that
// isn't sold, no sign-up; it asks for the "Weather data by Open-Meteo.com" line, which is in the Weather settings).
// About 16 days ahead; further out shows nothing. Sample mode and the off-screen pictures use made-up weather, never the network.
import SwiftUI
import CoreLocation
import DatelineCore

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

/// The icon with the high and low under a day's name. Hover for the day hour by hour.
struct WxChip: View {
    let day: Date, at: Geo
    @ObservedObject private var wx = WeatherStore.shared
    @State private var hover = false
    var body: some View {
        if let f = wx.forecast(at), let d = f.days[wxDayKey(day)] {
            HStack(spacing: 4) {
                WxIcon(code: d.code).font(.ui(11))
                Text(degrees(d.hi)).foregroundStyle(Palette.text2)
                Text(degrees(d.lo)).foregroundStyle(Palette.text3)
            }
            .font(.ui(11)).monospacedDigit().fixedSize()
            .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 4).fill(hover ? Palette.accentSoft : .clear))
            .onHover { hover = $0 }
            .popover(isPresented: $hover, arrowEdge: .bottom) { WxHours(day: day, f: f, d: d) }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(wxLook(d.code).words), high \(degrees(d.hi)), low \(degrees(d.lo))")
        }
    }
}

struct WxHours: View {
    let day: Date, f: Forecast, d: WxDay
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateText(day, "EEEE") + (WeatherPrefs.town.isEmpty ? "" : ", " + WeatherPrefs.town)).font(.ui(12, weight: .semibold))
            Text(wxLook(d.code).words + (d.rain > 0 ? ", \(d.rain)% chance of rain" : "")).font(.ui(12)).foregroundStyle(Palette.text3)
            ForEach([6, 9, 12, 15, 18, 21], id: \.self) { h in
                let t = cal.date(byAdding: .hour, value: h, to: cal.startOfDay(for: day))!
                if let w = f.hours[wxHourKey(t)] {
                    HStack(spacing: 8) {
                        Text(timeText(t, short: true)).frame(width: 44, alignment: .leading)
                        WxIcon(code: w.code).frame(width: 20)
                        Text(degrees(w.temp)).frame(width: 36, alignment: .leading)
                        Text("\(w.rain)%").foregroundStyle(Palette.text3)
                    }.font(.ui(12)).monospacedDigit()
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
                HStack(spacing: 12) {
                    WxIcon(code: code).font(.system(size: 24)).frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.map { "\(degrees($0.temp)), \(wxLook(code).words.lowercased()) at \(timeText(start))" } ?? "\(wxLook(code).words), high \(degrees(d.hi)), low \(degrees(d.lo))")
                        Text("\(h?.rain ?? d.rain)% chance of rain" + (h.map { " · wind \(Int($0.wind.rounded())) km/h" } ?? ""))
                            .font(.ui(11)).foregroundStyle(Palette.text3)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
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
                        Button { pick(t) } label: { Text(t.label).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }
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
                .font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Link("Weather data by Open-Meteo.com", destination: URL(string: "https://open-meteo.com/")!).font(.system(size: 12))
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

