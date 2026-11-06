// Week settings (approved mockup, 2026-10-27): the first day of the week, working days and working hours. Saved on this Mac.
import SwiftUI
import DatelineCore

// Days off in light grey, and (when on) light stripes over the hours outside work. Drawn behind a full 24-hour day column.
struct OffHours: View {
    let day: Date
    var body: some View {
        let off = !WorkWeek.isWorkDay(day)
        Canvas { c, size in
            let perMin = size.height / 1440
            if off { c.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.lineSoft.opacity(0.6))); return }  // lighter than the hour lines, so they still show
            guard WorkWeek.stripe else { return }
            for (a, b) in [(0, WorkWeek.from), (WorkWeek.to, 1440)] where b > a {
                let r = CGRect(x: 0, y: CGFloat(a) * perMin, width: size.width, height: CGFloat(b - a) * perMin)
                c.drawLayer { l in
                    l.clip(to: Path(r))
                    var p = Path()
                    for x in stride(from: -r.height, to: r.width, by: 9) {
                        p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                    }
                    l.stroke(p, with: .color(Palette.lineSoft), lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// The Week tab in Settings. Every choice applies at once; the preview on the right follows it.
struct WeekSettings: View {
    @ObservedObject var app: AppState
    var body: some View {
        let order = (0..<7).map { (WorkWeek.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                row("Week starts on", "Changes the month, quarter and year grids and the map's week. Week numbers follow it too.") {
                    Seg(options: WorkWeek.starts, selected: WorkWeek.start, small: true) { WorkWeek.start = $0; changed() }
                }
                row("Double-click a day opens", "The bubble has boxes for the title, calendar, date, time, place and alert. More details… opens the full side panel.") {
                    let opts = ["A bubble on the day", "The side panel"]
                    Seg(options: opts, selected: opts[AppState.dayBubble ? 0 : 1], small: true) { AppState.dayBubble = $0 == opts[0]; changed() }
                }
                row("Working days", "The 5-day view shows today, then these days. Days off get a light grey background in the week view.") {
                    HStack(spacing: 4) {
                        ForEach(order, id: \.self) { wd in
                            let on = WorkWeek.days.contains(wd)
                            Button { if on { WorkWeek.days.remove(wd) } else { WorkWeek.days.insert(wd) }; changed() } label: {
                                Text(String(cal.shortWeekdaySymbols[wd - 1].prefix(2))).font(.system(size: 12, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Palette.accent : Palette.text3).frame(width: 36, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Palette.accentSoft : .clear))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Palette.accent : Palette.line))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                row("Working hours", "Hours outside work are lightly striped. The calendar always opens on the current time.") {
                    HStack(spacing: 8) {
                        time(WorkWeek.from, in: 0..<WorkWeek.to) { WorkWeek.from = $0 }
                        Text("to").foregroundStyle(Palette.text3)
                        time(WorkWeek.to, in: (WorkWeek.from + 30)..<1441) { WorkWeek.to = $0 }
                    }
                }
                row("Show off-hours", nil) {
                    Toggle("Stripe the hours outside work", isOn: Binding(get: { WorkWeek.stripe }, set: { WorkWeek.stripe = $0; changed() }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                row("Sun and moon", "Sunrise and sunset for where you are, in each day's heading, with a line in the grid and a faint tint on the night hours.") {
                    Toggle("Show sunrise, sunset and the moon", isOn: Binding(get: { WorkWeek.sun }, set: { WorkWeek.sun = $0; changed() }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                row("Leave alerts", "For events with a place: an alert on the Mac when it is time to drive there. Each event can still turn it on or off.") {
                    Toggle("Alert me when it's time to leave", isOn: Binding(get: { WorkWeek.leave }, set: { WorkWeek.leave = $0; changed(); app.planTravel() }))
                        .toggleStyle(.switch).controlSize(.small)
                }
            }.frame(width: 432, alignment: .leading)
            WeekPreview(order: order).id(app.look)
        }
        .font(.system(size: 13))
        .padding(20).frame(width: 720)
    }

    func changed() { app.look += 1; app.reload() }

    // Half-hour steps; 1440 is midnight at the end of the day.
    func time(_ v: Int, in range: Range<Int>, _ set: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(Array(stride(from: range.lowerBound - range.lowerBound % 30, to: range.upperBound, by: 30)), id: \.self) { m in
                Button(minuteText(m)) { set(m); changed() }
            }
        } label: { Text(minuteText(v)) }.menuStyle(.borderlessButton).fixedSize()
    }

    func row<V: View>(_ k: String, _ hint: String?, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 112, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                v()
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

// A week from 6 AM to 8 PM in the chosen order, with days off and off-hours drawn as in the calendar.
struct WeekPreview: View {
    let order: [Int]
    var body: some View {
        let rowH: CGFloat = 13, first = 6, last = 20
        // Any week works: these are real days with the right weekday, so OffHours draws them as the calendar does.
        let s = startOfWeek(Date()), days = (0..<7).map { addDays(s, $0) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 32, height: 1)
                ForEach(days, id: \.self) { d in Text(String(dateText(d, "EEE").prefix(1))).font(.system(size: 11)).foregroundStyle(Palette.text2).frame(maxWidth: .infinity) }
            }.padding(.vertical, 4).background(Palette.bar).overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(first..<last, id: \.self) { h in
                        Text(h % 2 == 0 ? "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "a" : "p")" : "").font(.system(size: 10)).foregroundStyle(Palette.text3)
                            .frame(width: 28, height: rowH, alignment: .trailing)
                    }
                }.padding(.trailing, 4)
                ForEach(days, id: \.self) { d in
                    OffHours(day: d).frame(height: rowH * 24).offset(y: -rowH * CGFloat(first)).frame(height: rowH * CGFloat(last - first), alignment: .top).clipped()
                        .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
                }
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4).overlay(alignment: .top) { Palette.line.frame(height: 1) }
        }
        .background(Palette.win)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .frame(width: 232)
    }

    var caption: String {
        let names = order.filter(WorkWeek.days.contains).map { cal.shortWeekdaySymbols[$0 - 1] }
        let at = order.indices.filter { WorkWeek.days.contains(order[$0]) }
        let joined = names.count > 2 && at.last! - at.first! + 1 == at.count  // Mon to Fri, but Mon, Wed, Fri spelled out
        let span = names.isEmpty ? "no working days" : joined ? "\(names.first!) to \(names.last!)" : names.joined(separator: ", ")
        return "\(cal.weekdaySymbols[WorkWeek.firstWeekday - 1]) first · \(span) · \(minuteText(WorkWeek.from, short: true)) to \(minuteText(WorkWeek.to, short: true))"
    }
}

