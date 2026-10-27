// The window: sidebar, toolbar with the add box, the view area, the shortcut bar. Colours and sizes follow the approved mockups.
import SwiftUI
import AppKit

enum Palette {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
    static let win = c(0xffffff, 0x1e1e22), side = c(0xf3f3f6, 0x26262b), bar = c(0xf8f8fa, 0x232327)
    static let line = c(0xe2e2e7, 0x36363d), lineSoft = c(0xefeff3, 0x2b2b31)
    static let text = c(0x1d1d22, 0xececf1), text2 = c(0x5e5e68, 0xa8a8b3), text3 = c(0x8d8d97, 0x75757f)
    static let accent = c(0x2f6fde, 0x5b8ff0), accentSoft = c(0xe6eefc, 0x263552), now = c(0xe5484d, 0xe5484d)
    static let field = c(0xffffff, 0x2c2c32), pop = c(0xffffff, 0x2a2a30)
    static let work = c(0x2f6fde, 0x5b8ff0), personal = c(0x2e9d5b, 0x4cbb7a), family = c(0xd9822b, 0xeb9a4a)
}

// Busy = filled dot, Free = ring, Maybe = dotted ring (B17).
struct Mark: View {
    let showAs: ShowAs, color: Color
    var body: some View {
        switch showAs {
        case .busy: Circle().fill(color).frame(width: 9, height: 9)
        case .free: Circle().strokeBorder(color, lineWidth: 1.6).frame(width: 9, height: 9)
        case .maybe: Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 1.5])).frame(width: 9, height: 9)
        }
    }
}

struct Key: View {
    let k: String
    init(_ k: String) { self.k = k }
    var body: some View {
        Text(k).font(.system(size: 11)).foregroundStyle(Palette.text2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
    }
}

struct MainView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(app: app, store: store).frame(width: 236)
            Divider().overlay(Palette.line)
            VStack(spacing: 0) {
                Toolbar(app: app, store: store)
                ZStack(alignment: .bottom) {
                    Group {
                        switch store.access {
                        case .denied: NoAccess()
                        case .unknown: Color.clear
                        default:
                            switch app.mode {
                            case .month: MonthView(app: app, store: store)
                            case .year: YearView(app: app, store: store)
                            default: TimeGrid(app: app, store: store)
                            }
                        }
                    }
                    if let t = app.toast { ToastView(app: app, toast: t).padding(.bottom, 14) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if app.addFocused && !app.addText.isEmpty { PreviewCard(app: app, store: store).padding(.trailing, 14).padding(.top, 6) }
                }
                StatusBar()
            }
            if app.panelOpen, let it = app.selected {
                Divider().overlay(Palette.line)
                DetailPanel(app: app, store: store, item: it).id(it.id).frame(width: 320)
            }
        }
        .background(Palette.win)
        .foregroundStyle(Palette.text)
        .font(.system(size: 13))
        .sheet(isPresented: $app.showShortcuts) { ShortcutList(app: app) }
        .sheet(item: $app.confirmDelete) { it in ConfirmDelete(app: app, store: store, item: it) }
        .alert("Couldn't save", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }
}

