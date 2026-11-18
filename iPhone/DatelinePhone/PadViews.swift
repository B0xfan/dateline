// The iPad at full width (approved pictures 2026-11-18, board X4vcraNiNh5Ltv2yAGT8ao): the calendar column on the left,
// Calendar, Tasks, Places and Settings at the top, and the Mac's 3, 5 or 7 day week. Held upright the column hides until its button is tapped.
import SwiftUI
import DatelineCore

struct PadRoot: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        HStack(spacing: 0) {
            if app.column && app.tab == .calendar {
                CalColumn().frame(width: 290).transition(.move(edge: .leading))
                Rectangle().fill(T.line).frame(width: 1).ignoresSafeArea()
            }
            VStack(spacing: 0) {
                PadTopBar()
                switch app.tab {
                case .calendar: CalendarTab()
                case .tasks: TasksView()
                case .places: PlacesView()
                case .settings: SettingsView()
                }
            }
        }
        // Measured without the keyboard, which would otherwise make an upright iPad look sideways.
        .background(GeometryReader { g in
            let portrait = g.size.height > g.size.width
            Color.clear.onChange(of: portrait, initial: true) {  // turning the iPad resets the column to its default; a Split View round trip keeps your choice
                if app.portrait != portrait { app.column = !portrait }
                app.portrait = portrait
            }
        }.ignoresSafeArea(.keyboard))
        .modifier(SidewaysPicture(on: app.demoSideways))
    }
}

/// Pictures only: the simulator can't turn an iPad from the script, so the sideways layout is drawn turned a quarter and the script turns the picture back.
private struct SidewaysPicture: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            GeometryReader { g in
                content.frame(width: g.size.height, height: g.size.width).rotationEffect(.degrees(90)).position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .ignoresSafeArea().statusBarHidden()
        } else { content }
    }
}

/// The top bar: the column button, the four tabs in the middle, and on the calendar the emails, Today and add.
struct PadTopBar: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        let onCal = app.tab == .calendar
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if onCal {
                    Button { withAnimation(.easeOut(duration: 0.2)) { app.column.toggle() } } label: {
                        Image(systemName: "sidebar.left").frame(width: 44, height: 44).background(T.bg2, in: Circle())
                    }
                    .accessibilityLabel(app.column ? "Hide the calendar column" : "Show the calendar column")
                    if app.portrait && !app.column { SetMenu() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(PhoneState.Tab.allCases, id: \.self) { t in
                    let on = app.tab == t
                    Button(t.rawValue) { app.tab = t }
                        .font(.subheadline.weight(on ? .semibold : .regular)).foregroundStyle(on ? T.tint : T.text)
                        .padding(.horizontal, 16).frame(minHeight: 36)
                        .background(on ? T.card : .clear, in: Capsule()).shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1.5, y: 1)
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4).background(T.bg2, in: Capsule()).fixedSize()
            HStack(spacing: 6) {
                if onCal {
                    EmailButton().background(T.bg2, in: Circle())
                    Button { app.searching = true } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).background(T.bg2, in: Circle()) }
                        .accessibilityLabel("Search")
                    if !app.portrait { Button("Today") { app.goToday() }.font(.body.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 44).background(T.bg2, in: Capsule()) }
                    Button { app.adding = "" } label: { Image(systemName: "plus").foregroundStyle(.white).frame(width: 44, height: 44).background(T.tint, in: Circle()) }
                        .accessibilityLabel("Add an event or task")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(T.tint).buttonStyle(.plain)
        .padding(.horizontal, 16).frame(minHeight: 60)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(T.bg)
    }
}

