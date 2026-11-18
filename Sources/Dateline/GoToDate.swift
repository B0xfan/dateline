// Go to Date (approved mockup 2026-11-17): type a day ("march 19", "next friday") or pick one; the view in use jumps there.
import SwiftUI
import DatelineCore

struct GoToDate: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var day: Date  // set before the first draw, so the picker's change handler only sees the person's picks
    @State private var wrong = false
    private static let shown: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f }()

    init(app: AppState) {
        self.app = app
        _day = State(initialValue: app.anchor); _text = State(initialValue: Self.shown.string(from: app.anchor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go to date").font(.headline)
            HStack(spacing: 8) {
                TextField("Mar 19, 2027", text: $text).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit(go).onChange(of: text) { _, _ in wrong = false }
                Button("Go", action: go).keyboardShortcut(.defaultAction)
            }
            if wrong { Text("That isn't a date Dateline can read.").font(.callout).foregroundStyle(.red) }
            DatePicker("Date", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                .onChange(of: day) { _, d in jump(d) }
            Text("Type a date (\"march 19\", \"next friday\") or pick one.").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(18).frame(width: 300)
    }

    private func go() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        // The box starts filled with the shown day in the same form, so Go on it unchanged stays put.
        if let d = Self.shown.date(from: typed) ?? jumpDay(typed, now: Date()) { jump(d) } else { wrong = true }
    }
    private func jump(_ d: Date) { app.anchor = Calendar.current.startOfDay(for: d); dismiss() }
}