struct NoAccess: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Dateline can't see your calendars yet").font(.system(size: 15, weight: .semibold))
            Text("Turn on Dateline under Privacy & Security, Calendars, in System Settings, then reopen it.").foregroundStyle(Palette.text2)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Sidebar: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40)  // room for the window's buttons
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendars on this Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.bottom, 4)
                    let groups = Dictionary(grouping: store.calendars, by: \.account)
                    ForEach(groups.keys.sorted(), id: \.self) { acct in
                        Text(acct).font(.system(size: 11)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        ForEach(groups[acct]!) { c in row(c) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uses your Mac's accounts").font(.system(size: 12, weight: .semibold))
                        Text("Shows the calendars already set up in your Mac's settings. No separate sign-ins.").foregroundStyle(Palette.text2)
                    }
                    .font(.system(size: 12))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.lineSoft))
                    .padding(.horizontal, 8).padding(.top, 10)
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            Divider().overlay(Palette.line)
            Text("Your data stays on this Mac").font(.system(size: 11.5)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Palette.side)
    }

    func row(_ c: CalInfo) -> some View {
        let on = !store.hidden.contains(c.id)
        return Button {
            if on { store.hidden.insert(c.id) } else { store.hidden.remove(c.id) }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(on ? c.color : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(c.color, lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).opacity(on ? 1 : 0))
                    .frame(width: 14, height: 14)
                Text(c.title).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct Toolbar: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            Button("Today") { app.goToday() }.buttonStyle(TButton())
            HStack(spacing: 4) {
                Button { app.step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(TButton(icon: true))
                Button { app.step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(TButton(icon: true))
            }
            ViewThatFits(in: .horizontal) {
                Text(app.title).fixedSize()
                Text(app.shortTitle).fixedSize()
            }.font(.system(size: 15, weight: .semibold)).padding(.leading, 4).layoutPriority(2)
            if app.mode != .year {
                Text(app.weekLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.text2)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(Palette.lineSoft)).fixedSize()
            }
            Spacer(minLength: 8)
            if app.mode == .week {
                HStack(spacing: 6) {
                    if !app.panelOpen { Text("Days").font(.system(size: 12)).foregroundStyle(Palette.text2) }
                    Seg(options: ["3", "5", "7"], selected: String(app.days), small: true) { app.days = Int($0)! }
                }.fixedSize()
            }
            Seg(options: Mode.allCases.map(\.rawValue), selected: app.mode.rawValue) { app.mode = Mode(rawValue: $0)! }.fixedSize()
            AddBox(app: app).frame(minWidth: 130, maxWidth: 300)
            Button("?") { app.showShortcuts = true }.buttonStyle(TButton(icon: true)).help("Keyboard shortcuts")
        }
        .padding(.horizontal, 14).frame(height: 52)
        .background(Palette.bar)
        .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
    }
}

struct TButton: ButtonStyle {
    var icon = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).foregroundStyle(Palette.text)
            .frame(minWidth: 28, minHeight: 28).padding(.horizontal, icon ? 0 : 10)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Palette.lineSoft : Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            .contentShape(Rectangle())
    }
}

struct Seg: View {
    let options: [String], selected: String
    var small = false
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { pick(o) } label: {
                    Text(o).font(.system(size: small ? 12 : 13, weight: o == selected ? .medium : .regular))
                        .foregroundStyle(o == selected ? Palette.text : Palette.text2)
                        .padding(.horizontal, small ? 9 : 14).padding(.vertical, small ? 3 : 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(o == selected ? Palette.field : .clear).shadow(color: .black.opacity(o == selected ? 0.15 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Palette.lineSoft))
    }
}

struct AddBox: View {
    @ObservedObject var app: AppState
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
            TextField("Add: Dinner with Ana Friday 7pm", text: $app.addText)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit { app.commitAdd() }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.accent : Palette.line, lineWidth: focused ? 1.5 : 1))
        .background(RoundedRectangle(cornerRadius: 10).fill(focused ? Palette.accentSoft : .clear).padding(-3))
        .onChange(of: focused) { _, f in app.addFocused = f }
        .onChange(of: app.addFocused) { _, f in if !f { focused = false } }
        .onChange(of: app.focusAdd) { _, _ in focused = true }
    }
}

// "What I understood": the live preview under the add box (A2).
struct PreviewCard: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        let p = app.preview
        let c = app.addCalendar
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT I UNDERSTOOD").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.bottom, 8)
            row("Title") { Text(p.title.isEmpty ? "New event" : p.title) }
            row("When") { Text(whenText(p)) }
            if !p.place.isEmpty { row("Where") { Text(p.place) } }
            row("Calendar") {
                Menu {
                    ForEach(store.calendars.filter(\.writable)) { cal in Button(cal.title + "  (" + cal.account + ")") { app.addCalendarID = cal.id } }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(c?.color ?? .gray).frame(width: 8, height: 8)
                        Text(c?.title ?? "None")
                        if c?.id == store.defaultCalendarID { Text("(your default)").foregroundStyle(Palette.text3).fontWeight(.regular) }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            row("Show as") { HStack(spacing: 6) { Mark(showAs: p.showAs, color: c?.color ?? .gray); Text(p.showAs.rawValue) } }
            Divider().overlay(Palette.line).padding(.top, 10)
            HStack(spacing: 6) {
                Key("Return"); Text("add"); Key("Esc"); Text("cancel"); Key("Tab"); Text("edit details")
                Spacer()
                Button("Add") { app.commitAdd() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 6).fill(Palette.accent))
            }.font(.system(size: 11.5)).foregroundStyle(Palette.text3).padding(.top, 10)
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.pop).shadow(color: .black.opacity(0.18), radius: 17, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(k).foregroundStyle(Palette.text3).frame(width: 78, alignment: .leading)
            v().fontWeight(.medium)
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
}

