// Phase 6 (approved mockups, 2026-10-28): the full screen alert and the alert sounds. Saved on this Mac.
import SwiftUI
import AppKit

enum Alerts {
    private static let d = UserDefaults.standard
    static let leads = ["When it starts", "1 min before", "5 min before"], leadMinutes = [0, 1, 5]
    static let kinds = [("events", "Events", "Glass"), ("tasks", "Tasks", "Pop"), ("leave", "Time to leave", "Submarine"), ("full", "Full screen", "Hero")]
    // The Mac's own sounds, so nothing is downloaded.
    static let sounds = ["No sound"] + ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .map { ($0 as NSString).deletingPathExtension }.sorted()

    static var full = d.object(forKey: "fullAlert") as? Bool ?? true { didSet { save(full, "fullAlert") } }
    static var lead = d.object(forKey: "fullLead") as? Int ?? 0 { didSet { save(lead, "fullLead") } }
    // nil until the first change: then only calendars called Work are on.
    static var fullCalendars = (d.array(forKey: "fullCalendars") as? [String]).map(Set.init) { didSet { save(Array(fullCalendars ?? []), "fullCalendars") } }
    static var sound = d.dictionary(forKey: "alertSounds") as? [String: String] ?? [:] { didSet { save(sound, "alertSounds") } }

    private static func save(_ v: Any, _ key: String) { if Look.saves { d.set(v, forKey: key) } }

    static func covers(_ c: CalInfo) -> Bool { fullCalendars?.contains(c.id) ?? (c.title.caseInsensitiveCompare("Work") == .orderedSame) }
    static func soundName(_ kind: String) -> String { sound[kind] ?? kinds.first { $0.0 == kind }!.2 }

    static func play(_ kind: String) { play(name: soundName(kind)) }
    static func play(name: String) {
        guard name != "No sound", let s = NSSound(named: NSSound.Name(name)) else { return }
        s.stop(); s.play()
    }

    // The mockup's choices, for the off-screen pictures and the self-checks; never saved.
    static func reset() { Look.saves = false; full = true; lead = 0; fullCalendars = nil; sound = [:] }
}

// Events whose full screen alert time (start minus `lead` minutes) falls after `from`, up to `to`.
func fullScreenDue(_ items: [Item], from: Date, to: Date, lead: Int, covers: (String) -> Bool) -> [Item] {
    items.filter { it in
        let t = it.start.addingTimeInterval(-Double(lead * 60))
        return !it.allDay && t > from && t <= to && covers(it.calendarID)
    }.sorted { $0.start < $1.start }
}

func anyIn(_ dates: [Date], from: Date, to: Date) -> Bool { dates.contains { $0 > from && $0 <= to } }

// "STARTING NOW", "IN 5 MIN", "STARTED 5 MIN AGO" (after a snooze).
func startWord(_ start: Date, now: Date) -> String {
    let s = start.timeIntervalSince(now)
    if abs(s) < 30 { return "STARTING NOW" }
    return s > 0 ? "IN \(span((s / 60).rounded(.up) * 60).uppercased())" : "STARTED \(span(-s).uppercased()) AGO"
}

func screenLocked() -> Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }

extension AppState {
    // Every 10 seconds: what went off since the last look. One sound at a time, the full screen alert's first.
    func checkAlerts(now: Date = Date()) {
        let from = max(alertCheck, now.addingTimeInterval(-120))  // after sleep, only the last 2 minutes count
        alertCheck = now
        guard from < now, store.access == .granted else { return }
        let soon = store.soon
        let due = Alerts.full && !screenLocked()
            ? fullScreenDue(soon, from: from, to: now, lead: Alerts.leadMinutes[Alerts.lead]) { id in store.calendar(id).map(Alerts.covers) ?? false } : []
        let leave = soon.contains { it in (it.leave ?? WorkWeek.leave) && drive[it.id].map { anyIn([it.start.addingTimeInterval(-Double($0) * 60)], from: from, to: now) } == true }
        let tasks = store.todos.filter { !$0.done && $0.timed && $0.remind == .time }.compactMap(\.due)
        if !due.isEmpty { FullAlert.show(due, app: self) }
        else if anyIn(soon.flatMap(\.alerts), from: from, to: now) { Alerts.play("events") }
        else if leave { Alerts.play("leave") }
        else if anyIn(tasks, from: from, to: now) { Alerts.play("tasks") }
    }

