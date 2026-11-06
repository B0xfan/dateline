// The window: sidebar, toolbar with the add box, the view area, the shortcut bar. Colours and sizes follow the approved mockups.
import SwiftUI
import AppKit
import DatelineCore

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
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
    }
}

struct MainView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @ObservedObject var panels: Panels
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var width: CGFloat = 1000  // the calendar's width: narrow toolbars use short words

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { app.sidebarOpen ? .all : .detailOnly }, set: { app.sidebarOpen = $0 != .detailOnly })) {
            Sidebar(app: app, store: store).navigationSplitViewColumnWidth(236)
        } detail: {
            VStack(spacing: 0) {
                if width < 700 { AddBox(app: app, box: app.addBox).frame(height: 32).padding(.horizontal, 8); Divider().overlay(Palette.line) }
                TrialEndedStrip()
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
                    if let t = panels.toast { ToastView(app: app, toast: t).padding(.bottom, 16) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { PreviewSpot(app: app, store: store, box: app.addBox) }
                StatusBar()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(app.mode == .week && width < 560 ? dateText(app.anchor, "MMM") : width < 700 ? app.shortTitle : app.title)
            .navigationSubtitle(width < 700 && app.mode != .year ? app.weekLabel : app.subtitle)
            .toolbar { toolbar }
        }
        .inspector(isPresented: Binding(get: { app.openTask != nil || (panels.panelOpen && app.selected != nil) || panels.tasksOpen }, set: { if !$0 { app.closeSide() } })) {
            // The sliver keeps a panel's scroll view off the top edge: touching it, the system draws the panel a toolbar's height below where its clicks land.
            VStack(spacing: 0) { Color.clear.frame(height: 1); Group {
                if let t = app.openTask {
                    if t.a4 != nil { A4TaskDetail(app: app, store: store, task: t).id(t.id) } else { TaskDetail(app: app, store: store, task: t).id(t.id) }
                } else if panels.panelOpen, let it = app.selected {
                    DetailPanel(app: app, store: store, item: it).id(it.id)
                } else if panels.tasksOpen {
                    TaskList(app: app, store: store, panel: app.taskPanel)
                }
            } }
            .inspectorColumnWidth(min: 320, ideal: 320, max: 320)
        }
        .background(Palette.win)
        .foregroundStyle(Palette.text)
        .font(.ui(13))
        .id(app.look)  // shortcut: rebuilds the whole window (scroll resets); make Look observable if changing it while working gets annoying. Look settings are read while drawing, so a change redraws the whole window
        .sheet(isPresented: $panels.showShortcuts) { ShortcutList(app: app) }
        .sheet(isPresented: $panels.mapOpen) { PlacesMap(app: app, store: store) }
        .onAppear { app.planTravel(); app.openMain = { [openWindow] in openWindow(id: "main") } }
        .onChange(of: store.soon) { _, _ in app.planTravel() }
        .onReceive(app.emails.$items) { items in if let r = panels.reviewing, !items.contains(where: { $0.id == r }) { panels.reviewing = nil } }  // the email left the folder
        .sheet(item: $panels.confirmDelete) { it in ConfirmDelete(app: app, store: store, item: it) }
        .sheet(item: $panels.editingSet) { s in SetEditor(app: app, store: store, draft: s) }
        .sheet(isPresented: $panels.subscribing) { SubscribeSheet(app: app, store: store) }
        .sheet(isPresented: Binding(get: { panels.reviewing != nil }, set: { if !$0 { panels.reviewing = nil } })) {
            if let p = app.emails.items.first(where: { $0.id == panels.reviewing }) { EmailReview(app: app, p: p) }
        }
        .alert(app.error?.hasSuffix(License.endedMessage) == true ? "Adding and changing events is off" : "Couldn't save", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            if app.error?.hasSuffix(License.endedMessage) == true {
                Button("Buy · \(License.price)") { License.shared.buy() }
                Button("Enter key") { openLicense(openSettings) }
                Button("Not now", role: .cancel) {}
            } else { Button("OK") { app.error = nil } }
        } message: { Text(app.error ?? "") }
    }

    // Three groups, as Apple's own apps: moving through time, what to show, and tasks, map and the add box.
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Today") { app.goToday() }.help("Go to today (T)")
            Button("Previous", systemImage: "chevron.left") { app.step(-1) }.help("Go back (Left arrow)")
            Button("Next", systemImage: "chevron.right") { app.step(1) }.help("Go forward (Right arrow)")
        }
        // Narrow windows give up the smaller controls first; each is still in the menus and on its key. The add box moves under the toolbar, so it never lands behind the "more" arrow.
        ToolbarItemGroup(placement: .principal) {
            if app.mode == .week && width >= 800 {
                Picker("Days", selection: $app.days) { ForEach([3, 5, 7], id: \.self) { Text(String($0)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().help("Days to show in the week")
            }
            Picker("View", selection: $app.mode) {
                ForEach(Mode.allCases, id: \.self) { m in Text(width < 800 ? String(m.rawValue.prefix(1)) : m.rawValue).tag(m).accessibilityLabel(m.rawValue) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize().help("Day to year (keys 1 to 5)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if width >= 700 {
                Button("Tasks", systemImage: "checklist") { panels.tasksOpen.toggle() }.help("Show or hide tasks (R)")
                Button("Map", systemImage: "map") { panels.mapOpen = true }.help("Show this view's places on a map (P)")
                AddBox(app: app, box: app.addBox).frame(width: width < 800 ? 160 : 260)
            }
        }
    }
}

struct NoAccess: View {
    var body: some View {
        VStack(spacing: 12) {
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
            // The sliver keeps the scroll view off the top edge, as in the side panels: touching it, the rows are drawn a toolbar's height below where their clicks land.
            Color.clear.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    FromEmailList(app: app, inbox: app.emails)
                    SetList(app: app, store: store)
                    Text("Calendars on this Mac").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                    let groups = Dictionary(grouping: store.calendars.filter { !isSub($0.id) }, by: \.account)
                    ForEach(groups.keys.sorted(), id: \.self) { acct in
                        heading(acct, count: groups[acct]!.count, font: .ui(11)).padding(.top, 8).padding(.bottom, 2)
                        if !folded.contains(acct) { ForEach(groups[acct]!) { c in row(c) } }
                    }
                    SubscribedList(app: app, store: store) { AnyView(row($0, trailing: $1)) }
                    let lists = store.lists.filter { $0.account != a4Account }  // A4 has one list per project; its switch is in Settings
                    if !lists.isEmpty {
                        heading(Self.listsGroup, count: lists.count, font: .ui(11, weight: .semibold), upper: true).padding(.top, 12).padding(.bottom, 4)
                        if !folded.contains(Self.listsGroup) { ForEach(lists) { l in listRow(l) } }
                    }
                    OnClock(clock: app.clock) { now in
                        let soon = comingUp(store.soon.filter { !store.hidden.contains($0.calendarID) }, now: now)
                        if !soon.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("COMING UP").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.bottom, 4)
                                ForEach(Array(soon.enumerated()), id: \.offset) { _, s in
                                    HStack(alignment: .top, spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2).fill(store.calendar(s.calendarID)?.color ?? .gray).frame(width: 4)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(s.title).font(.ui(13, weight: .semibold)).lineLimit(1)
                                            (Text(s.lead) + Text(s.big).fontWeight(.semibold).foregroundColor(Palette.text) + Text(s.tail))
                                                .font(.ui(12)).foregroundStyle(s.dim ? Palette.text3 : Palette.text2)
                                        }
                                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.win))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                            .padding(.horizontal, 8).padding(.top, 12)
                        }
                    }
                    if Zones.card && !Zones.list.isEmpty { OnClock(clock: app.clock) { ZoneCard(now: $0) } }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            TrialCard()
            Divider().overlay(Palette.line)
            Text("Your data stays on this Mac").font(.ui(12)).foregroundStyle(Palette.text3).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    // Each account and the Reminders lists fold shut with a click on the heading, so Coming up fits (James 2026-11-05). Kept on this Mac.
    @AppStorage("foldedGroups") private var foldedRaw = ""
    static let listsGroup = "Reminders lists"
    var folded: Set<String> { Set(foldedRaw.split(separator: "\n").map(String.init)) }

    func heading(_ name: String, count: Int, font: Font, upper: Bool = false) -> some View {
        let open = !folded.contains(name)
        return Button {
            var f = folded
            if open { f.insert(name) } else { f.remove(name) }
            foldedRaw = f.sorted().joined(separator: "\n")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                Text(name).textCase(upper ? .uppercase : nil).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").monospacedDigit()
            }.font(font).foregroundStyle(Palette.text3).padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(open ? "Fold \(name) shut" : "Show \(name)")
        .accessibilityLabel(name).accessibilityValue(open ? "open" : "folded")
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
                Text("\(store.todos.filter { $0.listID == l.id && !$0.done }.count)").font(.ui(12)).foregroundStyle(Palette.text3)
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
            .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).opacity(on ? 1 : 0))
            .frame(width: 16, height: 16)
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
            row(nil, "All calendars", 1, on: all).contextMenu { Button("New Set…") { app.newSet() } }
            ForEach(Array(store.sets.enumerated()), id: \.element.id) { i, s in
                row(s, s.name, i + 2, on: !all && active?.id == s.id)
                    .contextMenu {
                        Button("New Set…") { app.newSet() }
                        Button("Edit set") { app.panels.editingSet = s }
                        Button("Delete set", role: .destructive) { store.deleteSet(s.id) }
                    }
            }
        }
    }

    func row(_ s: CalSet?, _ name: String, _ n: Int, on: Bool) -> some View {
        Button { app.pickSet(n) } label: {
            HStack(spacing: 8) {
                if let s {
                    HStack(spacing: 2) {
                        ForEach(s.calendars.compactMap(store.calendar).prefix(3)) { RoundedRectangle(cornerRadius: 2).fill($0.color).frame(width: 4, height: 16) }
                    }
                }
                Text(name).fontWeight(on ? .semibold : .regular).lineLimit(1)
                Spacer()
                if n <= 9 { Key("⌘\(n)") }
            }
            .padding(.horizontal, 8).padding(.vertical, 4 * Look.packFactor)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Palette.accentSoft : .clear))
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
            Text(isNew ? "New set" : "Edit set: " + (store.sets.first { $0.id == draft.id }?.name ?? "")).font(.ui(14, weight: .semibold)).padding(.bottom, 12)
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
                            }.padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            }
            row("New events go to") {
                let c = targets.first { $0.id == draft.defaultCalendar }
                Menu {
                    Button("Your Mac's default") { draft.defaultCalendar = nil }
                    ForEach(targets) { k in Button(k.title + "  (" + k.account + ")") { draft.defaultCalendar = k.id } }
                } label: {
                    HStack(spacing: 8) { Circle().fill(c?.color ?? Palette.text3).frame(width: 8, height: 8); Text(c?.title ?? "Your Mac's default") }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            row("Shortcut") {
                if place <= 9 { HStack(spacing: 8) { Key("⌘\(place)"); Text("set by its place in the list").foregroundStyle(Palette.text3) } }
                else { Text("None: only the first eight sets have one").foregroundStyle(Palette.text3) }
            }
            Text("A typed /code still wins: \"/w\" sends one event to Work while you are in this set.")
                .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            Divider().overlay(Palette.line).padding(.vertical, 12)
            HStack {
                if !isNew {
                    Button("Delete set") { store.deleteSet(draft.id); app.panels.editingSet = nil }.buttonStyle(.plain).foregroundStyle(Palette.now)
                }
                Spacer()
                Button("Cancel") { app.panels.editingSet = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.calendars.isEmpty)
            }
        }
        .padding(20).frame(width: 472).background(Palette.pop)
    }

    func save() {
        var s = draft
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if let d = s.defaultCalendar, !s.calendars.contains(d) { s.defaultCalendar = nil }
        // shortcut: a new or active set keeps the Reminders lists shown now; add list ticks to this editor if that ever confuses.
        if !store.lists.isEmpty, s.lists == nil || store.activeSet?.id == s.id { s.lists = store.lists.map(\.id).filter { !store.hiddenLists.contains($0) } }
        if let i = store.sets.firstIndex(where: { $0.id == s.id }) { store.sets[i] = s } else { store.sets.append(s) }
        store.use(s)
        app.panels.editingSet = nil
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 120, alignment: .leading).padding(.top, 4)
            v().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 8)
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(o == selected ? Palette.field : .clear).shadow(color: .black.opacity(o == selected ? 0.15 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Palette.lineSoft))
    }
}

