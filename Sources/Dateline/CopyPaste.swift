// Copy, Paste and Duplicate for events (approved Repeat and Copy mockup, 2026-11-20). Their keys can be changed or
// cleared in Settings, as every shortcut in John's apps can (John, 2026-11-19).
import SwiftUI
import DatelineCore

enum EventAction: String, CaseIterable { case copy = "Copy event", paste = "Paste event", duplicate = "Duplicate event" }

struct Shortcut: Equatable {
    var char: String  // lowercase, as the key's own character
    var mods: NSEvent.ModifierFlags
    static let order: [(NSEvent.ModifierFlags, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
    var name: String { (Self.order.filter { mods.contains($0.0) }.map(\.1) + [char.uppercased()]).joined(separator: " ") }
    var swiftUI: KeyboardShortcut {
        let m: [(NSEvent.ModifierFlags, EventModifiers)] = [(.control, .control), (.option, .option), (.shift, .shift), (.command, .command)]
        return KeyboardShortcut(KeyEquivalent(Character(char)), modifiers: EventModifiers(m.filter { mods.contains($0.0) }.map(\.1)))
    }
    init(_ char: String, _ mods: NSEvent.ModifierFlags) { self.char = char.count == 1 ? char : ""; self.mods = mods.intersection([.command, .option, .control, .shift]) }
    init(_ e: NSEvent) { self.init((e.charactersIgnoringModifiers ?? "").lowercased(), e.modifierFlags) }
}

@MainActor
final class EventKeys: ObservableObject {
    static let shared = EventKeys()
    static let defaults: [EventAction: Shortcut] = [.copy: Shortcut("c", .command), .paste: Shortcut("v", .command), .duplicate: Shortcut("d", .command)]
    // The app's own fixed menu keys and the Mac's usual ones, which a new pick may not take.
    static let taken: [Shortcut] = ["n", "t", "z", "f", "q", "w", "h", "m", ",", "/", "x", "a", "s", "o"].map { Shortcut($0, .command) } + (1...9).map { Shortcut("\($0)", .command) }
        + (1...5).map { Shortcut("\($0)", [.option, .command]) } + ["r", "p"].map { Shortcut($0, [.option, .command]) } + [Shortcut("/", [.shift, .command])]

    @Published private(set) var keys: [EventAction: Shortcut] = [:]
    @Published var recording: EventAction?
    @Published var refused: EventAction?  // the key just pressed is already in use

    init() {
        let d = UserDefaults.standard
        for a in EventAction.allCases {
            if d.bool(forKey: "key.\(a).cleared") { continue }
            if let c = d.string(forKey: "key.\(a).char"), c.count == 1 { keys[a] = Shortcut(c, NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "key.\(a).mods")))) }
            else { keys[a] = Self.defaults[a] }
        }
    }

    func action(for e: NSEvent) -> EventAction? { let s = Shortcut(e); return keys.first { $0.value == s }?.key }
    func shortcut(_ a: EventAction) -> KeyboardShortcut? { keys[a]?.swiftUI }
    // In the menu bar a key that is also Edit's Copy or Paste would fire while typing in a field with nothing to copy; the key handler takes those instead.
    func menuShortcut(_ a: EventAction) -> KeyboardShortcut? { keys[a].flatMap { ["c", "v"].contains($0.char) && $0.mods == .command ? nil : $0.swiftUI } }

    // Needs Command, Control or Option; refused when the app or another of these already uses it.
    @discardableResult
    func set(_ a: EventAction, _ s: Shortcut?) -> Bool {
        if let s {
            guard !s.char.isEmpty, !s.mods.intersection([.command, .control, .option]).isEmpty,
                  !Self.taken.contains(s), !keys.contains(where: { $0.key != a && $0.value == s }) else { refused = a; return false }
        }
        refused = nil
        keys[a] = s
        let d = UserDefaults.standard
        d.set(s == nil, forKey: "key.\(a).cleared")
        d.set(s?.char ?? "", forKey: "key.\(a).char")
        d.set(Int(s?.mods.rawValue ?? 0), forKey: "key.\(a).mods")
        return true
    }
}

