// Go to Date (approved redesign 2026-11-22, board XyJSw64aWUBWmWxWzbmbKy): type a day ("march 19", "next friday"),
// tap a quick pick or a day in the month; the view in use jumps there.
import SwiftUI
import DatelineCore

struct GoToDate: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var month: Date  // first day of the month on show; the arrows only change this
    @State private var wrong = false
    @FocusState private var typing: Bool
    private static let shown: DateFormatter = { let f = DateFormatter(); f.calendar = cal; f.locale = cal.locale; f.dateFormat = "MMM d, yyyy"; return f }()
    fileprivate static let title: DateFormatter = { let f = DateFormatter(); f.calendar = cal; f.locale = cal.locale; f.setLocalizedDateFormatFromTemplate("MMMMyyyy"); return f }()

    init(app: AppState) {
        self.app = app
        _text = State(initialValue: Self.shown.string(from: app.anchor))
        _month = State(initialValue: cal.dateInterval(of: .month, for: app.anchor)?.start ?? app.anchor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to date").font(.headline)
            field
            if wrong { Text("That isn't a date Dateline can read.").font(.callout).foregroundStyle(Palette.now) }
            HStack(spacing: 6) {
                pick("Today", 0, .day); pick("Tomorrow", 1, .day); pick("Next week", 7, .day); pick("Next month", 1, .month)
            }
            Divider()
            MonthGrid(month: $month, selected: app.anchor, today: Date(), choose: jump)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Palette.accent)
            }
        }
        .padding(18).frame(width: 340)
        .onAppear { typing = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").foregroundStyle(Palette.text3)
            TextField("March 19, next friday…", text: $text).textFieldStyle(.plain).focused($typing)
                .onChange(of: text) { _, _ in wrong = false }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(typing ? Palette.accent : Palette.line, lineWidth: typing ? 1.5 : 1))
    }

    private func pick(_ name: LocalizedStringKey, _ n: Int, _ unit: Calendar.Component) -> some View {
        Button(name) { jump(cal.date(byAdding: unit, value: n, to: Date()) ?? Date()) }
            .buttonStyle(Chip())
    }

    private func go() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        // The box starts filled with the shown day in the same form, so Go on it unchanged stays put.
        if let d = Self.shown.date(from: typed) ?? jumpDay(typed, now: Date()) { jump(d) } else { wrong = true }
    }
    private func jump(_ d: Date) { app.anchor = cal.startOfDay(for: d); dismiss() }
}

private struct Chip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }
    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label.font(.callout.weight(.medium))
                .foregroundStyle(hover ? Palette.accent : Palette.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(hover ? Palette.accentSoft : Palette.side, in: Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hover = $0 }
        }
    }
}

/// The month on show: today in red with a dot, the day in use filled blue, a click goes there.
private struct MonthGrid: View {
    @Binding var month: Date
    let selected: Date, today: Date
    let choose: (Date) -> Void

    private var days: [Date] {
        let lead = (cal.component(.weekday, from: month) - WorkWeek.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: month) ?? month
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
    private var letters: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols, f = WorkWeek.firstWeekday - 1  // the "Week starts on" setting, as in Week view
        return Array(s[f...] + s[..<f])
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(GoToDate.title.string(from: month)).font(.system(size: 14, weight: .semibold))
                Spacer()
                arrow("chevron.left", -1, "Previous month"); arrow("chevron.right", 1, "Next month")
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(letters.enumerated()), id: \.offset) { _, l in  // the same letter repeats (S, T), so position is the id
                    Text(l).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text3).frame(height: 20)
                }
                ForEach(days, id: \.self) { d in
                    DayCell(day: d, inMonth: cal.isDate(d, equalTo: month, toGranularity: .month),
                            isToday: cal.isDate(d, inSameDayAs: today), isSelected: cal.isDate(d, inSameDayAs: selected)) { choose(d) }
                }
            }
        }
    }

    private func arrow(_ icon: String, _ step: Int, _ help: LocalizedStringKey) -> some View {
        Button { month = cal.date(byAdding: .month, value: step, to: month) ?? month } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(Palette.text2).help(help).accessibilityLabel(help)
    }
}

private struct DayCell: View {
    let day: Date, inMonth: Bool, isToday: Bool, isSelected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(cal.component(.day, from: day), format: .number)
                .font(.system(size: 13, weight: isToday || isSelected ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : isToday ? Palette.now : inMonth ? Palette.text : Palette.text3)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(isSelected ? Palette.accent : hover ? Palette.side : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    if isToday { Circle().fill(isSelected ? Color.white : Palette.now).frame(width: 4, height: 4).padding(.bottom, 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month(.wide).day()) + Text(isToday ? ", today" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
