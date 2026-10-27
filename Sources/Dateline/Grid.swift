// The day and week grid, the month grid and the event details panel.
import SwiftUI
import AppKit

var hourH: CGFloat { Look.hourHeight }
let gutter: CGFloat = 52

// Side-by-side columns for events that overlap in time: (column, columns in its group).
func lanes(_ items: [Item]) -> [String: (Int, Int)] {
    var out: [String: (Int, Int)] = [:]
    var group: [Item] = [], ends: [Date] = [], groupEnd = Date.distantPast
    func flush() { for it in group { out[it.id] = (out[it.id]!.0, ends.count) }; group = []; ends = [] }
    for it in items.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
        if it.start >= groupEnd { flush() }
        let lane = ends.firstIndex(where: { $0 <= it.start }) ?? ends.count
        if lane == ends.count { ends.append(it.end) } else { ends[lane] = it.end }
        out[it.id] = (lane, 0); group.append(it); groupEnd = max(groupEnd, it.end)
    }
    flush()
    return out
}

struct TimeGrid: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store

    var body: some View {
        let days = app.visibleDays
        let items = app.shownItems
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                ForEach(days, id: \.self) { d in
                    let today = cal.isDate(d, inSameDayAs: app.now)
                    HStack(spacing: 4) {
                        Text(dateText(d, "EEE")).font(.ui(12)).foregroundStyle(Palette.text2)
                        if today {
                            Text(dateText(d, "d")).font(.ui(14, weight: .medium)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Circle().fill(Palette.now))
                        } else { Text(dateText(d, "d")).font(.ui(18, weight: .medium)) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 44).frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
                    .contentShape(Rectangle()).onTapGesture { if app.mode == .week { app.open(day: d) } }
                }
            }
            .frame(height: 44)
            .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.ui(11)).foregroundStyle(Palette.text3).frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8).padding(.top, 9)
                ForEach(days, id: \.self) { d in
                    VStack(spacing: 0) {
                        ForEach(items.filter { $0.allDay && $0.start < addDays(d, 1) && $0.end > d }) { it in
                            let c = store.color(it)
                            HStack(spacing: 5) { Mark(showAs: it.showAs, color: c); Text(it.shownTitle).lineLimit(1) }
                                .font(.ui(12, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.16)))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(c, lineWidth: app.selectedID == it.id ? 2 : 0))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .onTapGesture { app.selectedID = it.id; app.panelOpen = true }
                        }
                    }
                    .padding(.vertical, 2).frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                    .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
                }
            }
            .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            if days.contains(where: { d in app.calendarTodos.contains { taskRowDay($0, now: app.now) == d } }) { TaskRow(app: app, store: store, days: days) }
            ScrollViewReader { sv in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { h in
                                ZStack(alignment: .topTrailing) {
                                    Color.clear
                                    if h > 0 { Text(hourText(h)).font(.ui(11)).foregroundStyle(Palette.text3).offset(x: -8, y: -7) }
                                }.frame(height: hourH).id(h)
                            }
                        }.frame(width: gutter)
                        ForEach(days, id: \.self) { d in
                            DayColumn(app: app, store: store, day: d, days: days, items: items.filter { !$0.allDay && $0.start < addDays(d, 1) && $0.end > d })
                        }
                    }
                }
                // Opens at the start of the working day (Settings, Week).
                .onAppear { DispatchQueue.main.async { sv.scrollTo(WorkWeek.from / 60, anchor: .top) } }
                .onChange(of: app.mode) { _, _ in DispatchQueue.main.async { sv.scrollTo(WorkWeek.from / 60, anchor: .top) } }
            }
        }
        .background(Palette.win)
    }

    func hourText(_ h: Int) -> String { h == 12 ? "Noon" : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")" }
}

