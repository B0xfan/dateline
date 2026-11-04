// The month and year views (approved mockups "Month" and "Year").
import SwiftUI
import DatelineCore

/// "S M T W T F S", starting on the week's first day (Settings, Week).
func weekLetters() -> [String] {
    let l = ["S", "M", "T", "W", "T", "F", "S"], f = WorkWeek.firstWeekday - 1
    return Array(l[f...] + l[..<f])
}

struct MonthView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @State private var picked: Date?

    var body: some View {
        let grid = monthGrid(app.anchor), month = cal.component(.month, from: app.anchor)
        let sel = picked ?? (cal.isDate(app.today, equalTo: app.anchor, toGranularity: .month) ? cal.startOfDay(for: app.today) : cal.startOfDay(for: app.anchor))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 22, height: 1)
                    ForEach(Array(weekLetters().enumerated()), id: \.offset) { _, l in Text(l).frame(maxWidth: .infinity) }
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(T.text2)
                .padding(.top, 12).padding(.bottom, 4)
                ForEach(0..<grid.count / 7, id: \.self) { w in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(weekNumber(grid[w * 7]))").font(.caption2).foregroundStyle(T.text2).frame(width: 22).padding(.top, 10)
                        ForEach(0..<7, id: \.self) { i in cell(grid[w * 7 + i], inMonth: cal.component(.month, from: grid[w * 7 + i]) == month, picked: sel) }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
                }
                .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(dateText(sel, "EEEE, MMM d").uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(T.text2)
                    let list = store.shown(on: sel)
                    if list.isEmpty { Text("Nothing on this day.").font(.subheadline).foregroundStyle(T.text2) }
                    ForEach(list) { it in
                        Button { app.open(it) } label: {
                            HStack(spacing: 10) {
                                Bar(color: store.color(it), height: 32)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(it.shownTitle).font(.subheadline.weight(.semibold))
                                    Text(([it.allDay ? "All day" : "\(timeText(it.start, short: true)) to \(timeText(it.end, short: true))"] + (it.place.isEmpty ? [] : [it.place])).joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(T.text2)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10).padding(.horizontal, 8)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            }
            .padding(.horizontal, 8).padding(.bottom, 120)
        }
        .onChange(of: app.anchor) { picked = nil }
    }

    private func cell(_ d: Date, inMonth: Bool, picked sel: Date) -> some View {
        let today = cal.isDate(d, inSameDayAs: app.today), on = cal.isDate(d, inSameDayAs: sel)
        var seen = Set<String>()
        let dots = store.shown(on: d).filter { it in seen.insert(it.color.map { n in "c\(n)" } ?? it.calendarID).inserted }.prefix(3).map { store.color($0) }
        return Button { picked = d } label: {
            VStack(spacing: 3) {
                Text(dateText(d, "d")).font(.subheadline.weight(today ? .semibold : .regular))
                    .foregroundStyle(today ? .white : inMonth ? T.text : T.text2)
                    .frame(width: 26, height: 26)
                    .background(today ? T.accent : on ? T.bg2 : .clear, in: Circle())
                HStack(spacing: 2) { ForEach(Array(dots.enumerated()), id: \.offset) { _, c in Dot(color: c, size: 5) } }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .top).padding(.top, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dateText(d, "EEEE, MMMM d") + (dots.isEmpty ? "" : ", has events"))
    }
}

struct YearView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store

    var body: some View {
        let y = cal.dateInterval(of: .year, for: app.anchor)!
        let busy = dayCalendars(store.items.filter { !store.hidden.contains($0.calendarID) }, in: y)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), alignment: .leading, spacing: 18) {
                ForEach(0..<12, id: \.self) { m in mini(cal.date(byAdding: .month, value: m, to: y.start)!, busy: busy) }
            }
            .padding(.horizontal, 16).padding(.top, 16)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(T.tint.opacity(0.2)).frame(width: 12, height: 12)
                Text("Days with events. Tap a month to open it.")
            }
            .font(.caption).foregroundStyle(T.text2).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 120)
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
