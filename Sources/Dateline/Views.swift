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
    // Event colors and tag dots (Phase 3): red, amber, green, teal, blue, purple, pink, gray.
    static let tags = [c(0xe5484d, 0xec5d61), c(0xd9822b, 0xeb9a4a), c(0x2e9d5b, 0x4cbb7a), c(0x1a9aa8, 0x3cb8c5),
                       c(0x2f6fde, 0x5b8ff0), c(0x8b5cd6, 0xa47be6), c(0xd9478a, 0xe66aa3), c(0x7d7d88, 0x9a9aa5)]
    // A tag keeps the same color everywhere: picked from its letters.
    static func tag(_ name: String) -> Color { tags[name.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) } % tags.count] }
}

extension Store {
    // The event's own color if one was picked, else its calendar's.
    func color(_ it: Item) -> Color { it.color.flatMap { Palette.tags.indices.contains($0) ? Palette.tags[$0] : nil } ?? calendar(it.calendarID)?.color ?? .gray }
}

// Busy = filled dot, Free = ring, Maybe = dotted ring (B17).
struct Mark: View {
    let showAs: ShowAs, color: Color
    var size: CGFloat = 9
    var body: some View {
        switch showAs {
        case .busy: Circle().fill(color).frame(width: size, height: size)
        case .free: Circle().strokeBorder(color, lineWidth: 1.6).frame(width: size, height: size)
        case .maybe: Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 1.5])).frame(width: size, height: size)
        }
    }
}

struct Key: View {
    let k: String
    init(_ k: String) { self.k = k }
    var body: some View {
        Text(k).font(.ui(11)).foregroundStyle(Palette.text2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
    }
}

struct MainView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            if app.sidebarOpen {
                Sidebar(app: app, store: store).frame(width: 236)
                Divider().overlay(Palette.line)
            }
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
                            case .quarter: QuarterView(app: app, store: store)
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
            if let t = app.openTask {
                Divider().overlay(Palette.line)
                TaskDetail(app: app, store: store, task: t).id(t.id).frame(width: 320)
            } else if app.panelOpen, let it = app.selected {
                Divider().overlay(Palette.line)
                DetailPanel(app: app, store: store, item: it).id(it.id).frame(width: 320)
            } else if app.tasksOpen {
                Divider().overlay(Palette.line)
                TaskList(app: app, store: store).frame(width: 320)
            }
        }
        .background(Palette.win)
        .foregroundStyle(Palette.text)
        .font(.ui(13))
        .id(app.look)  // shortcut: rebuilds the whole window (scroll resets); make Look observable if changing it while working gets annoying. Look settings are read while drawing, so a change redraws the whole window
        .sheet(isPresented: $app.showShortcuts) { ShortcutList(app: app) }
        .sheet(isPresented: $app.mapOpen) { PlacesMap(app: app, store: store) }
        .onAppear { app.planTravel(); app.openMain = { [openWindow] in openWindow(id: "main") } }
        .onChange(of: store.soon) { _, _ in app.planTravel() }
        .sheet(item: $app.confirmDelete) { it in ConfirmDelete(app: app, store: store, item: it) }
        .sheet(item: $app.editingSet) { s in SetEditor(app: app, store: store, draft: s) }
        .sheet(isPresented: $app.subscribing) { SubscribeSheet(app: app, store: store) }
        .alert("Couldn't save", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }
}