struct DayColumn: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let day: Date, days: [Date], items: [Item]
    @State private var drag: (id: String, dy: CGFloat, dx: CGFloat, stretch: Bool)?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let lane = lanes(items)
            ZStack(alignment: .topLeading) {
                OffHours(day: day)
                VStack(spacing: 0) { ForEach(0..<24, id: \.self) { _ in Palette.lineSoft.frame(height: 1).frame(maxHeight: hourH, alignment: .top) } }
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { v in
                        let mins = Int(v.location.y / hourH * 60) / 30 * 30
                        app.newEvent(at: cal.date(byAdding: .minute, value: mins, to: day)!)
                    }.exclusively(before: TapGesture().onEnded { app.selectedID = nil; app.panelOpen = false }))
                ForEach(items) { it in
                    let (l, n) = lane[it.id] ?? (0, 1)
                    let f = frame(it)
                    let d = drag?.id == it.id ? drag : nil
                    let colW = (w - 4) / CGFloat(max(n, 1))
                    let stretchDY = d?.stretch == true ? d!.dy : 0
                    EventBlock(item: it, color: store.color(it), selected: app.selectedID == it.id, height: f.h + stretchDY)
                        .frame(width: colW - 2, height: max(18, f.h + stretchDY - 2))
                        .onTapGesture(count: 2) { app.selectedID = it.id; app.panelOpen = true }
                        .onTapGesture { app.selectedID = it.id }
                        .gesture(dragGesture(it, colWidth: w, stretch: false))
                        .overlay(alignment: .bottom) {
                            Color.clear.frame(height: 6).contentShape(Rectangle())
                                .onHover { ($0 ? NSCursor.resizeUpDown : NSCursor.arrow).set() }  // set, not push/pop: a redraw mid-hover cannot leave it stuck
                                .gesture(dragGesture(it, colWidth: w, stretch: true))
                        }
                        .offset(x: 2 + CGFloat(l) * colW + (d?.stretch == false ? d!.dx : 0), y: f.y + 1 + (d?.stretch == false ? d!.dy : 0))
                        .zIndex(d != nil ? 2 : 1)
                }
                if cal.isDate(day, inSameDayAs: app.now) {
                    let y = CGFloat(app.now.timeIntervalSince(day) / 3600) * hourH
                    ZStack(alignment: .leading) {
                        Palette.now.frame(height: 2)
                        Circle().fill(Palette.now).frame(width: 10, height: 10).offset(x: -5)
                    }.offset(y: y - 1).allowsHitTesting(false).zIndex(3)
                }
                // Reminders with a time on this day (not overdue: those sit in today's Tasks row).
                ForEach(app.calendarTodos.filter { t in t.timed && !isOverdue(t, now: app.now) && t.due.map { cal.isDate($0, inSameDayAs: day) } == true }) { t in
                    TaskBlock(app: app, store: store, task: t)
                        .frame(width: w - 8, height: max(20, hourH / 2 - 2))
                        .offset(x: 4, y: CGFloat(t.due!.timeIntervalSince(day) / 3600) * hourH + 1)
                        .zIndex(2)
                }
            }
        }
        .frame(height: hourH * 24)
        .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
        // Drag a task here from the task list or the Tasks row to give it this day and time (15-minute steps).
        .dropDestination(for: String.self) { ids, loc in
            guard let id = ids.first, id.hasPrefix("task:") else { return false }
            app.drop(taskID: String(id.dropFirst(5)), at: cal.date(byAdding: .minute, value: min(95, max(0, Int(loc.y / hourH * 4))) * 15, to: day)!)
            return true
        }
    }

    func frame(_ it: Item) -> (y: CGFloat, h: CGFloat) {
        let s = max(it.start, day), e = min(it.end, addDays(day, 1))
        let y = CGFloat(s.timeIntervalSince(day) / 3600) * hourH
        return (y, max(CGFloat(e.timeIntervalSince(s) / 3600) * hourH, 18))
    }

    // Moving (whole block, also to another day in the week view) or stretching (bottom edge), in 15-minute steps.
    // Holding Option when you let go of a move drops a copy and leaves the event where it was.
    func dragGesture(_ it: Item, colWidth: CGFloat, stretch: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)  // global: the block moves under the pointer, so its local space would feed back and jitter
            .onChanged { v in
                guard store.calendar(it.calendarID)?.writable == true else { return }
                let step = hourH / 4
                drag = (it.id, (v.translation.height / step).rounded() * step, days.count > 1 ? (v.translation.width / colWidth).rounded() * colWidth : 0, stretch)
                app.selectedID = it.id
            }
            .onEnded { v in
                defer { drag = nil }
                guard store.calendar(it.calendarID)?.writable == true else { return }
                let mins = Int((v.translation.height / (hourH / 4)).rounded()) * 15
                var new = it
                if stretch {
                    new.end = max(it.start.addingTimeInterval(15 * 60), it.end.addingTimeInterval(Double(mins) * 60))
                } else {
                    let dayShift = days.count > 1 ? Int((v.translation.width / colWidth).rounded()) : 0
                    new.start = addDays(it.start, dayShift).addingTimeInterval(Double(mins) * 60)
                    new.end = addDays(it.end, dayShift).addingTimeInterval(Double(mins) * 60)
                }
                if new == it { return }
                if !stretch && NSEvent.modifierFlags.contains(.option) { app.copy(new) } else { app.save(new) }
            }
    }
}

