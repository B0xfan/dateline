// The calendar tab: header, the list (the main screen), the 3 day week and the day view with their hour grid
// (approved mockups "Week (3 days)", "Day" and the 2026-11-05 main calendar screen).
import SwiftUI
import DatelineCore

struct CalendarTab: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        NavigationStack(path: $app.path) {
            VStack(spacing: 0) {
                CalHeader()
                switch app.mode {
                case .list: AgendaView()
                case .day: DayView()
                case .week: WeekView()
                case .month: MonthView()
                case .year: YearView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(T.bg)
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in  // swipe left or right for the next or last days
                let x = v.translation.width
                if abs(x) > 80 && abs(x) > abs(v.translation.height) * 2 && Date() > app.dragUntil { app.step(x < 0 ? 1 : -1) }
            })
            .navigationTitle(dateText(app.anchor, "EEE, MMM d"))  // the details screen's back button
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { DetailsView(id: $0) }
        }
    }
}

struct CalHeader: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @ObservedObject private var weather = WeatherStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                setMenu
                Spacer()
                if !app.emails.isEmpty {
                    Button { app.email = app.emails.first } label: {
                        Image(systemName: "envelope").font(.title3).frame(width: 44, height: 44)
                            .overlay(alignment: .topTrailing) {
                                Text("\(app.emails.count)").font(.caption2.bold()).foregroundStyle(.white)
                                    .frame(minWidth: 16, minHeight: 16).background(T.tint, in: Capsule()).offset(x: -3, y: 5)
                            }
                    }
                    .buttonStyle(.plain).foregroundStyle(T.text).accessibilityLabel("From email, \(app.emails.count) new")
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            HStack(alignment: .top, spacing: 12) {
                title
                Spacer(minLength: 0)
                if app.mode == .day, let w = app.wx(app.anchor) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(degrees(w.hi)).font(.title3)
                        Text("\(degrees(w.lo)) low").font(.footnote).foregroundStyle(T.text2)
                    }
                }
                Button("Today") { app.goToday() }
                    .font(.body.weight(.semibold)).foregroundStyle(T.accent).frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            if app.mode == .list { WeekStrip() }
        }
        .background(app.mode == .list ? T.top : T.bg)
    }

    private var setMenu: some View {
        let s = store.activeSet
        let colors = (s?.calendars ?? store.calendars.map(\.id)).compactMap { store.calendar($0)?.color }
        return Menu {
            Button("All calendars") { store.use(nil) }
            ForEach(store.sets) { set in Button(set.name) { store.use(set) } }
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, c in RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 3, height: 14) }
                }
                Text(s?.name ?? "All calendars")
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(T.text)
            .padding(.horizontal, 12).frame(height: 44).background(T.bg2, in: Capsule())
        }
        .accessibilityLabel("Calendar set: \(s?.name ?? "All calendars")")
    }

    /// The big title is also the menu that switches List, Day, Week, Month and Year (it replaced the segmented switch).
    private var title: some View {
        let a = app.anchor
        let sub: String? = switch app.mode {
        case .week: "Week \(weekNumber(a))"
        case .day: (["Week \(weekNumber(a))"] + (app.sun(a).map { ["sunrise \(dateText($0.rise, "h:mm"))", "sunset \(dateText($0.set, "h:mm"))"] } ?? [])).joined(separator: " · ")
        default: nil
        }
        return VStack(alignment: .leading, spacing: 0) {
            Menu {
                Picker("View", selection: $app.mode) {
                    ForEach(PhoneState.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    heading(a).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(T.text2)
                }
                .foregroundStyle(T.text)
            }
            .accessibilityValue("\(app.mode.rawValue) view")  // the label stays the date the title reads
            .accessibilityHint("Changes the view")
            if let sub { Text(sub).font(.footnote).foregroundStyle(T.text2) }
        }
    }

    private func heading(_ a: Date) -> Text {
        switch app.mode {
        case .list, .month: Text(dateText(a, "MMMM") + " ") + Text(dateText(a, "yyyy")).foregroundColor(T.accent)  // the year in the accent colour
        case .week: Text(dateText(a, "MMM d") + " to " + dateText(app.days.last!, cal.isDate(a, equalTo: app.days.last!, toGranularity: .month) ? "d" : "MMM d"))
        case .day: Text(dateText(a, "EEEE, MMM d"))
        case .year: Text(dateText(a, "yyyy"))
        }
    }
}