struct NoAccess: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Dateline can't see your calendars yet").font(.ui(15, weight: .semibold))
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
                    SetList(app: app, store: store)
                    Text("Calendars on this Mac").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
                    let groups = Dictionary(grouping: store.calendars.filter { !isSub($0.id) }, by: \.account)
                    ForEach(groups.keys.sorted(), id: \.self) { acct in
                        Text(acct).font(.ui(11)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        ForEach(groups[acct]!) { c in row(c) }
                    }
                    SubscribedList(app: app, store: store) { AnyView(row($0, trailing: $1)) }
                    if !store.lists.isEmpty {
                        Text("Reminders lists").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).textCase(.uppercase).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
                        ForEach(store.lists) { l in listRow(l) }
                        Text("Untick a list to hide its tasks. Sets remember lists too.").font(.ui(11)).foregroundStyle(Palette.text3)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.top, 4)
                    }
                    let soon = comingUp(store.soon.filter { !store.hidden.contains($0.calendarID) }, now: app.now)
                    if !soon.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("COMING UP").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.bottom, 3)
                            ForEach(Array(soon.enumerated()), id: \.offset) { _, s in
                                HStack(alignment: .top, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2).fill(store.calendar(s.calendarID)?.color ?? .gray).frame(width: 3)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.title).font(.ui(12.5, weight: .semibold)).lineLimit(1)
                                        (Text(s.lead) + Text(s.big).fontWeight(.semibold).foregroundColor(Palette.text) + Text(s.tail))
                                            .font(.ui(11.5)).foregroundStyle(s.dim ? Palette.text3 : Palette.text2)
                                    }
                                }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                            }
                        }
                        .padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.win))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
                        .padding(.horizontal, 8).padding(.top, 12)
                    }
                    if Zones.card && !Zones.list.isEmpty { ZoneCard(now: app.now) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uses your Mac's accounts").font(.ui(12, weight: .semibold))
                        Text("Shows the calendars already set up in your Mac's settings. No separate sign-ins.").foregroundStyle(Palette.text2)
                    }
                    .font(.ui(12))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.lineSoft))
                    .padding(.horizontal, 8).padding(.top, 10)
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            Divider().overlay(Palette.line)
            Text("Your data stays on this Mac").font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Palette.side)
    }

    func listRow(_ l: CalInfo) -> some View {
        let on = !store.hiddenLists.contains(l.id)
        return Button {
            if on { store.hiddenLists.insert(l.id) } else { store.hiddenLists.remove(l.id) }
        } label: {
            HStack(spacing: 8) {
                Tick(on: on, color: l.color)
                Text(l.title).lineLimit(1)
                Spacer()
                Text("\(store.todos.filter { $0.listID == l.id && !$0.done }.count)").font(.ui(11.5)).foregroundStyle(Palette.text3)
            }.padding(.horizontal, 8).padding(.vertical, 4 * Look.packFactor).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func row(_ c: CalInfo, trailing: AnyView? = nil) -> some View {
        let on = !store.hidden.contains(c.id)
        return Button {
            if on { store.hidden.insert(c.id) } else { store.hidden.remove(c.id) }
        } label: {
            HStack(spacing: 8) {
                Tick(on: on, color: c.color)
                Text(c.title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let trailing { trailing }
            }.padding(.horizontal, 8).padding(.vertical, 4 * Look.packFactor).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct Tick: View {
    let on: Bool, color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(on ? color : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.5))
            .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).opacity(on ? 1 : 0))
            .frame(width: 14, height: 14)
    }
}

// Calendar sets at the top of the sidebar (approved Phase 3 mockup). Command 1 is all calendars, Command 2 on the sets.
struct SetList: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        let active = store.activeSet
        let all = store.calendars.allSatisfy { !store.hidden.contains($0.id) }
        VStack(alignment: .leading, spacing: 1) {
            Text("Sets").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).textCase(.uppercase).padding(.horizontal, 8).padding(.bottom, 4)
            row(nil, "All calendars", 1, on: all)
            ForEach(Array(store.sets.enumerated()), id: \.element.id) { i, s in
                row(s, s.name, i + 2, on: !all && active?.id == s.id)
                    .contextMenu {
                        Button("Edit set") { app.editingSet = s }
                        Button("Delete set", role: .destructive) { store.sets.removeAll { $0.id == s.id } }
                    }
            }
            HStack(spacing: 4) {
                Button("+ New set") { app.editingSet = CalSet(name: "", calendars: store.calendars.map(\.id).filter { !store.hidden.contains($0) }) }
                if !store.sets.isEmpty {
                    Text("·")
                    Button("Edit sets") { app.editingSet = active ?? store.sets.first }
                }
            }.buttonStyle(.plain).font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 5)
        }
    }

    func row(_ s: CalSet?, _ name: String, _ n: Int, on: Bool) -> some View {
        Button { app.pickSet(n) } label: {
            HStack(spacing: 8) {
                if let s {
                    HStack(spacing: 2) {
                        ForEach(s.calendars.compactMap(store.calendar).prefix(3)) { RoundedRectangle(cornerRadius: 2).fill($0.color).frame(width: 4, height: 14) }
                    }
                }
                Text(name).fontWeight(on ? .semibold : .regular).lineLimit(1)
                Spacer()
                if n <= 9 { Key("⌘\(n)") }
            }
            .padding(.horizontal, 8).padding(.vertical, 4 * Look.packFactor)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Palette.accentSoft : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// Making or changing a set (approved Phase 3 mockup).
struct SetEditor: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var draft: CalSet
    var body: some View {
        let isNew = !store.sets.contains { $0.id == draft.id }
        let place = (store.sets.firstIndex { $0.id == draft.id } ?? store.sets.count) + 2
        let targets = store.calendars.filter { $0.writable && draft.calendars.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New set" : "Edit set: " + (store.sets.first { $0.id == draft.id }?.name ?? "")).font(.ui(14, weight: .semibold)).padding(.bottom, 14)
            row("Name") { TextField("Family", text: $draft.name).textFieldStyle(.roundedBorder) }
            row("Calendars shown") {
                VStack(spacing: 0) {
                    ForEach(store.calendars) { c in
                        let on = draft.calendars.contains(c.id)
                        Button { if on { draft.calendars.removeAll { $0 == c.id } } else { draft.calendars.append(c.id) } } label: {
                            HStack(spacing: 8) {
                                Tick(on: on, color: c.color)
                                Text(c.title).foregroundStyle(on ? Palette.text : Palette.text2).lineLimit(1)
                                Spacer()
                                Text(c.account).font(.ui(11)).foregroundStyle(Palette.text3).lineLimit(1)
                            }.padding(.horizontal, 10).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            }
            row("New events go to") {
                let c = targets.first { $0.id == draft.defaultCalendar }
                Menu {
                    Button("Your Mac's default") { draft.defaultCalendar = nil }
                    ForEach(targets) { k in Button(k.title + "  (" + k.account + ")") { draft.defaultCalendar = k.id } }
                } label: {
                    HStack(spacing: 6) { Circle().fill(c?.color ?? Palette.text3).frame(width: 8, height: 8); Text(c?.title ?? "Your Mac's default") }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            row("Shortcut") {
                if place <= 9 { HStack(spacing: 8) { Key("⌘\(place)"); Text("set by its place in the list").foregroundStyle(Palette.text3) } }
                else { Text("None: only the first eight sets have one").foregroundStyle(Palette.text3) }
            }
            Text("A typed /code still wins: \"/w\" sends one event to Work while you are in this set.")
                .font(.ui(11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            Divider().overlay(Palette.line).padding(.vertical, 12)
            HStack {
                if !isNew {
                    Button("Delete set") { store.sets.removeAll { $0.id == draft.id }; app.editingSet = nil }.buttonStyle(.plain).foregroundStyle(Palette.now)
                }
                Spacer()
                Button("Cancel") { app.editingSet = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.calendars.isEmpty)
            }
        }
        .padding(20).frame(width: 470).background(Palette.pop)
    }

    func save() {
        var s = draft
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if let d = s.defaultCalendar, !s.calendars.contains(d) { s.defaultCalendar = nil }
        // shortcut: a new or active set keeps the Reminders lists shown now; add list ticks to this editor if that ever confuses.
        if !store.lists.isEmpty, s.lists == nil || store.activeSet?.id == s.id { s.lists = store.lists.map(\.id).filter { !store.hiddenLists.contains($0) } }
        if let i = store.sets.firstIndex(where: { $0.id == s.id }) { store.sets[i] = s } else { store.sets.append(s) }
        store.use(s)
        app.editingSet = nil
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 120, alignment: .leading).padding(.top, 4)
            v().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 10)
    }
}

struct Toolbar: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State private var width: CGFloat = 1000
    @State private var fullScreen = false
    var body: some View {
        // A tight bar first drops the set's name and the Days word; the smallest window's compact bar drops the rest, so the add box and every button stay on screen.
        bar(compact: width < 800, roomy: width >= 1200)
        // With the sidebar gone, the window's close/minimize/zoom buttons sit over the bar's start (not in full screen, where they are not drawn).
        .padding(.leading, app.sidebarOpen || fullScreen ? 14 : 80).padding(.trailing, 14).frame(height: 52)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
        // Still too wide: the end of the bar is cut, never the sidebar or the window.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Palette.bar)
        .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
    }

    func bar(compact: Bool, roomy: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {  // tighter at the smallest window, so the sidebar button still leaves room for the add box
            Button { app.sidebarOpen.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(TButton(icon: true)).fixedSize().help(app.sidebarOpen ? "Hide calendars (S)" : "Show calendars (S)")
            Button("Today") { app.goToday() }.buttonStyle(TButton()).fixedSize()
            HStack(spacing: 4) {
                Button { app.step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(TButton(icon: true))
                Button { app.step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(TButton(icon: true))
            }
            ViewThatFits(in: .horizontal) {
                Text(app.title).fixedSize()
                Text(app.shortTitle).fixedSize()
            }.font(.ui(15, weight: .semibold)).padding(.leading, 4).layoutPriority(2)
            if app.mode != .year && !app.sideOpen && !compact {
                Text(app.weekLabel).font(.ui(11, weight: .medium)).foregroundStyle(Palette.text2)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(Palette.lineSoft)).fixedSize()
            }
            if !app.sideOpen && roomy, let s = store.activeSet, !store.calendars.allSatisfy({ !store.hidden.contains($0.id) }) {
                Text("· \(s.name) set").font(.ui(12)).foregroundStyle(Palette.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if app.mode == .week {
                HStack(spacing: 6) {
                    if !app.sideOpen && roomy { Text("Days").font(.ui(12)).foregroundStyle(Palette.text2) }
                    Seg(options: ["3", "5", "7"], selected: String(app.days), small: true) { app.days = Int($0)! }
                }.fixedSize()
            }
            // With the details panel open there is less room: the views shrink to their first letters (D W M Q Y).
            ViewThatFits(in: .horizontal) {
                Seg(options: Mode.allCases.map(\.rawValue), selected: app.mode.rawValue) { app.mode = Mode(rawValue: $0)! }.fixedSize()
                Seg(options: Mode.allCases.map { String($0.rawValue.prefix(1)) }, selected: String(app.mode.rawValue.prefix(1)), small: compact) { l in
                    app.mode = Mode.allCases.first { $0.rawValue.hasPrefix(l) }!
                }.fixedSize()
            }.layoutPriority(1)
            // Icons in every view (John 2026-10-28); the hover tip names each one and its key.
            Button { app.tasksOpen.toggle() } label: { Image(systemName: "checklist") }
                .buttonStyle(TButton(icon: true)).fixedSize().help("Tasks: Reminders (R)")
            Button { app.mapOpen = true } label: { Image(systemName: "map") }
                .buttonStyle(TButton(icon: true)).fixedSize().help("Map: Events (P)")
            AddBox(app: app).frame(minWidth: compact ? 100 : 130, maxWidth: 300)
            // With a panel open there is no room for it; the ? key still opens the list.
            if !app.sideOpen && !compact { Button("?") { app.showShortcuts = true }.buttonStyle(TButton(icon: true)).help("Keyboard shortcuts") }
        }
    }
}

struct TButton: ButtonStyle {
    var icon = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.ui(13)).foregroundStyle(Palette.text)
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
                    Text(o).font(.ui(small ? 12 : 13, weight: o == selected ? .medium : .regular))
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
            Image(systemName: "plus").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.accent)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT I UNDERSTOOD").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.bottom, 8)
            Understood(app: app, store: store, p: app.preview, pick: nil, menu: true)
            Divider().overlay(Palette.line).padding(.top, 10)
            HStack(spacing: 6) {
                Key("Return"); Text("add"); Key("Esc"); Text("cancel"); Key("Tab"); Text("edit details")
                Spacer()
                Button("Add") { app.commitAdd() }.buttonStyle(.plain)
                    .font(.ui(12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 6).fill(Palette.accent))
            }.font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.top, 10)
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.pop).shadow(color: .black.opacity(0.18), radius: 17, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }

}

// The rows of "What I understood", in the add box preview and the quick add box.
struct Understood: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let p: Parsed, pick: Item?
    var menu = false  // the calendar can be changed from a menu (main add box)
    var body: some View {
        let (c, note) = app.calendar(for: p, pick: pick)
        VStack(alignment: .leading, spacing: 0) {
            row("Title") { Text(p.title.isEmpty ? "New event" : p.title) }
            row("When") { Text(whenText(p)) }
            if !p.place.isEmpty { row("Where") { Text(p.place) } }
            row("Calendar") {
                let label = HStack(spacing: 6) {
                    Circle().fill(c?.color ?? .gray).frame(width: 8, height: 8)
                    Text(c?.title ?? "None")
                    Text(note).foregroundStyle(Palette.text3).fontWeight(.regular)
                }
                if menu {
                    Menu {
                        ForEach(store.calendars.filter(\.writable)) { cal in Button(cal.title + "  (" + cal.account + ")") { app.addCalendarID = cal.id } }
                    } label: { label }.menuStyle(.borderlessButton).fixedSize()
                } else { label }
            }
            if let m = p.alertMinutes {
                let code = m % 1440 == 0 ? "\(m / 1440)d" : m % 60 == 0 ? "\(m / 60)h" : "\(m)m"
                row("Alert") { HStack(spacing: 4) { Text(alertText(m)); Text("(from -a\(code))").foregroundStyle(Palette.text3).fontWeight(.regular) } }
            }
            if let r = p.repeats { row("Repeat") { HStack(spacing: 4) { Text(r.text); Text(verbatim: "(from -r\(r.n)\(r.unit))").foregroundStyle(Palette.text3).fontWeight(.regular) } } }
            row("Show as") { HStack(spacing: 6) { Mark(showAs: p.showAs, color: c?.color ?? .gray); Text(p.showAs.rawValue) } }
        }
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(k).foregroundStyle(Palette.text3).frame(width: 78, alignment: .leading)
            v().fontWeight(.medium)
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
}

// The quick add box that opens over any app (approved Phase 2 mockup).
struct QuickAddView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @FocusState private var focused: Bool
    var body: some View {
        let list = app.quickSuggestions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.ui(16, weight: .semibold)).foregroundStyle(Palette.accent)
                TextField("Lunch with Sam tomorrow 1pm /Personal -a15m", text: $app.quickText)
                    .textFieldStyle(.plain).font(.ui(18)).focused($focused)
                    .onSubmit { app.commitQuick() }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            if !list.isEmpty {
                section("FROM YOUR PAST EVENTS")
                ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                    let c = store.calendar(it.calendarID)
                    HStack(spacing: 10) {
                        Circle().fill(c?.color ?? .gray).frame(width: 9, height: 9)
                        Text(it.title).fontWeight(.semibold).lineLimit(1)
                        Text(([it.place, c?.title ?? ""].filter { !$0.isEmpty } + ["last on " + dateText(it.start, "MMM d")]).joined(separator: " · "))
                            .font(.ui(12)).foregroundStyle(Palette.text2).lineLimit(1)
                        Spacer(minLength: 0)
                        if i == app.quickSel { Key("Tab") }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(i == app.quickSel ? Palette.accentSoft : .clear)
                    .contentShape(Rectangle()).onTapGesture { app.quickPick = it }
                }
            }
            if !app.quickText.trimmingCharacters(in: .whitespaces).isEmpty {
                section("WHAT I UNDERSTOOD")
                Understood(app: app, store: store, p: app.quickPreview, pick: app.quickPick).padding(.horizontal, 16).padding(.bottom, 10)
            }
            HStack(spacing: 14) {
                code(["/name"], "calendar"); code(["-a15m", "-a1h", "-a1d"], "alert before"); code(["-r1d", "-r1w", "-r1m"], "repeat")
            }
            .font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Palette.line.frame(height: 1) }
            HStack(spacing: 6) {
                Key("Return"); Text("add"); Key("Tab"); Text("use past event"); Key("Esc"); Text("close")
                Spacer()
                if let err = app.quickError { Text(err).foregroundStyle(Palette.now) }
                else { Text(app.quickTaken ? "Another app uses \(app.quickName). Change it in Settings" : "Shortcut can be changed in Settings") }
            }
            .font(.ui(12)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 10)
            .background(Palette.bar).overlay(alignment: .top) { Palette.line.frame(height: 1) }
        }
        .font(.ui(13)).foregroundStyle(Palette.text)
        .frame(width: 640)
        .background(Palette.pop)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.38), radius: 40, y: 30)
        .padding(.top, 10)
        .onAppear { focused = true }
        .onChange(of: app.quickFocus) { _, _ in focused = true }
    }

    func section(_ t: String) -> some View {
        Text(t).font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
    }

    func code(_ codes: [String], _ what: String) -> some View {
        HStack(spacing: 4) { ForEach(codes, id: \.self) { Text($0).fontWeight(.semibold).foregroundStyle(Palette.accent) }; Text(what) }
    }
}