struct EventBlock: View {
    let item: Item, color: Color, selected: Bool, height: CGFloat
    var body: some View {
        let tint: AnyShapeStyle = switch item.showAs {
        case .busy: AnyShapeStyle(color.opacity(0.14))
        case .free: AnyShapeStyle(color.opacity(0.06))
        case .maybe: AnyShapeStyle(ImagePaint(image: stripes(color), scale: 1))
        }
        let time = timeText(item.start, short: true) + " to " + timeText(item.end, short: true)
        let meta = item.place.isEmpty ? time : time + " · " + item.place
        VStack(alignment: .leading, spacing: 1) {
            if height < 34 {
                HStack(spacing: 6) {
                    Mark(showAs: item.showAs, color: color)
                    Text(item.shownTitle).fontWeight(.semibold).lineLimit(1)
                    Text(meta).font(.ui(11.5)).foregroundStyle(Palette.text2).lineLimit(1)
                }
            } else {
                HStack(spacing: 5) { Mark(showAs: item.showAs, color: color); Text(item.shownTitle).fontWeight(.semibold).lineLimit(height > 60 ? 2 : 1) }
                Text(meta).font(.ui(11.5)).foregroundStyle(Palette.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.ui(12))
        .padding(.leading, 9).padding(.trailing, 8).padding(.vertical, height < 34 ? 2 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.win))
        .background(RoundedRectangle(cornerRadius: 6).fill(tint).padding(0))
        .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(color).frame(width: 3) }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: selected ? 2 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

// The diagonal stripes of a "Maybe" event, drawn once per colour.
@MainActor private var stripeCache: [Color: Image] = [:]
@MainActor func stripes(_ c: Color) -> Image {
    if let img = stripeCache[c] { return img }
    let r = ImageRenderer(content: Canvas { ctx, size in
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(c.opacity(0.06)))
        var p = Path()
        for x in stride(from: -12.0, through: 24, by: 12) { p.move(to: CGPoint(x: x, y: 12)); p.addLine(to: CGPoint(x: x + 12, y: 0)) }
        ctx.stroke(p, with: .color(c.opacity(0.14)), lineWidth: 4.2)
    }.frame(width: 12, height: 12))
    r.scale = 2
    let img = r.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: "circle")
    stripeCache[c] = img
    return img
}

struct MonthView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        // Own grid, not visibleDays: on a switch to Day this view can redraw once more with a 1-day list and crash.
        let grid = monthGrid(app.anchor)
        let weeks = grid.count / 7
        let items = app.shownItems
        let month = cal.component(.month, from: app.anchor)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 34)
                ForEach(0..<7, id: \.self) { i in
                    Text(dateText(grid[i], "EEE")).font(.ui(11)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                }
            }.frame(height: 30).overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            ForEach(0..<weeks, id: \.self) { w in
                HStack(spacing: 0) {
                    Text("\(weekNumber(grid[w * 7]))").font(.ui(10.5)).foregroundStyle(Palette.text3)
                        .frame(width: 34).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8).background(Palette.lineSoft)
                    ForEach(0..<7, id: \.self) { i in
                        let d = grid[w * 7 + i]
                        cell(d, items.filter { $0.start < addDays(d, 1) && $0.end > d }, other: cal.component(.month, from: d) != month)
                    }
                }.frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Palette.lineSoft.frame(height: 1) }
            }
        }.background(Palette.win)
    }

    func cell(_ d: Date, _ list: [Item], other: Bool) -> some View {
        GeometryReader { g in
            let fit = max(0, Int((g.size.height - 26) / 17))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    if cal.isDate(d, inSameDayAs: app.now) {
                        Text(dateText(d, "d")).font(.ui(12)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Palette.now))
                    } else { Text(dateText(d, "d")).font(.ui(12)).foregroundStyle(other ? Palette.text3.opacity(0.6) : Palette.text2) }
                }.padding(.bottom, 3).contentShape(Rectangle()).onTapGesture { app.open(day: d) }
                let shown = list.count > fit ? Array(list.prefix(max(0, fit - 1))) : list
                ForEach(shown) { it in
                    let c = store.color(it)
                    HStack(spacing: 5) {
                        Mark(showAs: it.showAs, color: c)
                        if !it.allDay { Text(timeText(it.start, short: true)).foregroundStyle(Palette.text3) }
                        Text(it.shownTitle).foregroundStyle(Palette.text)
                    }
                    .font(.ui(11)).lineLimit(1).padding(.vertical, 1).frame(height: 17)
                    .background(app.selectedID == it.id ? c.opacity(0.16) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { app.selectedID = it.id; app.panelOpen = true }
                    .onTapGesture { app.selectedID = it.id }
                }
                if list.count > shown.count {
                    Text("\(list.count - shown.count) more").font(.ui(11)).foregroundStyle(Palette.text3).onTapGesture { app.open(day: d) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 6).padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.newEvent(at: cal.date(byAdding: .hour, value: 9, to: d)!) }
    }
}