struct AddBox: View {
    static let placeholder = "Add: Dinner with Ana Friday 7pm"
    @ObservedObject var app: AppState
    @ObservedObject var box: AddText
    @ObservedObject private var lic = License.shared
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lic.canEdit ? "plus" : "lock").font(.ui(11, weight: .semibold)).foregroundStyle(lic.canEdit ? Palette.accent : Palette.text3)
            TextField(lic.canEdit ? AddBox.placeholder : "Adding is off", text: $box.text, onEditingChanged: { box.focused = $0 })  // in the toolbar the focus switch alone missed the typing, so the preview card never showed
                .textFieldStyle(.plain).focused($focused).disabled(!lic.canEdit)
                .onSubmit { app.commitAdd() }
        }
        .padding(.horizontal, 8)
        .accessibilityLabel("Add an event")
        .onChange(of: focused) { _, f in box.focused = f }
        .onDisappear { box.focused = false }  // it moves under the toolbar in a narrow window; a stale "focused" would turn the next Tab into a new event
        .onChange(of: box.focused) { _, f in if !f { focused = false } }
        .onChange(of: box.focusAsks) { _, _ in focused = true }
    }
}

// Watches the typing, so only the preview redraws with each letter.
struct PreviewSpot: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @ObservedObject var box: AddText
    var body: some View {
        if box.focused && !box.text.isEmpty { PreviewCard(app: app, store: store, p: app.preview).padding(.trailing, 16).padding(.top, 8) }
    }
}