// Dateline, Settings (Command comma): the quick add shortcut, and the Look tab (Phase 3).
struct SettingsView: View {
    @ObservedObject var app: AppState
    var body: some View {
        TabView {
            QuickSettings(app: app).tabItem { Label("Quick add", systemImage: "plus.square") }
            LookSettings(app: app).tabItem { Label("Look", systemImage: "paintpalette") }
            WeekSettings(app: app).tabItem { Label("Week", systemImage: "calendar") }
            AlertSettings(app: app, store: app.store).tabItem { Label("Alerts", systemImage: "bell") }
            ZoneSettings(app: app).tabItem { Label("Time zones", systemImage: "globe") }
            MenuBarSettings(app: app).tabItem { Label("Menu bar", systemImage: "menubar.rectangle") }
            WeatherSettings(app: app).tabItem { Label("Weather", systemImage: "cloud.sun") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }
}

struct QuickSettings: View {
    @ObservedObject var app: AppState
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick add from any app")
                Spacer()
                Button(app.recordingKey ? "Press the new shortcut" : app.quickName) { record() }
            }
            Text(app.quickTaken || app.keyRefused ? "Another app already uses this shortcut. Pick a different one." : "Opens the add box on top of whatever app is in front. Use Control, Option or Command with a key; Esc cancels.")
                .font(.ui(11.5)).foregroundStyle(app.quickTaken || app.keyRefused ? Palette.now : Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 440)
        .onDisappear { stop() }
        .font(.ui(13))
    }

