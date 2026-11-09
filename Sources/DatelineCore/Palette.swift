// The colours and sizes shared by the Mac and iPhone screens, from the approved mockups.
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public enum Palette {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        #if os(macOS)
        func ns(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
        #else
        func ui(_ v: UInt32) -> UIColor { UIColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
        #if os(watchOS)
        return Color(uiColor: ui(dark))  // the watch is always dark
        #else
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
        #endif
        #endif
    }
    public static let win = c(0xffffff, 0x1e1e22), side = c(0xf3f3f6, 0x26262b), bar = c(0xf8f8fa, 0x232327)
    public static let line = c(0xe2e2e7, 0x36363d), lineSoft = c(0xefeff3, 0x2b2b31)
    public static let text = c(0x1d1d22, 0xececf1), text2 = c(0x5e5e68, 0xa8a8b3), text3 = c(0x8d8d97, 0x75757f)
    public static let accent = c(0x2f6fde, 0x5b8ff0), accentSoft = c(0xe6eefc, 0x263552), now = c(0xe5484d, 0xe5484d)
    public static let field = c(0xffffff, 0x2c2c32), pop = c(0xffffff, 0x2a2a30)
    public static let work = c(0x2f6fde, 0x5b8ff0), personal = c(0x2e9d5b, 0x4cbb7a), family = c(0xd9822b, 0xeb9a4a)
    // Event colors and tag dots (Phase 3): red, amber, green, teal, blue, purple, pink, gray.
    public static let tags = [c(0xe5484d, 0xec5d61), c(0xd9822b, 0xeb9a4a), c(0x2e9d5b, 0x4cbb7a), c(0x1a9aa8, 0x3cb8c5),
                       c(0x2f6fde, 0x5b8ff0), c(0x8b5cd6, 0xa47be6), c(0xd9478a, 0xe66aa3), c(0x7d7d88, 0x9a9aa5)]
    // A tag keeps the same color everywhere: picked from its letters.
    public static func tag(_ name: String) -> Color { tags[name.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) } % tags.count] }
}

extension Store {
    // The event's own color if one was picked, else its calendar's.
    public func color(_ it: Item) -> Color { it.color.flatMap { Palette.tags.indices.contains($0) ? Palette.tags[$0] : nil } ?? calendar(it.calendarID)?.color ?? .gray }
}

