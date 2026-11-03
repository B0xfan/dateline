// Quick add from any app (Phase 2): its box, the system-wide shortcut, the floating panel and its Settings tab.
import SwiftUI
import AppKit
import Carbon.HIToolbox

// Quick add from any app (Phase 2): its own text, the past event Tab picked, the highlighted suggestion, and its shortcut.
@MainActor final class QuickBox: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { pick = nil; sel = 0 } } }
    @Published var pick: Item?
    @Published var sel = 0
    @Published var focus = 0
    @Published var name = UserDefaults.standard.string(forKey: "quickName") ?? "Control Option Space"
    @Published var error: String?  // why the last quick add failed, shown in the quick box
    @Published var taken = false  // another app already uses the shortcut
    @Published var keyRefused = false  // the shortcut just picked in Settings was taken, so the old one stays
    @Published var recordingKey = false  // Settings is waiting for a new shortcut
}

extension AppState {
    // The quick add shortcut, Control Option Space unless changed in Settings. Works while any app is in front.
    func registerQuick() {
        let d = UserDefaults.standard
        let code = d.object(forKey: "quickCode") as? Int ?? kVK_Space, mods = d.object(forKey: "quickMods") as? Int ?? (controlKey | optionKey)
        HotKey.action = { [weak self] in if let self { QuickPanel.toggle(self) } }
        quick.taken = !HotKey.register(code: UInt32(code), mods: UInt32(mods))
    }

    func setQuickKey(_ e: NSEvent) {
        let f = e.modifierFlags
        let parts: [(Bool, String, Int)] = [(f.contains(.control), "Control", controlKey), (f.contains(.option), "Option", optionKey),
                                            (f.contains(.shift), "Shift", shiftKey), (f.contains(.command), "Command", cmdKey)]
        let on = parts.filter(\.0)
        let key = e.keyCode == kVK_Space ? "Space" : (e.charactersIgnoringModifiers ?? "").uppercased()
        let d = UserDefaults.standard, keys = ["quickCode", "quickMods", "quickName"], old = keys.map { d.object(forKey: $0) }
        let name = (on.map(\.1) + [key]).joined(separator: " ")
        zip(keys, [Int(e.keyCode), on.reduce(0) { $0 | $1.2 }, name] as [Any]).forEach { d.set($1, forKey: $0) }
        registerQuick()
        if quick.taken {
            zip(keys, old).forEach { d.set($1, forKey: $0) }
            registerQuick()
            quick.keyRefused = true  // Settings says so; the old shortcut still works
        } else { quick.name = name; quick.keyRefused = false }
    }
}

// A system-wide shortcut through the Carbon hot key call: no Accessibility permission needed.
@MainActor
enum HotKey {
    static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false

    static func register(code: UInt32, mods: UInt32) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        return RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x444C4E45, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// The floating quick add box. It takes typing without bringing Dateline to the front, and hides when you click elsewhere.
final class QuickPanel: NSPanel {
    static var shared: QuickPanel?

    static func toggle(_ app: AppState) {
        let p = shared ?? QuickPanel(app)
        shared = p
        if p.isVisible { p.orderOut(nil); return }
        if let s = NSScreen.main { p.setFrameTopLeftPoint(NSPoint(x: s.frame.midX - p.frame.width / 2, y: s.visibleFrame.maxY - s.frame.height * 0.22)) }
        app.quick.text = ""; app.quick.error = nil
        app.quick.focus += 1
        p.makeKeyAndOrderFront(nil)
    }

    init(_ app: AppState) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the box draws its own
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: QuickAddView(app: app, store: app.store, quick: app.quick).frame(width: 700, height: 560, alignment: .top))
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }
}

// The quick add box that opens over any app (approved Phase 2 mockup).
struct QuickAddView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @ObservedObject var quick: QuickBox
    @FocusState private var focused: Bool
    var body: some View {
        let list = app.quickSuggestions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.ui(16, weight: .semibold)).foregroundStyle(Palette.accent)
                TextField("Lunch with Sam tomorrow 1pm /Personal -a15m", text: $quick.text)
                    .textFieldStyle(.plain).font(.ui(18)).focused($focused)
                    .onSubmit { app.commitQuick() }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            if !list.isEmpty {
                section("FROM YOUR PAST EVENTS")
                ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                    let c = store.calendar(it.calendarID)
                    HStack(spacing: 12) {
                        Circle().fill(c?.color ?? .gray).frame(width: 8, height: 8)
                        Text(it.title).fontWeight(.semibold).lineLimit(1)
                        Text(([it.place, c?.title ?? ""].filter { !$0.isEmpty } + ["last on " + dateText(it.start, "MMM d")]).joined(separator: " · "))
                            .font(.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                        Spacer(minLength: 0)
                        if i == quick.sel { Key("Tab") }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(i == quick.sel ? Palette.accentSoft : .clear)
                    .contentShape(Rectangle()).onTapGesture { quick.pick = it }
                }
            }
            if !quick.text.trimmingCharacters(in: .whitespaces).isEmpty {
                section("WHAT I UNDERSTOOD")
                Understood(app: app, store: store, box: app.addBox, p: app.quickPreview, pick: quick.pick).padding(.horizontal, 16).padding(.bottom, 8)
            }
            HStack(spacing: 16) {
                code(["/name"], "calendar"); code(["-a15m", "-a1h", "-a1d"], "alert before"); code(["-r1d", "-r1w", "-r1m"], "repeat")
            }
            .font(.ui(12)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Palette.line.frame(height: 1) }
            HStack(spacing: 8) {
                Key("Return"); Text("add"); Key("Tab"); Text("use past event"); Key("Esc"); Text("close")
                Spacer()
                if let err = quick.error { Text(err).foregroundStyle(Palette.now) }
                else { Text(quick.taken ? "Another app uses \(quick.name). Change it in Settings" : "Shortcut can be changed in Settings") }
            }
            .font(.ui(12)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 8)
            .background(Palette.bar).overlay(alignment: .top) { Palette.line.frame(height: 1) }
        }
        .font(.ui(13)).foregroundStyle(Palette.text)
        .frame(width: 640)
        .background(Palette.pop)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.38), radius: 40, y: 30)
        .padding(.top, 8)
        .onAppear { focused = true }
        .onChange(of: quick.focus) { _, _ in focused = true }
    }

    func section(_ t: String) -> some View {
        Text(t).font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    func code(_ codes: [String], _ what: String) -> some View {
        HStack(spacing: 4) { ForEach(codes, id: \.self) { Text($0).fontWeight(.semibold).foregroundStyle(Palette.accent) }; Text(what) }
    }
}

struct QuickSettings: View {
    @ObservedObject var app: AppState
    @ObservedObject var quick: QuickBox
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick add from any app")
                Spacer()
                Button(quick.recordingKey ? "Press the new shortcut" : quick.name) { record() }
            }
            Text(quick.taken || quick.keyRefused ? "Another app already uses this shortcut. Pick a different one." : "Opens the add box on top of whatever app is in front. Use Control, Option or Command with a key; Esc cancels.")
                .font(.ui(12)).foregroundStyle(quick.taken || quick.keyRefused ? Palette.now : Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 440)
        .onDisappear { stop() }
        .font(.ui(13))
    }

    func record() {
        guard monitor == nil else { return }
        quick.recordingKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode != 53, !e.modifierFlags.intersection([.command, .option, .control]).isEmpty { app.setQuickKey(e) }
            stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        quick.recordingKey = false
    }
}
