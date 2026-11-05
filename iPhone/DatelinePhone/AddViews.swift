// Add by typing and Event from email (approved mockups): the sentence is read by the same parser as the Mac's quick add.
import SwiftUI
import DatelineCore

/// What Dateline read, as rows: name, when, where, calendar, alert.
struct Understood: View {
    @EnvironmentObject var store: Store
    let p: Parsed
    let calendar: CalInfo?
    var emoji = ""
    var alert = ""
    var body: some View {
        Card {
            Row {
                Bar(color: calendar?.color ?? T.tint)
                Text((emoji.isEmpty ? "" : emoji + " ") + (p.title.isEmpty ? "New event" : p.title)).fontWeight(.semibold)
            }
            Row(label: "When") { Text(dateText(p.start, "EEEE, MMM d") + " · " + (p.allDay ? "All day" : "\(timeText(p.start, short: true)) to \(timeText(p.end, short: true))")) }
            if !p.place.isEmpty { Row(label: "Where") { Text(p.place) } }
            Row(label: "Calendar") {
                Dot(color: calendar?.color ?? T.text2)
                Text(calendar?.title ?? "No calendar can take new events")
            }
            if let r = p.repeats { Row(label: "Repeats") { Text(r.text) } }
            Row(label: "Alert", last: true) { Text(!alert.isEmpty ? alert : p.alertMinutes.map(alertText) ?? "None") }
        }
    }
}

struct AddSheet: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var problem: String?
    @State private var pick: String?  // nil = Dateline chooses, as on the Mac's add box
    @FocusState private var focused: Bool

    init(start: String) { _text = State(initialValue: start) }

    private var empty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let p = parseSentence(text, now: app.today)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Dinner with Ana Friday 7pm", text: $text)
                        .font(.title3).focused($focused).submitLabel(.done).onSubmit(add)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(T.bg2, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16).padding(.top, 6)
                    Text("Type it the way you'd say it. Dateline fills in the rest.")
                        .font(.footnote).foregroundStyle(T.text2).padding(.horizontal, 20).padding(.top, 6)
                    Card {
                        Picker("Calendar", selection: $pick) {
                            Text("Automatic").tag(String?.none)
                            ForEach(store.calendars.filter(\.writable)) { k in Text(k.title).tag(Optional(k.id)) }
                        }.pickerStyle(.menu).padding(.horizontal, 16).frame(minHeight: 44)
                    }.padding(.top, 12)
                    if !empty {
                        SectionLabel("Dateline understood")
                        Understood(p: p, calendar: app.calendarFor(p, pick: pick))
                    }
                }
            }
            .background(T.bg)
            .navigationTitle("New event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add).fontWeight(.semibold).disabled(empty || app.calendarFor(p, pick: pick) == nil) }
            }
        }
        .onAppear { focused = true }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
    }

    private func add() {
        guard !empty else { return }
        switch app.add(parseSentence(text, now: app.today), pick: pick) {
        case .success: dismiss()
        case .failure(let f): if store.trialOver { app.unlockNext = true; dismiss() } else { problem = f.message }
        }
    }
}

struct EmailSheet: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let find: EmailFind
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    (Text("From ") + Text(find.from).bold().foregroundColor(T.text) + Text("\n\"\(find.quote)\""))
                        .font(.subheadline).foregroundStyle(T.text2).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(T.bg2, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16).padding(.top, 8)
                    SectionLabel("Dateline found")
                    Understood(p: find.parsed, calendar: app.calendarFor(find.parsed), emoji: find.emoji, alert: find.alert)
                    Text("Read on this iPhone with Apple Intelligence. The email never leaves your phone.")
                        .font(.footnote).foregroundStyle(T.text2).padding(.horizontal, 32).padding(.top, 14)
                }
            }
            .background(T.bg)
            .navigationTitle("Event from email").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add).fontWeight(.semibold).disabled(app.calendarFor(find.parsed) == nil) }
            }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
    }

    private func add() {
        switch app.add(find.parsed, emoji: find.emoji) {
        case .success: app.emails.removeAll { $0.id == find.id }; dismiss()
        case .failure(let f): if store.trialOver { app.unlockNext = true; dismiss() } else { problem = f.message }
        }
    }
}
