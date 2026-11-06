// The phone mockups' colours and the grouped rows every screen uses.
import SwiftUI
import UIKit
import DatelineCore

enum T {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        func ui(_ v: UInt32) -> UIColor { UIColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
    static let bg = c(0xFFFFFF, 0x000000), bg2 = c(0xF2F2F7, 0x1C1C1E)
    static let text = c(0x1C1C1E, 0xF2F2F7), text2 = c(0x636366, 0xA1A1A6), line = c(0xE5E5EA, 0x2C2C2E)
    static let accent = c(0xD93A30, 0xFF5A4F), tint = c(0x0A64D6, 0x4C9BFF), late = c(0xC4321F, 0xFF6B5A)
    static let grouped = c(0xF2F2F7, 0x000000), card = c(0xFFFFFF, 0x1C1C1E)  // grouped screens: white cards on grey (2026-11-06 design)
}

/// "DETAILS" above a group of rows.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(T.text2)
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 6)
    }
}

/// A rounded group of rows.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(T.card, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
    }
}

/// One row in a Card: a grey label and its value; a line under it unless it is the last.
struct Row<Value: View>: View {
    var label = ""
    var last = false
    @ViewBuilder let value: Value
    var body: some View {
        HStack(spacing: 12) {
            if !label.isEmpty { Text(label).foregroundStyle(T.text2).frame(width: 80, alignment: .leading) }
            value
            Spacer(minLength: 0)
        }
        .font(.callout).padding(.horizontal, 16).frame(minHeight: 44)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(T.line).frame(height: 1).padding(.leading, 16) } }
    }
}

/// The coloured bar beside an event's name.
struct Bar: View {
    let color: Color
    var height: CGFloat = 28
    var body: some View { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: height) }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 10
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

extension View {
    /// The floating glass look of the Undo banner and the places search box.
    func glass() -> some View { background(.ultraThinMaterial, in: Capsule()).shadow(color: .black.opacity(0.14), radius: 8, y: 2) }
}