    // Open event: the window comes back on the event's day with its details open.
    func openEvent(_ it: Item) {
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
        if !visibleDays.contains(cal.startOfDay(for: it.start)) { anchor = cal.startOfDay(for: it.start) }
        selectedID = it.id
        panelOpen = true
    }
}

// Covers the screen you're using. Esc, Close, a click on the dark area or 2 minutes close it.
final class FullAlert: NSPanel {
    static var shared: FullAlert?
    private var timer: Timer?
    var shown = Date()

    @MainActor static func show(_ items: [Item], app: AppState) {
        shared?.dismiss()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let p = FullAlert(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.title = "Dateline alert"
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let now = Date()
        let next = app.store.soon.filter { n in !n.allDay && !app.store.hidden.contains(n.calendarID) && n.start > items.last!.start && cal.isDate(n.start, inSameDayAs: now) && !items.contains { $0.id == n.id } }
            .min { $0.start < $1.start }
        p.contentView = NSHostingView(rootView: FullAlertView(items: items, store: app.store, now: now, next: next,
            close: { p.dismiss() },
            snooze: {
                p.dismiss()
                let ids = items.map(\.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { MainActor.assumeIsolated {
                    // the setting, the lock and the event may have changed in those 5 minutes
                    let still = app.store.soon.filter { ids.contains($0.id) }
                    if Alerts.full && !screenLocked() && !still.isEmpty { show(still, app: app) }
                } }
            },
            open: { it in p.dismiss(); app.openEvent(it) }))
        p.setFrame(screen.frame, display: true)
        p.timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak p] _ in p?.dismiss() }
        shared = p
        p.shown = Date()
        p.makeKeyAndOrderFront(nil)
        Alerts.play("full")
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        orderOut(nil)
        DispatchQueue.main.async { self.contentView = nil }  // its buttons hold on to this panel; let the click that closed it finish first
        if FullAlert.shared === self { FullAlert.shared = nil }
    }

    override var canBecomeKey: Bool { true }
    // Keys typed in the first second were meant for the app underneath, not Esc, S or O here.
    override func sendEvent(_ e: NSEvent) { if e.type == .keyDown && Date().timeIntervalSince(shown) < 1 { return }; super.sendEvent(e) }
    override func resignKey() { super.resignKey(); dismiss() }  // a click outside it, also on another screen
}

struct FullAlertView: View {
    let items: [Item]
    @ObservedObject var store: Store
    let now: Date, next: Item?
    let close: () -> Void, snooze: () -> Void, open: (Item) -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.62).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 14) {
                Text(startWord(items[0].start, now: now) + " · " + timeText(items[0].start)).font(.ui(12, weight: .semibold)).foregroundStyle(Palette.now).kerning(0.5)
                ForEach(items) { it in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.shownTitle).font(.ui(items.count == 1 ? 26 : 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Circle().fill(store.color(it)).frame(width: 8, height: 8)
                            Text((store.calendar(it.calendarID)?.title ?? "") + " · " + timeText(it.start) + " to " + timeText(it.end))
                        }.foregroundStyle(Palette.text2)
                        if let n = it.notes.split(separator: "\n").first { Text("Notes: " + n).foregroundStyle(Palette.text2).lineLimit(2) }
                    }
                    .contentShape(Rectangle()).onTapGesture { open(it) }
                }
                HStack(spacing: 8) {
                    button("Close", "Esc", primary: true, .cancelAction, close)
                    button("Snooze 5 min", "S", KeyboardShortcut("s", modifiers: []), snooze)
                    button("Open event", "O", KeyboardShortcut("o", modifiers: [])) { open(items[0]) }
                }
                HStack(spacing: 10) {
                    Text("Closes by itself in 2 min")
                    Spacer(minLength: 0)
                    if let next { Text("Next: \(next.shownTitle), \(timeText(next.start))").lineLimit(1) }
                }
                .font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.top, 10).overlay(alignment: .top) { Palette.line.frame(height: 1) }
            }
            .font(.ui(13))
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22).frame(width: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.pop).shadow(color: .black.opacity(0.5), radius: 40, y: 30))
            .foregroundStyle(Palette.text)
            .onTapGesture {}  // a click on the card itself does not close it
        }
    }

    func button(_ t: String, _ key: String, primary: Bool = false, _ shortcut: KeyboardShortcut, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(t).fontWeight(primary ? .medium : .regular)
                Text(key).font(.ui(11)).padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(primary ? .white.opacity(0.5) : Palette.line))
            }
            .foregroundStyle(primary ? .white : Palette.text)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Palette.accent : Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Palette.accent : Palette.line))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).keyboardShortcut(shortcut)
    }
}