/// The list screen's week: day letters, the date, and a coloured dot per calendar with events. Tap a day to start the list there.
struct WeekStrip: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    var body: some View {
        let first = startOfWeek(app.anchor)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach((0..<7).map { addDays(first, $0) }, id: \.self) { d in
                    let today = cal.isDate(d, inSameDayAs: app.today), picked = cal.isDate(d, inSameDayAs: app.anchor)
                    Button { app.anchor = d } label: {
                        VStack(spacing: 4) {
                            Text(dateText(d, "EEE").uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(today ? T.accent : T.text2)
                            Text(dateText(d, "d")).font(.body.weight(today ? .bold : .medium)).frame(width: 32, height: 32)
                                .foregroundStyle(today ? .white : T.text)
                                .background(today ? T.accent : picked ? T.text.opacity(0.1) : .clear, in: Circle())
                            HStack(spacing: 3) { ForEach(Array(dots(d).enumerated()), id: \.offset) { Dot(color: $0.element, size: 5) } }.frame(height: 5)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dateText(d, "EEEE, MMMM d") + (today ? ", today" : "") + (dots(d).isEmpty ? "" : ", has events"))
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10).padding(.top, 6)
            Button { app.mode = .month } label: {  // the grabber opens the month
                Capsule().fill(T.text2.opacity(0.4)).frame(width: 36, height: 5).frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(.plain).accessibilityLabel("Show the month")
        }
    }

    /// Up to three colours of the day's events, in order, each once.
    private func dots(_ d: Date) -> [Color] {
        store.shown(on: d).map { store.color($0) }.reduce(into: [Color]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3).map { $0 }
    }
}

/// One line of the list: an event or a task.
enum AgendaRow: Identifiable {
    case event(Item), task(ToDo)
    var id: String { switch self { case .event(let it): "e" + it.id; case .task(let t): "t" + t.id } }
}

/// A day's list: overdue tasks, then tasks with no time, then events and timed tasks by their time.
@MainActor func agendaRows(_ store: Store, _ d: Date, now: Date) -> [AgendaRow] {
    let day = cal.startOfDay(for: d)
    let timed = store.todos.filter { $0.timed && !isOverdue($0, now: now) && !store.hiddenLists.contains($0.listID) && $0.due.map { cal.isDate($0, inSameDayAs: d) } == true }
    func key(_ r: AgendaRow) -> Double {
        switch r {
        case .event(let it): max(0, it.start.timeIntervalSince(day))
        case .task(let t): isOverdue(t, now: now) ? -2 : t.timed ? t.due!.timeIntervalSince(day) : -1
        }
    }
    let rows = (dayTasks(store, d, now: now) + timed).map(AgendaRow.task) + store.shown(on: d).filter { !$0.allDay }.map(AgendaRow.event)
    return rows.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
}

/// The main screen: one running list grouped by day, from the day picked in the week strip.
struct AgendaView: View {
    static let span = 14  // days the list runs; past the first two, days with nothing on them are left out
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    var body: some View {
        let days = (0..<Self.span).map { i -> (day: Date, rows: [AgendaRow], allDay: [Item]) in
            let d = addDays(app.anchor, i)
            return (d, agendaRows(store, d, now: app.today), store.shown(on: d).filter(\.allDay))
        }.enumerated().filter { $0.offset < 2 || !$0.element.rows.isEmpty || !$0.element.allDay.isEmpty }.map(\.element)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.day) { i, d in AgendaDay(day: d.day, rows: d.rows, allDay: d.allDay, first: i == 0) }
            }
            .padding(.horizontal, 16).padding(.bottom, 110)  // room under the tabs
        }
        .background(T.list)
    }
}