extension AppState {
    func copyEvent(_ it: Item? = nil) { if let s = it ?? selected { clip = s } }

    // On the spot last clicked: an hour in day or week view, or a day in month view at the copy's own time of day.
    func paste(on day: Date? = nil) {
        guard let c = clip else { return }
        let spot = day.map { d in pasteSpot.flatMap { cal.isDate($0.day, inSameDayAs: d) ? $0 : nil } ?? (day: d, time: false) } ?? pasteSpot ?? (day: anchor, time: false)
        let len = c.end.timeIntervalSince(c.start)
        var m = c
        if c.allDay { m.start = cal.startOfDay(for: spot.day) }
        else if spot.time { m.start = spot.day }
        else { let t = cal.dateComponents([.hour, .minute], from: c.start); m.start = cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: spot.day) ?? spot.day }
        m.end = c.allDay ? addDays(m.start, cal.dateComponents([.day], from: c.start, to: c.end).day ?? 1) : m.start.addingTimeInterval(len)  // whole days across a clock change
        copy(m)
    }

    // The copy starts right when the original ends.
    func duplicateEvent(_ it: Item? = nil) {
        guard let s = it ?? selected else { return }
        var m = s
        m.start = s.end; m.end = s.allDay ? addDays(s.end, cal.dateComponents([.day], from: s.start, to: s.end).day ?? 1) : s.end.addingTimeInterval(s.end.timeIntervalSince(s.start))
        copy(m)
    }

    func runEventKey(_ a: EventAction) -> Bool {
        switch a {
        case .copy: guard selected != nil else { return false }; copyEvent()
        case .paste: guard clip != nil else { return false }; paste()
        case .duplicate: guard selected != nil else { return false }; duplicateEvent()
        }
        return true
    }
}

// Right-click on an event.
struct EventMenu: View {
    @ObservedObject var app: AppState
    @ObservedObject var keys = EventKeys.shared
    let it: Item
    var body: some View {
        Button("Copy") { app.copyEvent(it) }.keyboardShortcut(keys.shortcut(.copy))
        Button("Duplicate") { app.duplicateEvent(it) }.keyboardShortcut(keys.shortcut(.duplicate))
    }
}

// Right-click on an empty spot in a day.
struct PasteMenu: View {
    @ObservedObject var app: AppState
    @ObservedObject var keys = EventKeys.shared
    let day: Date
    var body: some View {
        Button(app.clip.map { "Paste \u{201C}\($0.shownTitle)\u{201D} Here" } ?? "Paste Here") { app.paste(on: day) }.disabled(app.clip == nil)
    }
}

struct EventKeySettings: View {
    @ObservedObject var keys = EventKeys.shared
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(EventAction.allCases, id: \.self) { a in
                HStack {
                    Text(a.rawValue)
                    Spacer()
                    Text(keys.recording == a ? "Press the new shortcut" : keys.keys[a]?.name ?? "None").foregroundStyle(keys.recording == a ? Palette.accent : Palette.text)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Palette.field))
                    Button(keys.recording == a ? "Cancel" : "Change…") { keys.recording == a ? stop() : record(a) }
                    Button("Clear") { keys.set(a, nil) }.disabled(keys.keys[a] == nil)
                    Button("Reset") { keys.set(a, EventKeys.defaults[a]) }.disabled(keys.keys[a] == EventKeys.defaults[a])
                }
            }
            Text(keys.refused != nil ? "That shortcut is already used in Dateline. Pick a different one." : keys.recording != nil ? "Press Command, Control or Option with a key. Esc cancels." : "Paste puts the copy on the day or hour you last clicked.")
                .font(.ui(12)).foregroundStyle(keys.refused != nil ? Palette.now : Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 440)
        .onDisappear { stop() }
        .font(.ui(13))
    }

    func record(_ a: EventAction) {
        stop()
        keys.recording = a
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode != 53 { keys.set(a, Shortcut(e)) }
            stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        keys.recording = nil
    }
}