// The event panel on the right (approved event details mockup). Changes save when you leave a field.
struct DetailPanel: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var item: Item
    @FocusState private var field: String?
    @State private var notesEditing = false

    var body: some View {
        let c = store.calendar(item.calendarID)
        let locked = c?.writable != true
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("EVENT").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                    Spacer()
                    Button { commit(); app.panelOpen = false } label: { Image(systemName: "xmark").font(.ui(11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Palette.text3)
                }.padding(.bottom, 10)
                TextField("Title", text: $item.title, axis: .vertical).textFieldStyle(.plain).font(.ui(17, weight: .semibold))
                    .focused($field, equals: "title").onSubmit { commit() }
                    .disabled(locked)  // an invite's title is the sender's; an edit there would also block saving its emoji and tags
                HStack(spacing: 8) {
                    Text("Calendar").foregroundStyle(Palette.text3).frame(width: 64, alignment: .leading)
                    Menu {
                        ForEach(store.calendars.filter(\.writable)) { k in Button(k.title + "  (" + k.account + ")") { item.calendarID = k.id; commit() } }
                    } label: {
                        HStack(spacing: 6) { Circle().fill(c?.color ?? .gray).frame(width: 8, height: 8); Text(c?.title ?? ""); Text(c?.account ?? "").foregroundStyle(Palette.text3) }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(locked)
                }.padding(.top, 12)
                // Phase 3: kept by Dateline on this Mac, so they work on invites and read-only calendars too.
                row("Emoji") { EmojiRow(store: store, item: $item, commit: commit) }
                row("Color") { ColorRow(store: store, item: $item, commit: commit) }
                HStack(alignment: .top, spacing: 8) {
                    Text("Tags").foregroundStyle(Palette.text3).frame(width: 64, alignment: .leading).padding(.top, 5)
                    TagsRow(store: store, item: $item, commit: commit)
                }.padding(.top, 8).zIndex(1)
                Text("Tags, emoji and the event color are kept by Dateline on this Mac. They don't show on your phone or in Apple Calendar.")
                    .font(.ui(11)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                section("WHEN")
                Toggle("All day", isOn: Binding(get: { item.allDay }, set: { v in
                    item.allDay = v
                    if v { item.start = cal.startOfDay(for: item.start); item.end = addDays(item.start, 1) }
                    else { item.start = cal.date(byAdding: .hour, value: 9, to: cal.startOfDay(for: item.start))!; item.end = item.start.addingTimeInterval(3600) }
                    commit()
                })).toggleStyle(.switch).controlSize(.small)
                row("Date") {
                    DatePicker("", selection: Binding(get: { item.start }, set: { v in
                        let len = item.end.timeIntervalSince(item.start)
                        let t = cal.dateComponents([.hour, .minute], from: item.start)
                        item.start = cal.date(byAdding: t, to: cal.startOfDay(for: v))!; item.end = item.start.addingTimeInterval(len); commit()
                    }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                }
                if !item.allDay {
                    row("Time") {
                        HStack(spacing: 6) {
                            DatePicker("", selection: Binding(get: { item.start }, set: { v in
                                let len = item.end.timeIntervalSince(item.start); item.start = v; item.end = v.addingTimeInterval(len); commit()
                            }), displayedComponents: .hourAndMinute).labelsHidden()
                            Text("to").foregroundStyle(Palette.text3)
                            DatePicker("", selection: Binding(get: { item.end }, set: { v in
                                item.end = max(v, item.start.addingTimeInterval(5 * 60)); commit()
                            }), displayedComponents: .hourAndMinute).labelsHidden()
                        }
                    }
                    Text(lengthText).font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.leading, 72)
                }
                section("SHOW AS")
                Seg(options: ShowAs.allCases.map(\.rawValue), selected: item.showAs.rawValue) { item.showAs = ShowAs(rawValue: $0)!; commit() }
                section("PLACE")
                TextField("Add a place", text: $item.place).textFieldStyle(.roundedBorder).focused($field, equals: "place").onSubmit { commit() }
                section("NOTES")
                NotesBox(item: $item, editing: $notesEditing, locked: locked, commit: commit)
                Text(locked ? "This calendar is read only." : "Changes save when you leave a field. Command Z undoes.")
                    .font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.top, 12)
                if !locked {
                    Button("Delete event") { commit(); app.confirmDelete = app.selected }
                        .buttonStyle(.plain).foregroundStyle(Palette.now).padding(.top, 14)
                }
            }
            .padding(16)
        }
        .background(Palette.win)
        .onChange(of: field) { _, _ in commit() }
        .onDisappear { commit() }
        .onChange(of: store.items) { _, list in
            // Someone else (Apple Calendar, a drag in the grid, undo) changed it while the panel was open.
            if field == nil, !notesEditing, let fresh = list.first(where: { $0.id == item.id }), fresh != item { item = fresh }
        }
    }

    var lengthText: String {
        let m = Int(item.end.timeIntervalSince(item.start) / 60)
        let h = m / 60, r = m % 60
        return [h > 0 ? "\(h) hour" + (h == 1 ? "" : "s") : nil, r > 0 ? "\(r) min" : nil].compactMap { $0 }.joined(separator: " ")
    }

    func commit() {
        let extrasOnly = store.items.first { $0.id == item.id }.map { sameInCalendar($0, item) } ?? false
        guard extrasOnly || store.calendar(item.calendarID)?.writable == true else { return }
        app.save(item)
    }

    func section(_ t: String) -> some View {
        Text(t).font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3).padding(.top, 18).padding(.bottom, 6)
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 64, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 8)
    }
}

