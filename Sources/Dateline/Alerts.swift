// Phase 6 (approved mockups, 2026-10-28): the full screen alert and the alert sounds. Saved on this Mac.
import SwiftUI
import AppKit
import Intents
import DatelineCore

func screenLocked() -> Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
// A Focus counts only once John allowed Dateline to see it; a copy without Apple's Focus permission reads "not allowed" and keeps showing the alert.
func focusOn() -> Bool { INFocusStatusCenter.default.authorizationStatus == .authorized && INFocusStatusCenter.default.focusStatus.isFocused == true }
func quietNow() -> Bool { screenLocked() || focusOn() }

extension AppState {
    // Every 10 seconds: what went off since the last look. One sound at a time, the full screen alert's first.
    func checkAlerts(now: Date = Date()) {
        let from = max(alertCheck, now.addingTimeInterval(-120))  // after sleep, only the last 2 minutes count
        alertCheck = now
        guard from < now, store.access == .granted else { return }
        let soon = store.soon
        let due = Alerts.full && !quietNow()
            ? fullScreenDue(soon, from: from, to: now, lead: Alerts.leadMinutes[Alerts.lead]) { id in store.calendar(id).map(Alerts.covers) ?? false } : []
        let leave = soon.contains { it in (it.leave ?? WorkWeek.leave) && drive[it.id].map { anyIn([it.start.addingTimeInterval(-Double($0) * 60)], from: from, to: now) } == true }
        let tasks = store.todos.filter { !$0.done && $0.timed && $0.remind == .time && $0.a4 == nil }.compactMap(\.due)  // A4's own reminders job rings for its tasks
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
        panels.panelOpen = true
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
                    // the setting, the lock, a Focus and the event may have changed in those 5 minutes
                    let still = app.store.soon.filter { ids.contains($0.id) }
                    if Alerts.full && !quietNow() && !still.isEmpty { show(still, app: app) }
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
        let call = items.lazy.compactMap(callLink).first  // any of the events alerting together
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.62).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 16) {
                Text(startWord(items[0].start, now: now) + " · " + timeText(items[0].start)).font(.ui(12, weight: .semibold)).foregroundStyle(Palette.now).kerning(0.5)
                ForEach(items) { it in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.shownTitle).font(.ui(items.count == 1 ? 26 : 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Circle().fill(store.color(it)).frame(width: 8, height: 8)
                            Text((store.calendar(it.calendarID)?.title ?? "") + " · " + timeText(it.start) + " to " + timeText(it.end))
                        }.foregroundStyle(Palette.text2)
                        if let n = it.notes.split(separator: "\n").first { Text("Notes: " + n).foregroundStyle(Palette.text2).lineLimit(2) }
                    }
                    .contentShape(Rectangle()).onTapGesture { open(it) }
                }
                HStack(spacing: 8) {
                    if let call { button("Join", "J", primary: true, KeyboardShortcut("j", modifiers: [])) { NSWorkspace.shared.open(call.url); close() } }
                    button("Close", "Esc", primary: call == nil, .cancelAction, close)
                    button("Snooze 5 min", "S", KeyboardShortcut("s", modifiers: []), snooze)
                    button("Open event", "O", KeyboardShortcut("o", modifiers: [])) { open(items[0]) }
                }
                HStack(spacing: 12) {
                    Text("Closes by itself in 2 min")
                    Spacer(minLength: 0)
                    if let next { Text("Next: \(next.shownTitle), \(timeText(next.start))").lineLimit(1) }
                }
                .font(.ui(12)).foregroundStyle(Palette.text3).padding(.top, 8).overlay(alignment: .top) { Palette.line.frame(height: 1) }
            }
            .font(.ui(13))
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20).frame(width: call == nil ? 460 : 540, alignment: .leading)  // room for Join too
            .background(RoundedRectangle(cornerRadius: 20).fill(Palette.pop).shadow(color: .black.opacity(0.5), radius: 40, y: 30))
            .foregroundStyle(Palette.text)
            .onTapGesture {}  // a click on the card itself does not close it
        }
    }

    func button(_ t: String, _ key: String, primary: Bool = false, _ shortcut: KeyboardShortcut, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Text(t).fontWeight(primary ? .medium : .regular)
                Text(key).font(.ui(11)).padding(.horizontal, 4).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(primary ? .white.opacity(0.5) : Palette.line))
            }
            .foregroundStyle(primary ? .white : Palette.text)
            .padding(.horizontal, 16).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Palette.accent : Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? Palette.accent : Palette.line))
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
                row("Full screen alert", "Stays away while the Mac is locked or a Focus is on.") {
                    Toggle("Cover the screen when an event starts", isOn: Binding(get: { Alerts.full }, set: { Alerts.full = $0; bump += 1 })).toggleStyle(.switch).controlSize(.small)
                }
                row("For these calendars", "Other calendars keep their normal Mac alerts. All-day events never cover the screen.") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.calendars) { c in
                            let on = Alerts.covers(c)
                            Button {
                                var s = Alerts.fullCalendars ?? Set(store.calendars.filter(Alerts.covers).map(\.id))
                                if on { s.remove(c.id) } else { s.insert(c.id) }
                                Alerts.fullCalendars = s; bump += 1
                            } label: { HStack(spacing: 8) { Tick(on: on, color: c.color); Text(c.title).lineLimit(1) }.contentShape(Rectangle()) }.buttonStyle(.plain)
                        }
                    }
                }
                row("Show it") { Seg(options: Alerts.leads, selected: Alerts.leads[Alerts.lead], small: true) { Alerts.lead = Alerts.leads.firstIndex(of: $0)!; bump += 1 } }
                row("Sounds", "Each list has the Mac's sounds plus \u{201C}No sound\u{201D}. Calendar and Reminders still play their own sound with their banners; to hear only these, turn their sounds off under Notifications in System Settings.") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Alerts.kinds, id: \.0) { k in
                            HStack(spacing: 12) {
                                Text(k.1).frame(width: 100, alignment: .leading)
                                Menu {
                                    ForEach(Alerts.sounds, id: \.self) { n in Button(n) { Alerts.sound[k.0] = n; bump += 1; Alerts.play(name: n) } }
                                } label: { Text(Alerts.soundName(k.0)) }.frame(width: 152)
                                Button { Alerts.play(k.0) } label: {
                                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Palette.accent).frame(width: 28, height: 28)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                                }.buttonStyle(.plain).help("Play").accessibilityLabel("Play sound")
                            }
                        }
                    }
                }
            }
            .id(bump)
            .frame(width: 472, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Text("WHAT A TASK ALERT LOOKS LIKE").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3)
                HStack(spacing: 8) {
                    VStack(spacing: 0) {
                        Text("OCT").font(.system(size: 7, weight: .bold)).foregroundStyle(Palette.now)
                        Text("28").font(.system(size: 14, weight: .semibold))
                    }.frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Palette.win)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Buy AC filter").fontWeight(.semibold)
                        Text("Task due now · plays \u{201C}\(Alerts.soundName("tasks"))\u{201D}").font(.system(size: 12)).foregroundStyle(Palette.text2)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pop).shadow(color: .black.opacity(0.14), radius: 9, y: 6))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
                .id(bump)
                Text("Normal alerts stay the Mac's usual banners. Only the sound changes.").font(.system(size: 12)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .padding(12).frame(width: 260, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.side)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28).padding(.vertical, 20).frame(width: 820)
    }

    func row<V: View>(_ k: String, _ hint: String? = nil, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 120, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                v()
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

