// Look settings (approved Phase 3 mockup): light or dark, font, text size, how packed, hour height. Saved on this Mac.
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public enum Look {
    public static let appearances = ["Match Mac", "Light", "Dark"], fonts = ["System", "Rounded", "Serif", "Mono"]
    public static let packs = ["Roomy", "Normal", "Compact"], hours = ["Short", "Medium", "Tall"]
    private static let d = UserDefaults.standard
    public static let synced = Notification.Name("DatelineLookSynced")  // a Look or sound choice arrived from the other device
    public static var saves = true  // off for the off-screen pictures, so they never change your settings
    public static var appearance = pick("lookAppearance", appearances, "Match Mac") { didSet { if saves { d.set(appearance, forKey: "lookAppearance") }; apply() } }
    public static var font = pick("lookFont", fonts, "System") { didSet { if saves { d.set(font, forKey: "lookFont") } } }
    public static var scale = min(1.25, max(0.85, d.object(forKey: "lookScale") as? Double ?? 1)) { didSet { if saves { d.set(scale, forKey: "lookScale") } } }
    public static var pack = pick("lookPack", packs, "Normal") { didSet { if saves { d.set(pack, forKey: "lookPack") } } }
    public static var hour = pick("lookHour", hours, "Medium") { didSet { if saves { d.set(hour, forKey: "lookHour") } } }

    private static func pick(_ key: String, _ list: [String], _ def: String) -> String {
        d.string(forKey: key).flatMap { list.contains($0) ? $0 : nil } ?? def
    }

    public static var design: Font.Design { ["Rounded": .rounded, "Serif": .serif, "Mono": .monospaced][font] ?? .default }
    // Roomy spreads rows out, Compact squeezes them (also the hour rows, so a working day fits without scrolling).
    public static var packFactor: CGFloat { ["Roomy": 1.2, "Compact": 0.8][pack] ?? 1 }
    public static var hourHeight: CGFloat { (["Short": 42, "Tall": 72][hour] ?? 56) * packFactor }

    public static func apply() {
        #if os(macOS)
        NSApp?.appearance = appearance == "Light" ? NSAppearance(named: .aqua) : appearance == "Dark" ? NSAppearance(named: .darkAqua) : nil
        #endif
    }

    // Reads them again after the other device's choice arrived (step 2 sync).
    public static func reload() { appearance = pick("lookAppearance", appearances, "Match Mac"); font = pick("lookFont", fonts, "System"); scale = min(1.25, max(0.85, d.object(forKey: "lookScale") as? Double ?? 1)); pack = pick("lookPack", packs, "Normal"); hour = pick("lookHour", hours, "Medium") }

    // Back to the defaults, for the off-screen pictures.
    public static func reset() { saves = false; scale = 1; font = "System"; pack = "Normal"; hour = "Medium" }
}

extension Font {
    // Every text size in the app goes through here so the Look settings reach all of it.
    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size * Look.scale, weight: weight, design: Look.design) }
}