// The Alerts tab in Settings. Every choice applies at once.
struct AlertSettings: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State private var bump = 0  // redraws after a change; the choices live in `Alerts`, not here

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                row("Full screen alert") {
                    Toggle("Cover the screen when an event starts", isOn: Binding(get: { Alerts.full }, set: { Alerts.full = $0; bump += 1 })).toggleStyle(.switch).controlSize(.small)
                }
                row("For these calendars", "Other calendars keep their normal Mac alerts. All-day events never cover the screen.") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(store.calendars) { c in
                            let on = Alerts.covers(c)
                            Button {
                                var s = Alerts.fullCalendars ?? Set(store.calendars.filter(Alerts.covers).map(\.id))
                                if on { s.remove(c.id) } else { s.insert(c.id) }
                                Alerts.fullCalendars = s; bump += 1
                            } label: { HStack(spacing: 9) { Tick(on: on, color: c.color); Text(c.title).lineLimit(1) }.contentShape(Rectangle()) }.buttonStyle(.plain)
                        }
                    }
                }
                row("Show it") { Seg(options: Alerts.leads, selected: Alerts.leads[Alerts.lead], small: true) { Alerts.lead = Alerts.leads.firstIndex(of: $0)!; bump += 1 } }
                row("Sounds", "Each list has the Mac's sounds plus \u{201C}No sound\u{201D}. Calendar and Reminders still play their own sound with their banners; to hear only these, turn their sounds off under Notifications in System Settings.") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Alerts.kinds, id: \.0) { k in
                            HStack(spacing: 10) {
                                Text(k.1).frame(width: 100, alignment: .leading)
                                Menu {
                                    ForEach(Alerts.sounds, id: \.self) { n in Button(n) { Alerts.sound[k.0] = n; bump += 1; Alerts.play(name: n) } }
                                } label: { Text(Alerts.soundName(k.0)) }.frame(width: 150)
                                Button { Alerts.play(k.0) } label: {
                                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Palette.accent).frame(width: 28, height: 28)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                                }.buttonStyle(.plain).help("Play")
                            }
                        }
                    }
                }
            }
            .id(bump)
            .frame(width: 470, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text("WHAT A TASK ALERT LOOKS LIKE").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3)
                HStack(spacing: 9) {
                    VStack(spacing: 0) {
                        Text("OCT").font(.system(size: 7, weight: .bold)).foregroundStyle(Palette.now)
                        Text("28").font(.system(size: 14, weight: .semibold))
                    }.frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 7).fill(Palette.win)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Buy AC filter").fontWeight(.semibold)
                        Text("Task due now · plays \u{201C}\(Alerts.soundName("tasks"))\u{201D}").font(.system(size: 11.5)).foregroundStyle(Palette.text2)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pop).shadow(color: .black.opacity(0.14), radius: 9, y: 6))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
                .id(bump)
                Text("Normal alerts stay the Mac's usual banners. Only the sound changes.").font(.system(size: 12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .padding(12).frame(width: 260, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.side)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28).padding(.vertical, 22).frame(width: 820)
    }

    func row<V: View>(_ k: String, _ hint: String? = nil, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 120, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                v()
                if let hint { Text(hint).font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
