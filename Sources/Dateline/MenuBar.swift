// Phase 6 (approved mockup, 2026-10-28): the menu bar icon and its menu of today's events and tasks. Saved on this Mac.
import SwiftUI
import AppKit

enum MenuIcon {
    static let shows = ["Calendar icon with today's date", "Day and date", "Week number", "What's next"]
    private static let d = UserDefaults.standard
    static var on = d.object(forKey: "menuIcon") as? Bool ?? true { didSet { if Look.saves { d.set(on, forKey: "menuIcon") } } }
    static var show = d.object(forKey: "menuShows") as? Int ?? 0 { didSet { if Look.saves { d.set(show, forKey: "menuShows") } } }
    static func reset() { Look.saves = false; on = true; show = 3 }
}

// The words next to the icon. "What's next": the next event today, shortened; nil when the day is clear (the icon alone).
func menuWords(_ show: Int, now: Date, today: [Item]) -> String? {
    switch show {
    case 1: return dateText(now, "EEE d")
    case 2: return "W\(weekNumber(now))"
    case 3:
        guard let n = today.filter({ !$0.allDay && $0.start > now }).min(by: { $0.start < $1.start }) else { return nil }
        let t = n.title.count > 18 ? String(n.title.prefix(17)).trimmingCharacters(in: .whitespaces) + "…" : n.title
        return "\(t) in \(span((n.start.timeIntervalSince(now) / 60).rounded(.up) * 60))"
    default: return nil
    }
}

// Calendar outline with the day's number, drawn as a template so it follows the menu bar's light or dark.
func dateIcon(_ day: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: 17, height: 16), flipped: true) { _ in
        let r = NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 15, height: 13.5), xRadius: 3, yRadius: 3)
        r.lineWidth = 1.4; NSColor.black.setStroke(); r.stroke()
        NSBezierPath.fill(NSRect(x: 1, y: 1.5, width: 15, height: 3))
        let s = "\(day)" as NSString, a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.black]
        let w = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: 8.5 - w.width / 2, y: 4.3), withAttributes: a)
        return true
    }
    img.isTemplate = true
    return img
}

// Quick add's shortcut the Mac way: "Control Option Space" is ⌃⌥Space.
func keySymbols(_ name: String) -> String {
    name.split(separator: " ").map { ["Control": "⌃", "Option": "⌥", "Shift": "⇧", "Command": "⌘"][String($0)] ?? String($0) }.joined()
}

@MainActor
final class MenuBar: NSObject {
    static let shared = MenuBar()
    private var item: NSStatusItem?
    private let pop = NSPopover()
    private weak var app: AppState?

    // On launch and after every Settings change. Off: the icon leaves the menu bar.
    func update(_ app: AppState) {
        self.app = app
        guard MenuIcon.on else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.target = self
            item?.button?.action = #selector(click)
            pop.behavior = .transient
        }
        let now = Date()
        let words = menuWords(MenuIcon.show, now: now, today: today(app, now))
        guard let b = item?.button else { return }
        b.image = MenuIcon.show == 0 || MenuIcon.show == 3 ? dateIcon(cal.component(.day, from: now)) : nil
        b.imagePosition = .imageLeading
        b.title = words.map { b.image == nil ? $0 : " " + $0 } ?? ""
    }

    func today(_ app: AppState, _ now: Date) -> [Item] {
        app.store.soon.filter { !app.store.hidden.contains($0.calendarID) && cal.isDate($0.start, inSameDayAs: now) }.sorted { $0.start < $1.start }
    }

    @objc private func click() {
        guard let app, let b = item?.button else { return }
        if pop.isShown { pop.performClose(nil); return }
        pop.contentViewController = NSHostingController(rootView: MenuDrop(app: app, store: app.store, now: Date(), items: today(app, Date())) { [weak self] in self?.pop.performClose(nil) })
        pop.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
    }
}