struct AgendaDay: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let day: Date
    let rows: [AgendaRow]
    let allDay: [Item]
    let first: Bool
    var body: some View {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: app.today), to: day).day ?? 99
        let next: String? = n == 0 ? rows.lazy.compactMap { if case .event(let it) = $0, it.start > app.today { it.id } else { nil } }.first : nil  // rows run in time order
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                (Text(n == 0 ? "TODAY" : n == 1 ? "TOMORROW" : dateText(day, "EEEE").uppercased()).foregroundColor(n == 0 ? T.accent : T.text)
                 + Text(" " + dateText(day, "EEE M/d")).fontWeight(.medium).foregroundColor(T.text2))
                    .font(.footnote.weight(.bold))
                Spacer()
                if let w = app.wx(day) {
                    Text("\(degrees(w.hi)) / \(degrees(w.lo))").font(.footnote.weight(.semibold))
                    Image(systemName: wxLook(w.code).symbol).symbolRenderingMode(.multicolor).font(.body)
                        .accessibilityLabel(wxLook(w.code).words)
                }
            }
            .padding(.top, 16).padding(.bottom, 8)
            .overlay(alignment: .top) { if !first { Rectangle().fill(T.line).frame(height: 1) } }
            if !allDay.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allDay) { it in
                            Button { app.open(it) } label: {
                                Text(it.shownTitle).font(.subheadline.weight(.medium)).foregroundStyle(T.text).lineLimit(1)
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .background(store.color(it).opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            if rows.isEmpty && allDay.isEmpty { Text("Nothing planned").font(.subheadline).foregroundStyle(T.text2).padding(.vertical, 8) }
            ForEach(rows) { r in
                switch r {
                case .event(let it): AgendaEvent(it: it, day: day, next: it.id == next)
                case .task(let t): AgendaTask(t: t)
                }
            }
        }
    }
}

struct AgendaEvent: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let it: Item
    let day: Date
    let next: Bool
    var body: some View {
        let past = it.end <= app.today
        let leave = app.drive[it.id].map { it.start.addingTimeInterval(-Double($0) * 60) }.flatMap { $0 > app.today ? $0 : nil }
        Button { app.open(it) } label: {
            HStack(alignment: .top, spacing: 12) {
                Dot(color: store.color(it), size: 11).padding(.top, 4).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.start >= day ? "\(timeText(it.start, short: true)) to \(timeText(it.end, short: true))"
                         : cal.isDate(it.end, inSameDayAs: day) ? "Until \(timeText(it.end, short: true))" : "All day")  // a timed event running across several days
                        .font(.footnote.weight(.medium)).foregroundStyle(T.text2)
                    Text(it.shownTitle).font(.body.weight(.semibold)).foregroundStyle(T.text).lineLimit(1)
                    if !it.place.isEmpty { Text(it.place).font(.footnote).foregroundStyle(T.text2).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if let leave {
                    RowTag(text: "Leave \(dateText(leave, "h:mm"))", color: .orange)
                } else if next {
                    RowTag(text: "in " + span(it.start.timeIntervalSince(app.today)), color: T.tint)
                }
            }
            .padding(.vertical, 8).opacity(past ? 0.45 : 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A countdown or leave-by label on a list row.
struct RowTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 5).background(color.opacity(0.14), in: Capsule())
            .frame(maxHeight: .infinity)
    }
}

struct AgendaTask: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let t: ToDo
    var body: some View {
        let late = isOverdue(t, now: app.today), c = late ? T.late : store.taskList(t.listID)?.color ?? T.tint
        Button { app.toggle(t) } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle().strokeBorder(c, lineWidth: 1.8).background(Circle().fill(t.done ? c : .clear)).frame(width: 12, height: 12).padding(.top, 4).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(late ? "Overdue, from \(t.due.map { shortDay($0, now: app.today) } ?? "")" : t.timed ? timeText(t.due!, short: true) : "Anytime")
                        .font(.footnote.weight(.medium)).foregroundStyle(late ? T.late : T.text2)
                    Text(t.title).font(.body.weight(.medium)).strikethrough(t.done).foregroundStyle(t.done ? T.text2 : T.text).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.done ? "\(t.title), done" : "Finish \(t.title)")
    }
}