// The quarter view (approved Phase 2 mockup): three months side by side, with event names.
struct QuarterView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        let q = quarterStart(app.anchor)
        let items = app.shownItems
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                if i > 0 { Palette.line.frame(width: 1) }
                month(cal.date(byAdding: .month, value: i, to: q)!, items)
            }
        }.background(Palette.win)
    }

    func month(_ first: Date, _ items: [Item]) -> some View {
        // Own grid from the anchor, as in MonthView, so a switch to another view cannot redraw this with the wrong days.
        let grid = monthGrid(first), m = cal.component(.month, from: first)
        return VStack(alignment: .leading, spacing: 0) {
            Text(dateText(first, "MMMM")).font(.ui(13, weight: .semibold))
                .foregroundStyle(cal.isDate(first, equalTo: app.now, toGranularity: .month) ? Palette.now : Palette.text)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                .contentShape(Rectangle()).onTapGesture { app.anchor = first; app.mode = .month }
            HStack(spacing: 0) {
                Color.clear.frame(width: 24, height: 1)
                ForEach(0..<7, id: \.self) { i in Text(dateText(grid[i], "EEE")).font(.ui(10)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity) }
            }.padding(.top, 2).padding(.bottom, 4).overlay(alignment: .bottom) { Palette.lineSoft.frame(height: 1) }
            ForEach(0..<grid.count / 7, id: \.self) { w in
                HStack(spacing: 0) {
                    Text("\(weekNumber(grid[w * 7]))").font(.ui(9.5)).foregroundStyle(Palette.text3)
                        .frame(width: 24).frame(maxHeight: .infinity, alignment: .top).padding(.top, 5).background(Palette.lineSoft)
                    ForEach(0..<7, id: \.self) { i in
                        let d = grid[w * 7 + i]
                        if cal.component(.month, from: d) == m { cell(d, items.filter { $0.start < addDays(d, 1) && $0.end > d }) }
                        else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) } }
                    }
                }.frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Palette.lineSoft.frame(height: 1) }
            }
        }.frame(maxWidth: .infinity)
    }

    func cell(_ d: Date, _ list: [Item]) -> some View {
        GeometryReader { g in
            let fit = max(0, Int((g.size.height - 20) / 14))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Text(dateText(d, "d")).font(.ui(11))
                        .foregroundStyle(cal.isDate(d, inSameDayAs: app.now) ? .white : Palette.text2)
                        .padding(.horizontal, cal.isDate(d, inSameDayAs: app.now) ? 5 : 0)
                        .background { if cal.isDate(d, inSameDayAs: app.now) { Capsule().fill(Palette.now) } }
                }.padding(.bottom, 2).contentShape(Rectangle()).onTapGesture { app.open(day: d) }
                let shown = list.count > fit ? Array(list.prefix(max(0, fit - 1))) : list
                ForEach(shown) { it in
                    let c = store.color(it)
                    HStack(spacing: 3) { Mark(showAs: it.showAs, color: c, size: 6); Text(it.shownTitle) }
                        .font(.ui(10)).lineLimit(1).frame(height: 14)
                        .background(app.selectedID == it.id ? c.opacity(0.16) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { app.selectedID = it.id; app.panelOpen = true }
                        .onTapGesture { app.selectedID = it.id }
                }
                if list.count > shown.count {
                    Text("\(list.count - shown.count) more").font(.ui(10)).foregroundStyle(Palette.text3).onTapGesture { app.open(day: d) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 4).padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.newEvent(at: cal.date(byAdding: .hour, value: 9, to: d)!) }
    }
}