func whenText(_ p: Parsed) -> String {
    if p.allDay {
        let last = addDays(p.end, -1)
        return dateText(p.start, "EEE, MMM d") + (cal.isDate(last, inSameDayAs: p.start) ? "" : " to " + dateText(last, "EEE, MMM d")) + ", all day"
    }
    let sameDay = cal.isDate(p.start, inSameDayAs: p.end)
    return dateText(p.start, "EEE, MMM d") + ", " + timeText(p.start) + " to " + (sameDay ? "" : dateText(p.end, "EEE, MMM d") + ", ") + timeText(p.end)
}

struct StatusBar: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) { Key("N"); Text("new") }
            HStack(spacing: 5) { Key("T"); Text("today") }
            HStack(spacing: 5) { Key("1"); Key("2"); Key("3"); Key("4"); Text("day, week, month, year") }
            HStack(spacing: 5) { Key("?"); Text("all shortcuts") }
            Spacer()
            ForEach(ShowAs.allCases, id: \.self) { s in HStack(spacing: 5) { Mark(showAs: s, color: Palette.text3); Text(s.rawValue) } }
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.text3)
        .padding(.horizontal, 14).frame(height: 30)
        .background(Palette.bar)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
}

struct ShortcutList: View {
    @ObservedObject var app: AppState
    static let rows: [(String, String)] = [
        ("New event", "N"), ("Go to today", "T"), ("Day view", "1"), ("Week view", "2"), ("Month view", "3"), ("Year view", "4"),
        ("Previous", "Left"), ("Next", "Right"), ("Next or previous event", "Up / Down"), ("Open event", "Return"),
        ("Delete event", "Delete"), ("Move event 15 min", "Option Up / Down"), ("Undo", "Command Z"), ("This list", "?"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts").font(.system(size: 15, weight: .semibold)).padding(.bottom, 12)
            ForEach(Self.rows, id: \.0) { r in
                HStack { Text(r.0); Spacer(); Key(r.1) }.padding(.vertical, 5)
                Divider().overlay(Palette.lineSoft)
            }
            HStack { Spacer(); Button("Done") { app.showShortcuts = false }.keyboardShortcut(.defaultAction) }.padding(.top, 12)
        }.padding(20).frame(width: 340).background(Palette.pop)
    }
}

struct ToastView: View {
    @ObservedObject var app: AppState
    let toast: AppState.Toast
    var body: some View {
        HStack(spacing: 10) {
            Text("Deleted \u{201C}\(toast.text)\u{201D} from \(toast.calendar)")
            Button("Undo") { app.undo() }.buttonStyle(.plain).foregroundStyle(Palette.accent).fontWeight(.semibold)
            Key("Command Z")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.pop).shadow(color: .black.opacity(0.18), radius: 12, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }
}

struct ConfirmDelete: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let item: Item
    var body: some View {
        let c = store.calendar(item.calendarID)?.title ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \u{201C}\(item.title)\u{201D}?").font(.system(size: 15, weight: .semibold))
            Text("This removes it from your \(c) calendar on this Mac and on every device that syncs it. You can undo right after.")
                .foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { app.confirmDelete = nil }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { app.confirmDelete = nil; app.delete(item) }.keyboardShortcut(.defaultAction)
            }.padding(.top, 6)
        }.padding(20).frame(width: 360).background(Palette.pop)
    }
}
