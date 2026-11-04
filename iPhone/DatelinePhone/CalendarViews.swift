// The calendar tab: header, the 3 day week and the day view with their hour grid (approved mockups "Week (3 days)" and "Day").
import SwiftUI
import DatelineCore

struct CalendarTab: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        NavigationStack(path: $app.path) {
            VStack(spacing: 0) {
                CalHeader()
                switch app.mode {
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
                if abs(x) > 80 && abs(x) > abs(v.translation.height) * 2 { app.step(x < 0 ? 1 : -1) }
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
                        Image(systemName: "envelope").font(.body).frame(width: 44, height: 44).background(T.bg2, in: Circle())
                            .overlay(alignment: .topTrailing) {
                                Text("\(app.emails.count)").font(.caption2.bold()).foregroundStyle(.white)
                                    .frame(minWidth: 16, minHeight: 16).background(T.tint, in: Capsule()).offset(x: -2, y: 2)
                            }
                    }
                    .buttonStyle(.plain).accessibilityLabel("From email, \(app.emails.count) new")
                }
                Button("Today") { app.goToday() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(T.text)
                    .padding(.horizontal, 14).frame(height: 44).background(T.bg2, in: Capsule())
            }
            .padding(.horizontal, 16).padding(.top, 8)
            title.padding(.horizontal, 16).padding(.top, 4)
            Picker("View", selection: $app.mode) {
                ForEach(PhoneState.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 10)
        }
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

    @ViewBuilder private var title: some View {
        let a = app.anchor
        switch app.mode {
        case .week:
            let b = addDays(a, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(dateText(a, "MMM d") + " to " + dateText(b, cal.isDate(a, equalTo: b, toGranularity: .month) ? "d" : "MMM d")).font(.title.bold())
                Text("Week \(weekNumber(a))").font(.footnote).foregroundStyle(T.text2)
            }
        case .day:
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(dateText(a, "EEEE, MMM d")).font(.title.bold())
                    Text((["Week \(weekNumber(a))"] + (app.sun(a).map { ["sunrise \(dateText($0.rise, "h:mm"))", "sunset \(dateText($0.set, "h:mm"))"] } ?? [])).joined(separator: " · "))
                        .font(.footnote).foregroundStyle(T.text2)
                }
                Spacer()
                if let w = app.wx(a) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(degrees(w.hi)).font(.title3)
                        Text("\(degrees(w.lo)) low").font(.footnote).foregroundStyle(T.text2)
                    }
                }
            }
        case .month: Text(dateText(a, "MMMM yyyy")).font(.title.bold())
        case .year: Text(dateText(a, "yyyy")).font(.title.bold())
        }
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

    var body: some View {
        let days = app.days
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 44, height: 1)
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
                Text("tasks").font(.caption2).foregroundStyle(T.text2).padding(.leading, 6).padding(.top, 6).frame(width: 44, alignment: .leading)
                ForEach(days, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(dayTasks(store, d, now: app.today)) { TaskChip(t: $0).font(.caption) }
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
                    Text((s.lead.hasPrefix("starts") ? "in " : s.lead) + s.big).font(.title3.bold()).foregroundStyle(T.tint)
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
    let days: [Date]
    let wide: Bool
    private let hourH: CGFloat = 56

    var body: some View {
        ScrollViewReader { sv in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in
                            ZStack(alignment: .topLeading) {
                                Rectangle().fill(T.line).frame(height: 1)
                                Text(h == 12 ? "Noon" : minuteText(h * 60, short: true)).font(.caption2).foregroundStyle(T.text2)
                                    .padding(.trailing, 2).background(T.bg).offset(x: 6, y: -7)
                            }
                            .frame(height: hourH, alignment: .top).id(h)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { column($0) }
                    }
                    .padding(.leading, wide ? 52 : 44)
                }
                .padding(.top, 8).padding(.bottom, 170)  // room under the add bar and tabs
            }
            .onAppear { sv.scrollTo(firstHour, anchor: .top) }
            .onChange(of: app.anchor) { sv.scrollTo(firstHour, anchor: .top) }
        }
    }

    /// Opens on the hour before now on today, else at 8 AM.
    private var firstHour: Int {
        days.contains { cal.isDate($0, inSameDayAs: app.today) } ? max(0, cal.component(.hour, from: app.today) - 1) : 8
    }

    private func y(_ t: Date, _ day: Date) -> CGFloat {
        let m = min(1440, max(0, t.timeIntervalSince(day) / 60))
        return CGFloat(m) / 60 * hourH
    }

    private func column(_ day: Date) -> some View {
        let list = store.shown(on: day).filter { !$0.allDay }
        let ln = lanes(list)
        let timed = store.todos.filter { $0.timed && !$0.done && !store.hiddenLists.contains($0.listID) && $0.due.map { cal.isDate($0, inSameDayAs: day) } == true }
        return GeometryReader { g in ZStack(alignment: .topLeading) {
            ForEach(list) { it in
                let pos = ln[it.id] ?? (0, 1)
                let w = g.size.width / CGFloat(max(pos.1, 1))
                let top = y(it.start, day)
                if let m = app.drive[it.id], top > 0 {
                    let h = CGFloat(m) / 60 * hourH
                    DriveBlock(minutes: m, color: store.color(it)).frame(width: w - 4, height: min(h, top)).offset(x: CGFloat(pos.0) * w + 2, y: top - min(h, top) - 2)
                }
                EventBlock(it: it, wide: wide).frame(width: w - 4, height: max(22, y(it.end, day) - top - 2)).offset(x: CGFloat(pos.0) * w + 2, y: top)
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
}

struct EventBlock: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    let it: Item
    let wide: Bool
    var body: some View {
        let c = store.color(it)
        Button { app.open(it) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(it.shownTitle).fontWeight(.semibold).lineLimit(wide ? 1 : 2)
                Text(wide ? ([timeText(it.start, short: true) + " to " + timeText(it.end, short: true)] + (it.place.isEmpty ? [] : [it.place])).joined(separator: " · ") : timeText(it.start, short: true))
                    .foregroundStyle(wide ? T.text2 : T.text).lineLimit(1)
            }
            .font(wide ? .subheadline : .caption).foregroundStyle(T.text)
            .padding(.leading, wide ? 10 : 6).padding(.trailing, 4).padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(c.opacity(0.18))
            .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: wide ? 4 : 3) }
            .clipShape(RoundedRectangle(cornerRadius: wide ? 8 : 6))
        }
        .buttonStyle(.plain)
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