// For the year view: each day (start of day) inside `range`, mapped to the calendars with something on it, in start order.
func dayCalendars(_ items: [Item], in range: DateInterval) -> [Date: [String]] {
    var out: [Date: [String]] = [:]
    for it in items where it.end > range.start && it.start < range.end {
        var d = cal.startOfDay(for: max(it.start, range.start))
        let last = min(it.end, range.end)
        repeat {
            if !(out[d]?.contains(it.calendarID) ?? false) { out[d, default: []].append(it.calendarID) }
            d = addDays(d, 1)
        } while d < last
    }
    return out
}

// The year view (approved year view mockup): twelve small months, a dot for each calendar with something that day.
struct YearView: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    var body: some View {
        let year = cal.dateInterval(of: .year, for: app.anchor)!
        let dots = dayCalendars(app.shownItems, in: year)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: 4), alignment: .leading, spacing: 22) {
                ForEach(0..<12, id: \.self) { m in month(cal.date(byAdding: .month, value: m, to: year.start)!, dots) }
            }.padding(.horizontal, 26).padding(.vertical, 20)
        }.background(Palette.win)
    }

    func month(_ first: Date, _ dots: [Date: [String]]) -> some View {
        let grid = monthGrid(first), m = cal.component(.month, from: first)
        return VStack(alignment: .leading, spacing: 6) {
            Text(dateText(first, "MMMM")).font(.ui(13, weight: .semibold))
                .foregroundStyle(cal.isDate(first, equalTo: app.now, toGranularity: .month) ? Palette.now : Palette.text)
                .contentShape(Rectangle()).onTapGesture { app.anchor = first; app.mode = .month }
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 22, height: 1)
                    ForEach(0..<7, id: \.self) { i in Text(dateText(grid[i], "EEEEE")).font(.ui(10)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity) }
                }.padding(.bottom, 1)
                ForEach(0..<grid.count / 7, id: \.self) { w in
                    HStack(spacing: 0) {
                        Text("\(weekNumber(grid[w * 7]))").font(.ui(9.5)).foregroundStyle(Palette.text3).padding(.top, 4).frame(width: 22, height: 24, alignment: .top)
                        ForEach(0..<7, id: \.self) { i in
                            let d = grid[w * 7 + i]
                            if cal.component(.month, from: d) == m { day(d, dots[d] ?? []) } else { Color.clear.frame(maxWidth: .infinity).frame(height: 24) }
                        }
                    }
                }
            }
        }
    }

    func day(_ d: Date, _ cals: [String]) -> some View {
        let today = cal.isDate(d, inSameDayAs: app.now)
        return VStack(spacing: 2) {
            Text(dateText(d, "d")).font(.ui(11))
                .foregroundStyle(today ? .white : cal.isDateInWeekend(d) ? Palette.text3 : Palette.text2)
                .padding(.horizontal, today ? 5 : 0)
                .background { if today { Capsule().fill(Palette.now) } }
            HStack(spacing: 2) {
                ForEach(cals.prefix(3), id: \.self) { Circle().fill(store.calendar($0)?.color ?? .gray).frame(width: 4, height: 4) }
            }.frame(height: 4)
        }
        .padding(.top, 3).frame(maxWidth: .infinity).frame(height: 24, alignment: .top)
        .opacity(!today && d < cal.startOfDay(for: app.now) ? 0.55 : 1)
        .contentShape(Rectangle()).onTapGesture { app.open(day: d) }
        .help(dateText(d, "EEEE, MMMM d"))
    }
}
