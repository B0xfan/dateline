// The month and year views (approved mockups "Month" and "Year").
import SwiftUI
import DatelineCore

/// "SUN MON TUE ...", starting on the week's first day (Settings, Week).
func weekDayNames() -> [String] {
    let l = cal.shortWeekdaySymbols.map { $0.uppercased() }, f = WorkWeek.firstWeekday - 1
    return Array(l[f...] + l[..<f])
}

/// The month (2026-11-06 design): the calendar set, the year and the arrows; the grid with coloured markers;
/// the tapped day's schedule under it.
struct MonthView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var picked: Date?

    var body: some View {
        let grid = monthGrid(app.anchor), month = cal.component(.month, from: app.anchor)
        let sel = picked ?? (cal.isDate(app.today, equalTo: app.anchor, toGranularity: .month) ? cal.startOfDay(for: app.today) : cal.startOfDay(for: app.anchor))
        let list = store.shown(on: sel)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              VStack(alignment: .leading, spacing: 0) {  // the calendar on white; the day's card below on grey
                HStack(spacing: 0) {
                    SetMenu()
                    Spacer(minLength: 0)
                    Button(dateText(app.anchor, "yyyy")) { app.mode = .year }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 8).frame(minHeight: 44)
                        .accessibilityLabel("Show the year \(dateText(app.anchor, "yyyy"))")
                    Button { app.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("Last month")
                    Button { app.step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("Next month")
                }
                .foregroundStyle(T.tint).buttonStyle(.plain).padding(.horizontal, 6).padding(.top, 4)
                HStack(spacing: 0) {
                    ForEach(Array(weekDayNames().enumerated()), id: \.offset) { _, l in Text(l).frame(maxWidth: .infinity) }
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(T.text2).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 0.5) }
                ForEach(0..<grid.count / 7, id: \.self) { w in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            cell(grid[w * 7 + i], inMonth: cal.component(.month, from: grid[w * 7 + i]) == month, picked: sel)
                                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(T.line).frame(width: 0.5) } }
                        }
                    }
                    .padding(.horizontal, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 0.5) }
                }
              }
              .background(T.bg)
                (Text(dateText(sel, "EEEE, MMMM d")).foregroundColor(T.text).fontWeight(.semibold)
                 + Text("  " + (list.isEmpty ? "No events" : list.count == 1 ? "1 event" : "\(list.count) events")))
                    .font(.footnote).foregroundStyle(T.text2)
                    .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 7)
                    .accessibilityAddTraits(.isHeader)
                DayCard(day: sel, rows: agendaRows(store, sel, now: app.today).filter { if case .event(let it) = $0 { !it.allDay } else { true } },
                        allDay: list.filter(\.allDay))
                    .padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
        .background(T.grouped)
        .onChange(of: app.anchor) { picked = nil }
    }

    private func cell(_ d: Date, inMonth: Bool, picked sel: Date) -> some View {
        let today = cal.isDate(d, inSameDayAs: app.today), on = cal.isDate(d, inSameDayAs: sel)
        var seen = Set<String>()
        let dots = store.shown(on: d).filter { it in seen.insert(it.color.map { n in "c\(n)" } ?? it.calendarID).inserted }.prefix(3).map { store.color($0) }
        return Button { picked = d } label: {
            VStack(spacing: 4) {
                Text(dateText(d, "d")).font(.subheadline.weight(today ? .semibold : .regular))
                    .foregroundStyle(today ? .white : on ? T.tint : inMonth ? T.text : T.text2.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .background(today ? T.accent : on ? T.tint.opacity(0.14) : .clear, in: Circle())
                HStack(spacing: 3) { ForEach(Array(dots.enumerated()), id: \.offset) { _, c in Dot(color: c, size: 5) } }.frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .top).padding(.top, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(T.bg)
        .accessibilityLabel(dateText(d, "EEEE, MMMM d") + (today ? ", today" : "") + (dots.isEmpty ? "" : ", has events"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct YearView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store

    var body: some View {
        let y = cal.dateInterval(of: .year, for: app.anchor)!
        let busy = dayCalendars(store.items.filter { !store.hidden.contains($0.calendarID) }, in: y)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), alignment: .leading, spacing: 18) {
                ForEach(0..<12, id: \.self) { m in mini(cal.date(byAdding: .month, value: m, to: y.start)!, busy: busy) }
            }
            .padding(.horizontal, 16).padding(.top, 16)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(T.tint.opacity(0.2)).frame(width: 12, height: 12)
                Text("Days with events. Tap a month to open it.")
            }
            .font(.caption).foregroundStyle(T.text2).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 20)
        }
    }

    private func mini(_ first: Date, busy: [Date: [String]]) -> some View {
        let n = cal.range(of: .day, in: .month, for: first)!.count
        let blanks = (cal.component(.weekday, from: first) - WorkWeek.firstWeekday + 7) % 7
        return Button { app.anchor = first; app.mode = .month } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateText(first, "MMM")).font(.subheadline.bold()).foregroundStyle(T.text)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                    ForEach(0..<(blanks + n), id: \.self) { i in
                        if i < blanks { Color.clear.frame(height: 14) } else {
                            let d = addDays(first, i - blanks), today = cal.isDate(d, inSameDayAs: app.today)
                            Text("\(i - blanks + 1)").font(.system(size: 8, weight: today ? .bold : .regular))
                                .foregroundStyle(today ? .white : T.text)
                                .frame(maxWidth: .infinity, minHeight: 14)
                                .background(today ? T.accent : busy[d] != nil ? T.tint.opacity(0.2) : .clear, in: Capsule())
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dateText(first, "MMMM"))
    }
}