/// A task on the calendar: tap the ring to finish it.
struct TaskChip: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let t: ToDo
    var size: CGFloat = 10
    var body: some View {
        let late = isOverdue(t, now: app.today), c = store.taskList(t.listID)?.color ?? T.tint
        Button { app.toggle(t) } label: {
            HStack(spacing: size < 12 ? 4 : 8) {
                Circle().strokeBorder(late ? T.late : c, lineWidth: 1.5).background(Circle().fill(t.done ? c : .clear)).frame(width: size, height: size)
                Text(t.title).lineLimit(1).strikethrough(t.done)
                if late && size >= 12, let d = t.due { Text("from \(shortDay(d, now: app.today))").font(.caption) }
            }
            .foregroundStyle(late ? T.late : t.done ? T.text2 : T.text)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.done ? "\(t.title), done" : "Finish \(t.title)")
    }
}

/// An all-day event as a small coloured label.
struct AllDayChip: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let it: Item
    var body: some View {
        Button { app.open(it) } label: {
            Text(it.shownTitle).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(T.text)
                .padding(.horizontal, 5).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                .background(store.color(it).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

struct WeekView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @ObservedObject private var weather = WeatherStore.shared
    @ScaledMetric(relativeTo: .caption2) private var gutterRaw: CGFloat = 44
    private var gutter: CGFloat { min(gutterRaw, 80) }  // grows with the phone's text size, capped so three days still fit

    var body: some View {
        let days = app.days
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { d in
                    let today = cal.isDate(d, inSameDayAs: app.today)
                    VStack(spacing: 2) {
                        Text(dateText(d, "EEE")).font(.caption).foregroundStyle(T.text2)
                        Text(dateText(d, "d")).font(.headline).frame(width: 30, height: 30)
                            .foregroundStyle(today ? .white : T.text).background(today ? T.accent : .clear, in: Circle())
                        Text(wxLine(d)).font(.caption2).foregroundStyle(T.text2)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 10).padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            HStack(alignment: .top, spacing: 0) {
                Text("tasks").font(.caption2).foregroundStyle(T.text2).lineLimit(1).minimumScaleFactor(0.6).padding(.leading, 6).padding(.top, 6).frame(width: gutter, alignment: .leading)
                ForEach(days, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        let open = dayTasks(store, d, now: app.today).filter { !$0.done }
                        ForEach(open.prefix(2)) { TaskChip(t: $0).font(.caption) }
                        if open.count > 2 {
                            Button("+\(open.count - 2) more") { app.tab = .tasks }.font(.caption).foregroundStyle(T.text2).buttonStyle(.plain)
                        }
                        ForEach(store.shown(on: d).filter(\.allDay)) { AllDayChip(it: $0) }
                    }
                    .padding(.horizontal, 3).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            HourGrid(days: days, wide: false)
        }
    }

    private func wxLine(_ d: Date) -> String {
        [app.wx(d).map { degrees($0.hi) }, app.sun(d).map { dateText($0.rise, "h:mm") }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The tasks shown on a day's tasks row: due that day without a time, and anything overdue on today.
@MainActor func dayTasks(_ store: Store, _ d: Date, now: Date) -> [ToDo] {
    store.todos.filter { !store.hiddenLists.contains($0.listID) && taskRowDay($0, now: now) == cal.startOfDay(for: d) }
        .sorted { ($0.done ? 1 : 0, $0.title) < ($1.done ? 1 : 0, $1.title) }
}

struct DayView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store

    var body: some View {
        let d = app.anchor
        VStack(alignment: .leading, spacing: 0) {
            if cal.isDate(d, inSameDayAs: app.today), let s = comingUp(store.soon.filter { !store.hidden.contains($0.calendarID) }, now: app.today).first(where: { !$0.dim }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("COMING UP").font(.caption.weight(.semibold)).foregroundStyle(T.text2)
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    Text((s.lead.hasPrefix("starts") ? "in " : s.lead) + s.big).font(.subheadline.weight(.semibold)).foregroundStyle(T.tint)
                        .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)  // the title's size, on one line (John 2026-11-05: too large at big text)
                }
                .padding(.horizontal, 12).padding(.vertical, 10).background(T.bg2, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(dayTasks(store, d, now: app.today)) { TaskChip(t: $0, size: 14).font(.subheadline) }
                ForEach(store.shown(on: d).filter(\.allDay)) { AllDayChip(it: $0) }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
            Rectangle().fill(T.line).frame(height: 1)
            HourGrid(days: [d], wide: true)
        }
    }
}

/// The scrolling hours with the events, drive times, timed tasks and the now line.
struct HourGrid: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @State private var away = false
    @GestureState private var held: DragLive? = nil  // the event held in a finger now; it clears itself when the finger lifts or the touch is cancelled
    let days: [Date]
    let wide: Bool
    private let hourH: CGFloat = 56
    @ScaledMetric(relativeTo: .caption2) private var gutterRaw: CGFloat = 44
    private var gutter: CGFloat { min(gutterRaw, 80) }  // same as the week's day headers
    @ScaledMetric private var barRoom: CGFloat = 110  // the tabs grow with the text size too

    var body: some View {
        ScrollViewReader { sv in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in
                            ZStack(alignment: .topLeading) {  // the line sits 8 below the row's top, so a row scrolled to the top keeps its label
                                Rectangle().fill(T.line).frame(height: 1).offset(y: 8)
                                Text(h == 12 ? "Noon" : minuteText(h * 60, short: true)).font(.caption2).foregroundStyle(T.text2).lineLimit(1).minimumScaleFactor(0.6)
                                    .frame(maxWidth: gutter - 8, alignment: .leading)
                                    .padding(.trailing, 2).background(T.bg).offset(x: 6, y: 1)
                            }
                            .frame(height: hourH, alignment: .top).id(h)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { d in column(d).zIndex(live?.day == d ? 1 : 0) }
                    }
                    .padding(.leading, wide ? gutter + 8 : gutter).padding(.top, 8)
                }
                .padding(.bottom, min(barRoom, 200))  // room under the tabs
            }
            .scrollDisabled(held != nil)
            .onChange(of: held?.id) {
                if held != nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); app.dragUntil = .distantFuture }
                else { app.dragUntil = Date().addingTimeInterval(0.4) }
            }
            .onChange(of: held?.minutes) { if held != nil { UISelectionFeedbackGenerator().selectionChanged() } }
            // Like the Mac: the current hour's row sits mid-view on opening and each time the app comes back to the front.
            .onAppear { DispatchQueue.main.async { centre(sv) } }
            .onChange(of: app.anchor) { centre(sv) }
            .onChange(of: scenePhase) {
                if scenePhase == .background { away = true }  // a pulled-down Control Center only reaches .inactive: no jump back
                else if scenePhase == .active && away {
                    away = false
                    if !app.sample { app.today = Date() }  // the minute clock may not have run yet after a sleep
                    centre(sv)
                }
            }
        }
    }

    private func centre(_ sv: ScrollViewProxy) { sv.scrollTo(cal.component(.hour, from: app.today), anchor: .center) }

    private func y(_ t: Date, _ day: Date) -> CGFloat {
        let m = min(1440, max(0, t.timeIntervalSince(day) / 60))
        return CGFloat(m) / 60 * hourH
    }

    private var live: DragLive? { held ?? app.demoDrag }

    /// The event as it would be saved if the finger lifted now.
    private func lifted(_ it: Item, _ l: DragLive, column: Date) -> Item {
        if l.stretch { return DragMath.stretch(it, minutes: l.minutes) }
        return DragMath.move(it, minutes: l.minutes, days: shift(l, from: column))
    }

    /// Whole days over, from the column it started in; it stays inside the days on screen.
    private func shift(_ l: DragLive, from day: Date) -> Int {
        guard !l.stretch, let i = days.firstIndex(of: day) else { return 0 }
        return dayShift(columns: min(max(l.columns, -i), days.count - 1 - i), from: day, in: days)
    }

    private func column(_ day: Date) -> some View {
        let list = store.shown(on: day).filter { !$0.allDay }
        let ln = lanes(list)
        let timed = store.todos.filter { $0.timed && !$0.done && !store.hiddenLists.contains($0.listID) && $0.due.map { cal.isDate($0, inSameDayAs: day) } == true }
        return GeometryReader { g in ZStack(alignment: .topLeading) {
            // A tap on an empty time starts a new event there (events and tasks sit above and take their own taps).
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in app.addStart = DragMath.slot(on: day, y: v.location.y, hourH: hourH); app.adding = "" })
                .accessibilityHidden(true)
            ForEach(list) { it in
                let pos = ln[it.id] ?? (0, 1)
                let w = g.size.width / CGFloat(max(pos.1, 1))
                let top = y(it.start, day)
                let l = live?.id == it.id ? live : nil
                let shown = l.map { lifted(it, $0, column: day) } ?? it
                let cols = l.map { l in l.stretch ? 0 : days.firstIndex(of: day).map { i in min(max(l.columns, -i), days.count - 1 - i) } ?? 0 } ?? 0
                if let m = app.drive[it.id], top > 0, l == nil {
                    let h = CGFloat(m) / 60 * hourH
                    DriveBlock(minutes: m, color: store.color(it)).frame(width: w - 4, height: min(h, top)).offset(x: CGFloat(pos.0) * w + 2, y: top - min(h, top) - 2)
                }
                let h0 = max(22, y(it.end, day) - top - 2)
                let h = l == nil ? h0 : max(22, CGFloat(shown.end.timeIntervalSince(shown.start)) / 3600 * hourH - 2)
                let writable = store.calendar(it.calendarID)?.writable == true
                EventBlock(it: shown, wide: wide, lifted: l != nil)
                    .frame(width: w - 4, height: h)
                    .gesture(hold(it, column: day, width: g.size.width, stretch: false), including: writable ? .all : .none)
                    .overlay(alignment: .bottom) {
                        if writable {
                            Color.clear.frame(height: min(22, h0 / 2)).contentShape(Rectangle())
                                .onTapGesture { app.open(it) }
                                .gesture(hold(it, column: day, width: g.size.width, stretch: true))
                                .accessibilityHidden(true)
                        }
                    }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in app.say("This calendar is read only.") }, including: writable ? .none : .all)
                    .accessibilityAction(named: "Move 15 minutes later") { if writable { _ = app.change(DragMath.move(it, minutes: 15), from: it, "Moved") } }
                    .accessibilityAction(named: "Move 15 minutes earlier") { if writable { _ = app.change(DragMath.move(it, minutes: -15), from: it, "Moved") } }
                    .overlay(alignment: top < 44 ? .bottom : .top) { if l != nil { HoldPill(it: shown).offset(y: top < 44 ? 30 : -30) } }
                    .offset(x: CGFloat(pos.0) * w + 2 + CGFloat(cols) * g.size.width, y: top + (l.map { $0.stretch ? 0 : CGFloat($0.minutes) / 60 * hourH } ?? 0))
                    .zIndex(l != nil ? 2 : 0)
            }
            ForEach(timed) { t in
                TimedTask(t: t, color: store.taskList(t.listID)?.color ?? T.tint)
                    .frame(width: g.size.width - 4, height: hourH / 2 + 6).offset(x: 2, y: y(t.due!, day))
            }
            if cal.isDate(day, inSameDayAs: app.today) {
                let top = y(app.today, day)
                Rectangle().fill(T.accent).frame(width: g.size.width + 4, height: 2).offset(x: -4, y: top)
                Circle().fill(T.accent).frame(width: 10, height: 10).offset(x: -5, y: top - 4)
            }
        } }
        .frame(height: 24 * hourH)
        .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
    }

    /// Press and hold, then drag: moves the event (anywhere on it) or changes its length (its bottom edge). 15 minute steps.
    private func hold(_ it: Item, column: Date, width: CGFloat, stretch: Bool) -> some Gesture {
        func live(_ v: SequenceGesture<LongPressGesture, DragGesture>.Value) -> DragLive? {
            guard case .second(true, let d?) = v else { return nil }
            return DragLive(id: it.id, day: column, stretch: stretch, minutes: DragMath.minutes(dy: d.translation.height, hourH: hourH), columns: Int((d.translation.width / width).rounded()))
        }
        return LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($held) { v, state, _ in if let l = live(v) { state = l } }
            .onEnded { v in
                guard let l = live(v) else { return }
                let new = lifted(it, l, column: column)
                guard new != it else { return }
                if let f = app.change(new, from: it, stretch ? "Changed the length of" : "Moved") { if store.trialOver { app.showUnlock = true } else { app.problem = f.message } }
            }
    }
}