// "What I understood": the live preview under the add box (A2).
struct PreviewCard: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let p: Parsed
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT I UNDERSTOOD").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.bottom, 8)
            Understood(app: app, store: store, box: app.addBox, p: p, pick: nil, menu: true)
            Divider().overlay(Palette.line).padding(.top, 8)
            HStack(spacing: 8) {
                Key("Return"); Text("add"); Key("Esc"); Text("cancel"); Key("Tab"); Text("edit details")
                Spacer()
                Button("Add") { app.commitAdd() }.buttonStyle(.plain)
                    .font(.ui(12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent))
            }.font(.ui(12)).foregroundStyle(Palette.text3).padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pop).shadow(color: .black.opacity(0.18), radius: 17, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }

}

// The rows of "What I understood", in the add box preview and the quick add box.
struct Understood: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @ObservedObject var box: AddText  // the calendar picked from its menu
    let p: Parsed, pick: Item?
    var menu = false  // the calendar can be changed from a menu (main add box)
    var body: some View {
        let (c, note) = app.calendar(for: p, pick: pick)
        VStack(alignment: .leading, spacing: 0) {
            row("Title") { Text(p.title.isEmpty ? "New event" : p.title) }
            row("When") { Text(whenText(p)) }
            if !p.place.isEmpty { row("Where") { Text(p.place) } }
            row("Calendar") {
                let label = HStack(spacing: 8) {
                    Circle().fill(c?.color ?? .gray).frame(width: 8, height: 8)
                    Text(c?.title ?? "None")
                    Text(note).foregroundStyle(Palette.text3).fontWeight(.regular)
                }
                if menu {
                    Menu {
                        ForEach(store.calendars.filter(\.writable)) { cal in Button(cal.title + "  (" + cal.account + ")") { box.calendarID = cal.id } }
                    } label: { label }.menuStyle(.borderlessButton).fixedSize()
                } else { label }
            }
            if let m = p.alertMinutes {
                let code = m % 1440 == 0 ? "\(m / 1440)d" : m % 60 == 0 ? "\(m / 60)h" : "\(m)m"
                row("Alert") { HStack(spacing: 4) { Text(alertText(m)); Text("(from -a\(code))").foregroundStyle(Palette.text3).fontWeight(.regular) } }
            }
            if let r = p.repeats { row("Repeat") { HStack(spacing: 4) { Text(r.text); Text(verbatim: "(from -r\(r.n)\(r.unit))").foregroundStyle(Palette.text3).fontWeight(.regular) } } }
            row("Show as") { HStack(spacing: 8) { Mark(showAs: p.showAs, color: c?.color ?? .gray); Text(p.showAs.rawValue) } }
        }
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(k).foregroundStyle(Palette.text3).frame(width: 80, alignment: .leading)
            v().fontWeight(.medium)
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
}