/// The calendar's title row on the iPad: the dates and week number (tap to go to a date), back and on, then the day count and the view.
struct PadCalHeader: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var jumping = false
    var body: some View {
        HStack(spacing: 12) {
            Button { jumping = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title2.bold()).foregroundStyle(T.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text(sub).font(.footnote).foregroundStyle(T.text2).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .layoutPriority(1).accessibilityAddTraits(.isHeader).accessibilityHint("Go to a date")
            HStack(spacing: 0) {
                Button { app.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }.accessibilityLabel("Previous")
                Button { app.step(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }.accessibilityLabel("Next")
            }
            .font(.title3).foregroundStyle(T.tint)
            if app.portrait { Button("Today") { app.goToday() }.font(.body.weight(.semibold)).foregroundStyle(T.tint).padding(.horizontal, 8).frame(minHeight: 44) }
            Spacer(minLength: 0)
            // Narrow Split View or large text: the 3, 5, 7 picker steps aside so the dates stay readable.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { if app.mode == .week { daysPicker }; viewPicker }
                viewPicker
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 20).padding(.trailing, 16).frame(minHeight: 56)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(T.bg)
        .overlay(alignment: .bottom) { if app.mode != .week { Rectangle().fill(T.line).frame(height: 0.5) } }
        .sheet(isPresented: $jumping) { GoToDate(day: app.anchor) { app.anchor = cal.startOfDay(for: $0) } }
    }

    private var daysPicker: some View {
        Picker("Days", selection: $app.weekDays) { ForEach([3, 5, 7], id: \.self) { Text("\($0)").tag($0) } }
            .pickerStyle(.segmented).fixedSize().accessibilityLabel("Days shown")
    }

    // Quarter has no segment (it opens from the month, as on the phone), so none is lit while it shows.
    private var viewPicker: some View {
        Picker("View", selection: $app.mode) {
            ForEach([PhoneState.Mode.day, .week, .month, .year], id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize()
    }

    /// The Mac's titles: "October 26 to 30, 2026", "Oct 26 to Nov 1, 2026".
    private var title: String {
        let a = app.days[0], b = app.days.last!
        switch app.mode {
        case .week where a != b:
            if cal.isDate(a, equalTo: b, toGranularity: .month) { return dateText(a, "MMMM d") + " to " + dateText(b, "d, yyyy") }
            return dateText(a, "MMM d") + " to " + dateText(b, "MMM d, yyyy")
        case .day, .week: return dateText(a, "EEEE, MMMM d, yyyy")
        case .month, .list: return dateText(app.anchor, "MMMM yyyy")
        case .quarter: let q = quarterStart(app.anchor); return dateText(q, "MMM") + " to " + dateText(cal.date(byAdding: .month, value: 2, to: q)!, "MMM yyyy")
        case .year: return dateText(app.anchor, "yyyy")
        }
    }

    /// "Week 44 · Family set"
    private var sub: String {
        ["Week \(weekNumber(app.mode == .day || app.mode == .week ? app.days[0] : app.anchor))", store.activeSet.map { "\($0.name) set" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The calendar column: events found in emails, the sets, then each calendar and Reminders list with its tick.
struct CalColumn: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !app.emails.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("FROM EMAIL"); Spacer(); Text("\(app.emails.count)") }.modifier(ColumnLabel())
                        ForEach(app.emails) { f in
                            Button { app.email = f } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.parsed.title).font(.subheadline.weight(.semibold)).foregroundStyle(T.text).lineLimit(2)
                                        Text("From \(f.from)").font(.footnote).foregroundStyle(T.text2).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Text("New").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2).background(T.tint, in: Capsule())
                                }
                                .padding(.vertical, 6).padding(.horizontal, 4).contentShape(Rectangle())
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SETS").modifier(ColumnLabel())
                    setRow("All calendars", colors: [], on: store.activeSet == nil && store.hidden.isEmpty) { store.use(nil) }
                    ForEach(store.sets) { s in
                        setRow(s.name, colors: s.calendars.prefix(3).compactMap { store.calendar($0)?.color }, on: store.activeSet?.id == s.id) { store.use(s) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("CALENDARS").modifier(ColumnLabel())
                    ForEach(store.calendars.filter { !isBlocks($0.id) }) { c in
                        tick(c.title, c.color, on: !store.hidden.contains(c.id)) { if store.hidden.contains(c.id) { store.hidden.remove(c.id) } else { store.hidden.insert(c.id) } }
                    }
                }
                if !store.lists.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("REMINDERS LISTS").modifier(ColumnLabel())
                        ForEach(store.lists) { l in
                            let open = store.todos.filter { $0.listID == l.id && !$0.done }.count
                            tick(l.title, l.color, on: !store.hiddenLists.contains(l.id), count: open) { if store.hiddenLists.contains(l.id) { store.hiddenLists.remove(l.id) } else { store.hiddenLists.insert(l.id) } }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
        }
        .background(T.bg2)
    }

    private func setRow(_ name: String, colors: [Color], on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                HStack(spacing: 2) { ForEach(Array(colors.enumerated()), id: \.offset) { Bar(color: $0.element, height: 18) } }.frame(width: 14, alignment: .leading)
                Text(name).fontWeight(on ? .semibold : .regular).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 44)
            .background(on ? T.tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tick(_ name: String, _ color: Color, on: Bool, count: Int? = nil, _ flip: @escaping () -> Void) -> some View {
        Button(action: flip) {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(color)
                Text(name).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 0)
                if let count { Text("\(count)").foregroundStyle(T.text2) }
            }
            .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(name).accessibilityValue(on ? "Shown" : "Hidden").accessibilityAddTraits(.isToggle)
    }
}

private struct ColumnLabel: ViewModifier {
    func body(content: Content) -> some View { content.font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(T.text2).padding(.bottom, 4) }
}

/// "Add: Dinner with Ana Friday 7pm" at the bottom of the iPad's calendar: return opens the add sheet with what was typed, as on the Mac.
struct AddBar: View {
    @EnvironmentObject var app: PhoneState
    @State private var text = ""
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").foregroundStyle(T.tint).accessibilityHidden(true)
            TextField("Add: Dinner with Ana Friday 7pm", text: $text).submitLabel(.done)
                .onSubmit { let t = text.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }; app.adding = t; text = "" }
        }
        .padding(.horizontal, 16).frame(minHeight: 48).frame(maxWidth: 560)
        .glass().padding(.horizontal, 16).padding(.bottom, 16)
    }
}