// The menu under the icon (the mockup's dropdown).
struct MenuDrop: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let now: Date, items: [Item]
    let close: () -> Void

    var body: some View {
        let tasks = app.calendarTodos.filter { !$0.done && $0.due.map { cal.startOfDay(for: $0) <= cal.startOfDay(for: now) } == true }
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Today · " + dateText(now, "EEE MMM d")).fontWeight(.semibold); Spacer(); Text("Week \(weekNumber(now))").foregroundStyle(Palette.text3) }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            if items.isEmpty && tasks.isEmpty { Text("Nothing on today").foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.vertical, 6) }
            ForEach(items) { it in
                row(Circle().fill(store.color(it)), it.shownTitle, it.allDay ? "all day" : timeText(it.start)) { close(); app.openEvent(it) }
            }
            ForEach(tasks) { t in
                row(Circle().strokeBorder(store.taskList(t.listID)?.color ?? Palette.accent, lineWidth: 1.5), t.title, "task") {
                    close(); app.openMain?(); NSApp.activate(ignoringOtherApps: true); app.openTaskID = t.id
                }
            }
            Palette.line.frame(height: 1).padding(.horizontal, 4).padding(.vertical, 6)
            command("Quick add…", keySymbols(app.quickName)) { close(); QuickPanel.toggle(app) }
            command("Open Dateline", nil) { close(); app.openMain?(); NSApp.activate(ignoringOtherApps: true) }
        }
        .font(.ui(12.5)).foregroundStyle(Palette.text)
        .padding(8).frame(width: 300)
    }

    func row<S: View>(_ mark: S, _ title: String, _ when: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 9) {
                mark.frame(width: 8, height: 8)
                Text(title).lineLimit(1)
                Spacer(minLength: 6)
                Text(when).foregroundStyle(Palette.text3).monospacedDigit()
            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }

    func command(_ t: String, _ key: String?, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack { Text(t); Spacer(); if let key { Text(key).font(.ui(11)).foregroundStyle(Palette.text2) } }
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

// The row under the pointer is highlighted, like a Mac menu.
struct MenuRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration c: Configuration) -> some View {
        c.label.background(RoundedRectangle(cornerRadius: 6).fill(hover || c.isPressed ? Palette.accentSoft : .clear)).onHover { hover = $0 }
    }
}

// The Menu bar tab in Settings.
struct MenuBarSettings: View {
    @ObservedObject var app: AppState
    @State private var on = MenuIcon.on
    @State private var show = MenuIcon.show

    var body: some View {
        let now = app.now
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show Dateline in the menu bar", isOn: Binding(get: { on }, set: { on = $0; MenuIcon.on = $0; MenuBar.shared.update(app) })).toggleStyle(.switch).controlSize(.small)
            VStack(spacing: 8) {
                ForEach(MenuIcon.shows.indices, id: \.self) { i in
                    let picked = i == show
                    Button { show = i; MenuIcon.show = i; MenuBar.shared.update(app) } label: {
                        HStack(spacing: 10) {
                            Circle().strokeBorder(picked ? Palette.accent : Palette.text3, lineWidth: picked ? 4 : 1.5).frame(width: 14, height: 14)
                            Text(MenuIcon.shows[i])
                            Spacer()
                            chip(i, now)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(picked ? Palette.accentSoft : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked ? Palette.accent : Palette.line))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.disabled(!on).opacity(on ? 1 : 0.5)
            Text("\u{201C}What's next\u{201D} shows the next event today, or the icon alone when the day is clear. Long names are shortened so the menu bar stays tidy.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 620)
    }

    // A sample of what the menu bar shows.
    func chip(_ i: Int, _ now: Date) -> some View {
        let words = i == 3 ? (menuWords(3, now: now, today: MenuBar.shared.today(app, now)) ?? "") : menuWords(i, now: now, today: [])
        return HStack(spacing: 5) {
            if i == 0 || i == 3 { Image(nsImage: dateIcon(cal.component(.day, from: now))).renderingMode(.template) }
            if let words, !words.isEmpty { Text(words) }
        }
        .font(.system(size: 12)).foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.13))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.87, green: 0.89, blue: 0.92)))
    }
}