/// An event held in a finger: which one, how far (in 15 minute steps and whole columns), and whether the bottom edge is being pulled.
struct DragLive: Equatable {
    var id: String
    var day: Date
    var stretch: Bool
    var minutes: Int
    var columns: Int
}

/// The time it would have, above a held event.
struct HoldPill: View {
    let it: Item
    var body: some View {
        Text("\(dateText(it.start, "EEE")) \(timeText(it.start, short: true)) to \(timeText(it.end, short: true))")
            .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4).background(T.tint, in: Capsule())
    }
}

struct EventBlock: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let it: Item
    let wide: Bool
    var lifted = false  // held in a finger: raised, with a grip at the bottom edge
    var body: some View {
        let c = store.color(it)
        VStack(alignment: .leading, spacing: 0) {
            Text(it.shownTitle).fontWeight(.semibold).lineLimit(wide ? 1 : 3).minimumScaleFactor(wide ? 1 : 0.8)
            Text(wide ? ([timeText(it.start, short: true) + " to " + timeText(it.end, short: true)] + (it.place.isEmpty ? [] : [it.place])).joined(separator: " · ") : timeText(it.start, short: true))
                .foregroundStyle(wide ? T.text2 : T.text).lineLimit(1)
        }
        .font(wide ? .subheadline : .caption).foregroundStyle(T.text)
        .padding(.leading, wide ? 10 : 6).padding(.trailing, 4).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(lifted ? c.opacity(0.35) : c.opacity(0.18))
        .background(lifted ? T.bg : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: wide ? 4 : 3) }
        .overlay(alignment: .bottom) { if lifted { Capsule().fill(c).frame(width: 28, height: 4).padding(.bottom, 3) } }
        .clipShape(RoundedRectangle(cornerRadius: wide ? 8 : 6))
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: 8, y: 3)
        .scaleEffect(lifted ? 1.03 : 1)
        .contentShape(Rectangle())
        .onTapGesture { app.open(it) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The drive before an event: a striped block of its length.
struct DriveBlock: View {
    let minutes: Int
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width { p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 10 }
            ctx.stroke(p, with: .color(color.opacity(0.22)), lineWidth: 5)
        }
        .overlay(alignment: .leading) { Text("\(minutes) min drive").font(.caption2).foregroundStyle(T.text).padding(.leading, 6).lineLimit(1) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// A task with a time, in the grid: a dashed box. Tap to finish it.
struct TimedTask: View {
    @EnvironmentObject var app: PhoneState
    let t: ToDo
    let color: Color
    var body: some View {
        Button { app.toggle(t) } label: {
            (Text(timeText(t.due!, short: true) + " ") + Text(t.title).fontWeight(.semibold))
                .font(.caption).foregroundStyle(T.text).lineLimit(2)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Finish \(t.title), \(timeText(t.due!, short: true))")
    }
}
