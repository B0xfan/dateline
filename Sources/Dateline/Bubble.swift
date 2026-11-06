// A new event filled in from boxes, in a bubble at the double-clicked day (approved mockup PQ5tq5fctbzZ43xX4oqT9M, James 2026-11-05).
import SwiftUI
import DatelineCore

extension View {
    // The bubble for a new event on `day`, pointing at `spot` (the whole view when nil).
    func newEventBubble(app: AppState, store: Store, day: Date, spot: CGRect? = nil) -> some View {
        popover(isPresented: Binding(get: { app.bubble.map { cal.isDate($0, inSameDayAs: day) } ?? false }, set: { if !$0, let b = app.bubble, cal.isDate(b, inSameDayAs: day) { app.bubble = nil } }),  // an old bubble closing never shuts the new one
                attachmentAnchor: spot.map { .rect(.rect($0)) } ?? .rect(.bounds), arrowEdge: .trailing) {
            if let start = app.bubble { NewEventBubble(app: app, store: store, start: start).id(start) }
        }
    }
}

struct NewEventBubble: View {
    let app: AppState, store: Store
    @State private var title = ""
    @State private var calendarID: String?
    @State private var start: Date
    @State private var end: Date
    @State private var allDay = false
    @State private var place = ""
    @State private var alert: Int?
    @FocusState private var titleFocused: Bool
    static let alerts: [(Int?, String)] = [(nil, "None"), (0, "At the start"), (5, "5 min before"), (10, "10 min before"), (15, "15 min before"), (30, "30 min before"), (60, "1 hour before"), (1440, "1 day before")]

    init(app: AppState, store: Store, start: Date) {
        self.app = app; self.store = store
        _start = State(initialValue: start); _end = State(initialValue: start.addingTimeInterval(3600))
        _calendarID = State(initialValue: app.calendar(for: Parsed(start: start, end: start.addingTimeInterval(3600)), pick: nil).0?.id)
    }

    var body: some View {
        let c = calendarID.flatMap { store.calendar($0) }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.ui(11)).foregroundStyle(Palette.text3)
                TextField("New event", text: $title).textFieldStyle(.roundedBorder).font(.ui(15, weight: .semibold))
                    .focused($titleFocused)  // Return is the Add button's; an onSubmit too would add twice
            }
            row("Calendar") {
                Menu {
                    ForEach(store.calendars.filter(\.writable)) { k in Button(k.title + "  (" + k.account + ")") { calendarID = k.id } }
                } label: {
                    HStack(spacing: 8) { Circle().fill(c?.color ?? .gray).frame(width: 8, height: 8); Text(c?.title ?? "None"); Text(c?.account ?? "").foregroundStyle(Palette.text3) }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            row("Date") {
                DatePicker("", selection: Binding(get: { start }, set: { v in
                    let len = end.timeIntervalSince(start); start = Self.moved(start, to: v); end = start.addingTimeInterval(len)
                }), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                Spacer(minLength: 8)
                Toggle("All day", isOn: $allDay).toggleStyle(.switch).controlSize(.small)
            }
            if !allDay {
                row("Time") {
                    DatePicker("", selection: Binding(get: { start }, set: { v in let len = end.timeIntervalSince(start); start = v; end = v.addingTimeInterval(len) }),
                               displayedComponents: .hourAndMinute).labelsHidden()
                    Text("to").foregroundStyle(Palette.text3)
                    DatePicker("", selection: Binding(get: { end }, set: { end = Self.ended($0, after: start) }), displayedComponents: .hourAndMinute).labelsHidden()
                }
            }
            row("Place") { TextField("Add a place", text: $place).textFieldStyle(.roundedBorder) }
            row("Alert") {
                Menu {
                    ForEach(Self.alerts, id: \.1) { m, name in Button(name) { alert = m } }
                } label: { Text(Self.alerts.first { $0.0 == alert }?.1 ?? "None") }.menuStyle(.borderlessButton).fixedSize()
            }
            Divider()
            HStack(spacing: 8) {
                Button("More details…") { add(details: true) }.buttonStyle(.link).help("Add the event and open all its details on the right")
                Spacer()
                Button("Cancel") { app.bubble = nil }.keyboardShortcut(.cancelAction)
                Button("Add") { add(details: false) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .font(.ui(13)).padding(16).frame(width: 340)
        .onAppear { titleFocused = true }
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 64, alignment: .leading); v() }
    }

    // A new date keeps the clock time, also on a daylight-saving day.
    static func moved(_ start: Date, to day: Date) -> Date {
        let t = cal.dateComponents([.hour, .minute], from: start)
        return cal.date(bySettingHour: t.hour!, minute: t.minute!, second: 0, of: day)!
    }
    // An end picked before the start is the next day (23:00 to 01:00); never under 5 minutes.
    static func ended(_ picked: Date, after start: Date) -> Date { max(picked <= start ? addDays(picked, 1) : picked, start.addingTimeInterval(5 * 60)) }

    static func draft(title: String, start: Date, end: Date, allDay: Bool, place: String, alert: Int?) -> Parsed {
        let t = title.trimmingCharacters(in: .whitespaces), s = allDay ? cal.startOfDay(for: start) : start
        return Parsed(title: t.isEmpty ? "New event" : t, start: s, end: allDay ? addDays(s, 1) : end, allDay: allDay,
                      place: place.trimmingCharacters(in: .whitespaces), lengthGiven: true, dateGiven: true, alertMinutes: alert)
    }

    func add(details: Bool) {
        guard app.add(Self.draft(title: title, start: start, end: end, allDay: allDay, place: place, alert: alert), calendar: calendarID.flatMap { store.calendar($0) }) != nil else { return }  // the error shows; the bubble stays so nothing typed is lost
        app.bubble = nil
        app.panels.panelOpen = details
    }
}
