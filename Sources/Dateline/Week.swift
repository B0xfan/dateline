// Week settings (approved mockup, 2026-10-27): the first day of the week, working days and working hours. Saved on this Mac.
import SwiftUI

enum WorkWeek {
    static let starts = ["Match Mac", "Sunday", "Monday", "Saturday"]
    private static let d = UserDefaults.standard
    static var start = d.string(forKey: "weekStart").flatMap { starts.contains($0) ? $0 : nil } ?? "Match Mac" { didSet { save(start, "weekStart") } }
    static var days = Set(d.array(forKey: "workDays") as? [Int] ?? [2, 3, 4, 5, 6]) { didSet { save(days.sorted(), "workDays") } }  // 1 = Sunday
    static var from = d.object(forKey: "workFrom") as? Int ?? 8 * 60 { didSet { save(from, "workFrom") } }  // minutes after midnight
    static var to = d.object(forKey: "workTo") as? Int ?? 18 * 60 { didSet { save(to, "workTo") } }
    static var stripe = d.object(forKey: "workStripe") as? Bool ?? true { didSet { save(stripe, "workStripe") } }

    private static func save(_ v: Any, _ key: String) { if Look.saves { d.set(v, forKey: key) } }

    // 1 = Sunday, 2 = Monday, 7 = Saturday; "Match Mac" follows Language & Region in System Settings.
    static var firstWeekday: Int { ["Sunday": 1, "Monday": 2, "Saturday": 7][start] ?? Calendar.autoupdatingCurrent.firstWeekday }
    static func isWorkDay(_ day: Date) -> Bool { days.contains(cal.component(.weekday, from: day)) }

    // The mockup's week, for the off-screen pictures and the self-checks; never saved.
    static func reset() { Look.saves = false; start = "Monday"; days = [2, 3, 4, 5, 6]; from = 8 * 60; to = 18 * 60; stripe = true }
}

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
                row("Week starts on", "Changes the week view, the month, quarter and year grids. Week numbers follow it too.") {
                    Seg(options: WorkWeek.starts, selected: WorkWeek.start, small: true) { WorkWeek.start = $0; changed() }
                }
                row("Working days", "The 5-day view shows these days. Days off get a light grey background in the week view.") {
                    HStack(spacing: 5) {
                        ForEach(order, id: \.self) { wd in
                            let on = WorkWeek.days.contains(wd)
                            Button { if on { WorkWeek.days.remove(wd) } else { WorkWeek.days.insert(wd) }; changed() } label: {
                                Text(String(cal.shortWeekdaySymbols[wd - 1].prefix(2))).font(.system(size: 12, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Palette.accent : Palette.text3).frame(width: 34, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Palette.accentSoft : .clear))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Palette.accent : Palette.line))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                row("Working hours", "The calendar opens scrolled to the start of your day. Hours outside work are lightly striped.") {
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
            }.frame(width: 430, alignment: .leading)
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
        HStack(alignment: .top, spacing: 10) {
            Text(k).foregroundStyle(Palette.text2).frame(width: 110, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                v()
                if let hint { Text(hint).font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

func minuteText(_ m: Int, short: Bool = false) -> String {
    if m == 1440 { return "Midnight" }  // the end of the day, not 12:00 AM at its start
    let h = m / 60 % 24, mm = m % 60
    return "\(h % 12 == 0 ? 12 : h % 12)\(short && mm == 0 ? "" : ":\(mm < 10 ? "0" : "")\(mm)") \(h < 12 ? "AM" : "PM")"
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
                Color.clear.frame(width: 30, height: 1)
                ForEach(days, id: \.self) { d in Text(String(dateText(d, "EEE").prefix(1))).font(.system(size: 10.5)).foregroundStyle(Palette.text2).frame(maxWidth: .infinity) }
            }.padding(.vertical, 5).background(Palette.bar).overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(first..<last, id: \.self) { h in
                        Text(h % 2 == 0 ? "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "a" : "p")" : "").font(.system(size: 9)).foregroundStyle(Palette.text3)
                            .frame(width: 26, height: rowH, alignment: .trailing)
                    }
                }.padding(.trailing, 4)
                ForEach(days, id: \.self) { d in
                    OffHours(day: d).frame(height: rowH * 24).offset(y: -rowH * CGFloat(first)).frame(height: rowH * CGFloat(last - first), alignment: .top).clipped()
                        .overlay(alignment: .leading) { Palette.lineSoft.frame(width: 1) }
                }
            }
            Text(caption).font(.system(size: 10.5)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6).overlay(alignment: .top) { Palette.line.frame(height: 1) }
        }
        .background(Palette.win)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .frame(width: 230)
    }

    var caption: String {
        let names = order.filter(WorkWeek.days.contains).map { cal.shortWeekdaySymbols[$0 - 1] }
        let at = order.indices.filter { WorkWeek.days.contains(order[$0]) }
        let joined = names.count > 2 && at.last! - at.first! + 1 == at.count  // Mon to Fri, but Mon, Wed, Fri spelled out
        let span = names.isEmpty ? "no working days" : joined ? "\(names.first!) to \(names.last!)" : names.joined(separator: ", ")
        return "\(cal.weekdaySymbols[WorkWeek.firstWeekday - 1]) first · \(span) · \(minuteText(WorkWeek.from, short: true)) to \(minuteText(WorkWeek.to, short: true))"
    }
}
