// Look settings (approved Phase 3 mockup): light or dark, font, text size, how packed, hour height. Saved on this Mac.
import SwiftUI
import AppKit

enum Look {
    static let appearances = ["Match Mac", "Light", "Dark"], fonts = ["System", "Rounded", "Serif", "Mono"]
    static let packs = ["Roomy", "Normal", "Compact"], hours = ["Short", "Medium", "Tall"]
    private static let d = UserDefaults.standard
    static var saves = true  // off for the off-screen pictures, so they never change your settings
    static var appearance = pick("lookAppearance", appearances, "Match Mac") { didSet { if saves { d.set(appearance, forKey: "lookAppearance") }; apply() } }
    static var font = pick("lookFont", fonts, "System") { didSet { if saves { d.set(font, forKey: "lookFont") } } }
    static var scale = min(1.25, max(0.85, d.object(forKey: "lookScale") as? Double ?? 1)) { didSet { if saves { d.set(scale, forKey: "lookScale") } } }
    static var pack = pick("lookPack", packs, "Normal") { didSet { if saves { d.set(pack, forKey: "lookPack") } } }
    static var hour = pick("lookHour", hours, "Medium") { didSet { if saves { d.set(hour, forKey: "lookHour") } } }

    private static func pick(_ key: String, _ list: [String], _ def: String) -> String {
        d.string(forKey: key).flatMap { list.contains($0) ? $0 : nil } ?? def
    }

    static var design: Font.Design { ["Rounded": .rounded, "Serif": .serif, "Mono": .monospaced][font] ?? .default }
    // Roomy spreads rows out, Compact squeezes them (also the hour rows, so a working day fits without scrolling).
    static var packFactor: CGFloat { ["Roomy": 1.2, "Compact": 0.8][pack] ?? 1 }
    static var hourHeight: CGFloat { (["Short": 42, "Tall": 72][hour] ?? 56) * packFactor }

    static func apply() {
        NSApp?.appearance = appearance == "Light" ? NSAppearance(named: .aqua) : appearance == "Dark" ? NSAppearance(named: .darkAqua) : nil
    }

    // Back to the defaults, for the off-screen pictures.
    static func reset() { saves = false; scale = 1; font = "System"; pack = "Normal"; hour = "Medium" }
}

extension Font {
    // Every text size in the app goes through here so the Look settings reach all of it.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size * Look.scale, weight: weight, design: Look.design) }
}

// The Look tab in Settings (approved Phase 3 mockup). Every choice applies at once; the preview on the right follows it.
struct LookSettings: View {
    @ObservedObject var app: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                row("Appearance") { Seg(options: Look.appearances, selected: Look.appearance, small: true) { Look.appearance = $0; app.look += 1 } }
                row("Font") {
                    HStack(spacing: 6) {
                        ForEach(Look.fonts, id: \.self) { f in
                            let on = f == Look.font
                            Button { Look.font = f; app.look += 1 } label: {
                                VStack(spacing: 2) {
                                    Text("Aa").font(.system(size: 17, design: ["Rounded": .rounded, "Serif": .serif, "Mono": .monospaced][f] ?? .default))
                                    Text(f).font(.system(size: 10.5)).foregroundStyle(Palette.text2)
                                }.frame(width: 58, height: 48)
                                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Palette.accentSoft : Palette.field))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Palette.accent : Palette.line, lineWidth: on ? 1.5 : 1))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                row("Text size") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("A").font(.system(size: 11))
                            Slider(value: Binding(get: { Look.scale }, set: { Look.scale = ($0 * 20).rounded() / 20; app.look += 1 }), in: 0.85...1.25)
                            Text("A").font(.system(size: 17))
                        }
                        HStack { Text("Small"); Spacer(); Text("Normal"); Spacer(); Text("Large") }.font(.system(size: 10.5)).foregroundStyle(Palette.text3).padding(.horizontal, 16)
                    }.frame(width: 250)
                }
                row("How packed") { Seg(options: Look.packs, selected: Look.pack, small: true) { Look.pack = $0; app.look += 1 } }
                row("Hour height") { Seg(options: Look.hours, selected: Look.hour, small: true) { Look.hour = $0; app.look += 1 } }
                Text("Compact fits a full working day, 8 AM to 6 PM, on the screen without scrolling.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 370, alignment: .leading)
            LookPreview().id(app.look)
        }
        .font(.system(size: 13))
        .padding(20).frame(width: 690)
    }

    // The settings themselves keep the normal size, so the window does not jump while you pick.
    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 96, alignment: .leading).padding(.top, 3)
            v()
        }
    }
}

// Two days of the week view, drawn with the picked font, size, packing and hour height.
struct LookPreview: View {
    var body: some View {
        let h = Look.hourHeight * 0.62, hours = [11, 12, 13, 14, 15]
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 44, height: 1)
                ForEach(["Tue 27", "Wed 28"], id: \.self) { d in Text(d).font(.ui(11.5, weight: .semibold)).foregroundStyle(Palette.text2).frame(maxWidth: .infinity).padding(.vertical, 5 * Look.packFactor) }
            }.overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { hr in
                        HStack(alignment: .top, spacing: 0) {
                            Text(hr == 12 ? "12 PM" : "\(hr % 12) \(hr < 12 ? "AM" : "PM")").font(.ui(10)).foregroundStyle(Palette.text3).frame(width: 40, alignment: .trailing).padding(.trailing, 4).offset(y: -6)
                            VStack { Palette.lineSoft.frame(height: 1); Spacer(minLength: 0) }
                        }.frame(height: h)
                    }
                }
                GeometryReader { g in
                    let col = (g.size.width - 44) / 2
                    block("🏠 Christian at the condo", "11:30 AM", Palette.family).frame(width: col - 6, height: h * 0.5 - 2).offset(x: 47, y: h * 0.5 + 1)
                    block("Client call", "12 to 1 PM", Palette.work).frame(width: col - 6, height: h - 2).offset(x: 47 + col, y: h + 1)
                }
            }.frame(height: h * CGFloat(hours.count)).padding(.top, 8).clipped()
        }
        .background(Palette.win)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .frame(width: 260)
    }

    func block(_ title: String, _ time: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.ui(11, weight: .semibold)).lineLimit(1)
            Text(time).font(.ui(10)).foregroundStyle(Palette.text2).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 3 * Look.packFactor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.16)))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