// Dateline, Settings (Command comma). Eight tabs at most, all wide enough to show every tab, so none is pushed into
// the toolbar's » menu, which shows them greyed out (John 2026-11-05). The render draws these same tabs (settings-window).
@MainActor func settingsTabs(_ app: AppState) -> [(tag: String, label: String, icon: String, view: AnyView)] {
    func stack(_ parts: [AnyView]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) { ForEach(parts.indices, id: \.self) { i in if i > 0 { Divider() }; parts[i] } })
    }
    var tabs: [(tag: String, label: String, icon: String, view: AnyView)] = [
        ("quick", "General", "gearshape", stack([AnyView(QuickSettings(app: app, quick: app.quick)), AnyView(LicenseSettings()), AnyView(UpdateSettings())])),
        ("accounts", "Accounts", "person.crop.circle", AnyView(AccountSettings(store: app.store))),
        ("look", "Look", "paintpalette", stack([AnyView(LookSettings(app: app)), AnyView(MenuBarSettings(app: app))])),
        ("week", "Week", "calendar", AnyView(WeekSettings(app: app))),
        ("alerts", "Alerts", "bell", AnyView(AlertSettings(app: app, store: app.store))),
        ("zones", "Time & weather", "globe", stack([AnyView(ZoneSettings(app: app)), AnyView(WeatherSettings(app: app))])),
        ("assistant", "Assistant", "sparkles", AnyView(AssistantSettings(app: app, a: Assistant.shared))),
    ]
    if app.store.a4Here { tabs.insert(("a4", "A4 tasks", "checklist", AnyView(A4Settings(store: app.store))), at: 6) }
    return tabs.map { ($0.tag, $0.label, $0.icon, AnyView($0.view.frame(minWidth: 700, alignment: .topLeading))) }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    @AppStorage("settingsTab") private var tab = "quick"  // the attachments hint opens Accounts, Enter key opens General
    var body: some View {
        let tabs = settingsTabs(app)
        TabView(selection: $tab) {
            ForEach(tabs, id: \.tag) { t in t.view.tabItem { Label(t.label, systemImage: t.icon) }.tag(t.tag) }
        }
        // A tab picked in an older copy, now folded into another, or the hidden A4 tab.
        .onAppear { tab = ["menubar": "look", "weather": "zones", "updates": "quick", "license": "quick"][tab] ?? (tabs.contains { $0.tag == tab } ? tab : "quick") }
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
        // Too narrow for the key hints: only the Busy, Free, Maybe legend.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                HStack(spacing: 4) { Key("N"); Text("new") }
                HStack(spacing: 4) { Key("T"); Text("today") }
                HStack(spacing: 4) { Key("1"); Text("to"); Key("5"); Text("day to year") }
                HStack(spacing: 4) { Key("?"); Text("all shortcuts") }
                Spacer()
                legend
            }
            HStack(spacing: 16) { Spacer(); legend }
        }
        .font(.ui(12)).foregroundStyle(Palette.text3)
        .padding(.horizontal, 16).frame(height: 32)
        .background(Palette.bar)
        .overlay(alignment: .top) { Palette.line.frame(height: 1) }
    }
    var legend: some View { ForEach(ShowAs.allCases, id: \.self) { s in HStack(spacing: 4) { Mark(showAs: s, color: Palette.text3); Text(s.rawValue) } } }
}