    func record() {
        guard monitor == nil else { return }
        app.recordingKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode != 53, !e.modifierFlags.intersection([.command, .option, .control]).isEmpty { app.setQuickKey(e) }
            stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        app.recordingKey = false
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
            HStack(spacing: 5) { Key("1"); Text("to"); Key("5"); Text("day to year") }
            HStack(spacing: 5) { Key("?"); Text("all shortcuts") }
            Spacer()
            ForEach(ShowAs.allCases, id: \.self) { s in HStack(spacing: 5) { Mark(showAs: s, color: Palette.text3); Text(s.rawValue) } }
        }
        .font(.ui(11.5)).foregroundStyle(Palette.text3)
        .padding(.horizontal, 14).frame(height: 30)
        .background(Palette.bar)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
}

struct ShortcutList: View {
    @ObservedObject var app: AppState
    var rows: [(String, String)] { [
        ("New event", "N"), ("Go to today", "T"), ("Day view", "1"), ("Previous", "Left"), ("Week view", "2"), ("Next", "Right"),
        ("Month view", "3"), ("Next or previous event", "Up / Down"), ("Quarter view", "4"), ("Open event", "Return"), ("Year view", "5"),
        ("Delete event", "Delete"), ("Move event 15 min", "Option Up / Down"), ("Copy event", "Option drag"), ("Undo", "Command Z"), ("This list", "?"),
        ("Quick add from any app", app.quickName), ("All calendars", "Command 1"), ("Calendar sets", "Command 2 to 9"), ("Tasks", "R"), ("Map of places", "P"), ("Hide or show calendars", "S"),
    ] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts").font(.ui(15, weight: .semibold)).padding(.bottom, 12)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], spacing: 0) {
                ForEach(rows, id: \.0) { r in
                    VStack(spacing: 0) {
                        HStack { Text(r.0).lineLimit(1); Spacer(minLength: 6); Key(r.1) }.padding(.vertical, 5)
                        Divider().overlay(Palette.lineSoft)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { app.showShortcuts = false }.keyboardShortcut(.defaultAction) }.padding(.top, 12)
        }.padding(20).frame(width: 560).background(Palette.pop)
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
            Text("Delete \u{201C}\(item.title)\u{201D}?").font(.ui(15, weight: .semibold))
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