struct ShortcutList: View {
    @ObservedObject var app: AppState
    var rows: [(String, String)] { [
        ("New event", "N"), ("Go to today", "T"), ("Day view", "1"), ("Previous", "Left"), ("Week view", "2"), ("Next", "Right"),
        ("Month view", "3"), ("Next or previous event", "Up / Down"), ("Quarter view", "4"), ("Open event", "Return"), ("Year view", "5"),
        ("Delete event", "Delete"), ("Move event 15 min", "Option Up / Down"), ("Copy event", "Option drag"), ("Undo", "Command Z"), ("This list", "?"),
        ("Quick add from any app", app.quick.name), ("All calendars", "Command 1"), ("Calendar sets", "Command 2 to 9"), ("Tasks", "R"), ("Map of places", "P"), ("Hide or show calendars", "S"),
    ] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts").font(.ui(15, weight: .semibold)).padding(.bottom, 12)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], spacing: 0) {
                ForEach(rows, id: \.0) { r in
                    VStack(spacing: 0) {
                        HStack { Text(r.0).lineLimit(1); Spacer(minLength: 6); Key(r.1) }.padding(.vertical, 4)
                        Divider().overlay(Palette.lineSoft)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { app.panels.showShortcuts = false }.keyboardShortcut(.defaultAction) }.padding(.top, 12)
        }.padding(20).frame(width: 560).background(Palette.pop)
    }
}

struct ToastView: View {
    @ObservedObject var app: AppState
    let toast: AppState.Toast
    var body: some View {
        HStack(spacing: 12) {
            Text("Deleted \u{201C}\(toast.text)\u{201D} from \(toast.calendar)")
            Button("Undo") { app.undo() }.buttonStyle(.plain).foregroundStyle(Palette.accent).fontWeight(.semibold)
            Key("Command Z")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pop).shadow(color: .black.opacity(0.18), radius: 12, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }
}

struct ConfirmDelete: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let item: Item
    var body: some View {
        let c = store.calendar(item.calendarID)?.title ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \u{201C}\(item.title)\u{201D}?").font(.ui(15, weight: .semibold))
            Text("This removes it from your \(c) calendar on this Mac and on every device that syncs it. You can undo right after.")
                .foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { app.panels.confirmDelete = nil }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { app.panels.confirmDelete = nil; app.delete(item) }.keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }.padding(20).frame(width: 360).background(Palette.pop)
    }
}

