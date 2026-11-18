// The event edit sheet (Apple Calendar's pattern: Edit opens a form with Cancel and Done). It edits everything the Mac's event panel does,
// with the same rules; an invite or read-only calendar keeps its calendar part locked and still takes Dateline's own extras.
import SwiftUI
import UIKit
import DatelineCore

/// The Mac panel's time rules, kept apart so the self-check can run them.
enum EventEdit {
    static func allDay(_ it: Item, _ on: Bool) -> Item {
        var n = it
        n.allDay = on
        if on { n.start = cal.startOfDay(for: it.start); n.end = addDays(n.start, 1) }
        else { n.start = cal.date(byAdding: .hour, value: 9, to: cal.startOfDay(for: it.start))!; n.end = n.start.addingTimeInterval(3600) }
        return n
    }
    /// A new day keeps the clock time and the length.
    static func date(_ it: Item, _ v: Date) -> Item {
        var n = it
        let len = it.end.timeIntervalSince(it.start), t = cal.dateComponents([.hour, .minute], from: it.start)
        n.start = cal.date(byAdding: t, to: cal.startOfDay(for: v))!; n.end = n.start.addingTimeInterval(len)
        return n
    }
    /// A new start keeps the length.
    static func start(_ it: Item, _ v: Date) -> Item {
        var n = it; n.end = v.addingTimeInterval(it.end.timeIntervalSince(it.start)); n.start = v; return n
    }
    /// The end never goes closer than five minutes to the start.
    static func end(_ it: Item, _ v: Date) -> Item { var n = it; n.end = max(v, it.start.addingTimeInterval(5 * 60)); return n }
}

struct EditSheet: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let original: Item
    @State private var item: Item
    @State private var newTag = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var mins: [Int]?  // the alerts, in minutes before the start, once changed here; applied to the final start on Done
    @State private var added: (emoji: String, before: [Item])?  // what "Add to all" just did, for its Undo
    @StateObject private var search = PlaceSearch()

    init(_ it: Item) { original = it; _item = State(initialValue: it) }

    private var locked: Bool { store.calendar(item.calendarID)?.writable != true }  // an invite's title is the sender's, as on the Mac
    private var writable: [CalInfo] { store.calendars.filter(\.writable) }
    private var tagsLeft: [String] { store.allTags.map(\.0).filter { !item.tags.contains($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $item.title, axis: .vertical).font(.title3.weight(.semibold)).disabled(locked)
                    if locked {
                        LabeledContent("Calendar") { HStack { Dot(color: store.calendar(item.calendarID)?.color ?? T.text2); Text(store.calendar(item.calendarID)?.title ?? "") } }
                    } else {
                        Picker("Calendar", selection: $item.calendarID) {
                            // grouped under each account, so the chosen row shows only the calendar's name and never truncates at big text
                            ForEach(Array(Set(writable.map(\.account))).sorted(), id: \.self) { acct in
                                Section(acct) { ForEach(writable.filter { $0.account == acct }) { k in Text(k.title).tag(k.id) } }
                            }
                        }
                    }
                }
                if locked { Section { Text("This calendar is read only. You can still add an emoji, a color, tags and travel.").font(.footnote).foregroundStyle(T.text2) } }
                when
                alerts
                Section("Show as") {
                    Picker("Show as", selection: $item.showAs) { ForEach(ShowAs.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).disabled(locked)
                }
                Section("Place") {
                    if locked { Text(item.place.isEmpty ? "No place" : item.place).foregroundStyle(item.place.isEmpty ? T.text2 : T.text) }
                    else {
                        // Apple Maps suggestions as you type, as on the Mac; a typed place with no pick is looked up on Done.
                        TextField("Place or address", text: Binding(get: { item.place }, set: { v in
                            guard v != item.place else { return }
                            item.place = v; item.geo = nil
                            search.query(v)
                        })).textContentType(.fullStreetAddress)
                        ForEach(search.results, id: \.self) { s in
                            Button {
                                saving = true  // Done waits for the pick
                                Task { if let (name, g) = await search.pick(s) { item.place = name; item.geo = g }; saving = false }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).foregroundStyle(T.text)
                                    if !s.subtitle.isEmpty { Text(s.subtitle).font(.footnote).foregroundStyle(T.text2) }
                                }
                            }
                        }
                    }
                }
                if item.geo != nil, !item.allDay { travel }
                videoCall
                Section("Notes") {
                    TextEditor(text: $item.notes).frame(minHeight: 110).disabled(locked).accessibilityLabel("Notes")
                }
                extras
            }
            .navigationTitle("Edit event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { saving = true; Task { await save(); saving = false } }.fontWeight(.semibold).disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { if let q = app.demoPlace { app.demoPlace = nil; item.place = q; item.geo = nil; search.query(q) } }
            .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
        }
        // On the whole sheet, not the form (a picker page hides the form): still applied when the sheet closes, shake to undo takes all of them back.
        .onDisappear { if let a = added { app.undo.push { [weak store] in store?.saveEmoji(a.before) } } }
    }

    private var when: some View {
        Section("When") {
            Toggle("All day", isOn: Binding(get: { item.allDay }, set: { item = EventEdit.allDay(item, $0) })).disabled(locked)
            DatePicker("Date", selection: Binding(get: { item.start }, set: { item = EventEdit.date(item, $0) }), displayedComponents: .date).disabled(locked)
            if !item.allDay {
                DatePicker("Starts", selection: Binding(get: { item.start }, set: { item = EventEdit.start(item, $0) }), displayedComponents: .hourAndMinute).disabled(locked)
                DatePicker("Ends", selection: Binding(get: { item.end }, set: { item = EventEdit.end(item, $0) }), displayedComponents: .hourAndMinute).disabled(locked)
            }
        }
    }

    /// Alerts (approved mockup 2026-11-17): the Mac's choices, up to five, swipe left to remove. Saved on the event, so they ring everywhere.
    @ViewBuilder private var alerts: some View {
        if !locked {
            let cur = mins ?? alertMinutes(item)
            let google = store.accCal(item.calendarID)?.0.kind == "google"  // Google takes only alerts before the start
            let choices = (item.allDay ? allDayAlertChoices : alertChoices).filter { !(google && $0 < 0) }
            Section("Alerts") {
                ForEach(Array(cur.enumerated()), id: \.offset) { i, m in
                    Picker(i < Self.names.count ? Self.names[i] : "Alert", selection: Binding(get: { m }, set: { v in var a = cur; a[i] = v; mins = a })) {
                        ForEach(choices.contains(m) ? choices : [m] + choices, id: \.self) { Text(alertText($0, allDay: item.allDay)).tag($0) }
                    }
                }
                .onDelete { mins = cur.enumerated().filter { !$0.contains($0.offset) }.map(\.element) }
                if cur.count < maxAlerts, let next = ([item.allDay ? 900 : 15] + choices).first(where: { choices.contains($0) && !cur.contains($0) }) {
                    Button("Add alert") { mins = cur + [next] }
                }
            }
        }
    }
    private static let names = ["Alert", "Second alert", "Third alert", "Fourth alert", "Fifth alert"]

    @ViewBuilder private var videoCall: some View {
        let call = callLink(item)
        Section("Video call") {
            if let call {
                VStack(alignment: .leading, spacing: 10) {
                    Text(call.service).fontWeight(.medium)
                    Text((call.url.host ?? "") + call.url.path).font(.footnote).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 10) {
                        Button("Join") { UIApplication.shared.open(call.url) }.buttonStyle(.borderedProminent)
                        Button("Copy") { UIPasteboard.general.string = call.url.absoluteString }.buttonStyle(.bordered)
                    }
                }.buttonStyle(.borderless)
                if !locked, callLink(in: [item.link]) != nil { Button("Remove link", role: .destructive) { item.link = "" } }
            } else if locked {
                Text("No video call").foregroundStyle(T.text2)
            } else {
                TextField("Paste a Zoom, Meet or Teams link", text: $item.link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
    }

    @ViewBuilder private var travel: some View {
        Section {
            Toggle("Drive time", isOn: Binding(get: { !item.noTravel }, set: { item.noTravel = !$0 }))
            if !item.noTravel {
                Picker("From", selection: $item.from) { ForEach(From.allCases, id: \.self) { Text($0.label).tag($0) } }
                Toggle("Leave alert", isOn: Binding(get: { item.leave ?? WorkWeek.leave }, set: { item.leave = $0 }))
            }
        } header: { Text("Travel") } footer: {
            Text("Drive time comes from Apple Maps and is checked again an hour before, so traffic is counted.")
        }
    }

    @ViewBuilder private var extras: some View {
        Section {
            TextField("Emoji", text: Binding(get: { item.emoji }, set: { item.emoji = String($0.filter(\.isEmoji).prefix(1)) }))
                .accessibilityLabel("Emoji")
            emojiToAll
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                swatch(nil, store.calendar(item.calendarID)?.color ?? .gray, "Calendar color")
                ForEach(Palette.tags.indices, id: \.self) { swatch($0, Palette.tags[$0], "Color \($0 + 1)") }
            }
            ForEach(item.tags, id: \.self) { t in
                HStack { Text(t); Spacer(); Button { item.tags.removeAll { $0 == t } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(T.late) }.buttonStyle(.borderless).accessibilityLabel("Remove tag \(t)") }
            }
            if !tagsLeft.isEmpty {
                Menu("Pick a tag") { ForEach(tagsLeft, id: \.self) { t in Button(t) { item.tags.append(t) } } }
            }
            TextField("New tag", text: $newTag).submitLabel(.done).onSubmit(addTag)
        } header: { Text("Emoji, color and tags") } footer: {
            Text("Dateline keeps these. They also work on invites. They don't show in Apple Calendar.")
        }
    }

    // Approved picture (John 2026-11-17): the emoji to every loaded event with the same name on this calendar, with Undo.
    @ViewBuilder private var emojiToAll: some View {
        let same = store.sameName(as: original)
        if let a = added {
            HStack {
                Text("Added \(a.emoji) to \(a.before.count) events").foregroundStyle(T.text2)
                Spacer()
                Button("Undo") { if let f = store.saveEmoji(a.before) { problem = f.message }; added = nil }.buttonStyle(.borderless)
            }
        } else if !item.emoji.isEmpty, same.count > 1, same.contains(where: { $0.emoji != item.emoji }) {
            Button("Add \(item.emoji) to all \(same.count) \u{201C}\(original.title)\u{201D} events") {
                if let f = store.saveEmoji(same.map { var x = $0; x.emoji = item.emoji; return x }) { problem = f.message; return }
                added = (item.emoji, same)
                UIAccessibility.post(notification: .announcement, argument: "Added \(item.emoji) to \(same.count) events")
            }
        }
    }

    private func swatch(_ i: Int?, _ c: Color, _ name: String) -> some View {
        Button { item.color = i } label: {
            Circle().fill(c).frame(width: 28, height: 28)
                .overlay { if item.color == i { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                .frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.borderless).accessibilityLabel(name).accessibilityAddTraits(item.color == i ? .isSelected : [])
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !item.tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { item.tags.append(t) }
        newTag = ""
    }

    /// The Mac's commit(): a read-only calendar takes only the extras; an ended trial changes nothing.
    private func save() async {
        addTag()
        var n = item
        n.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.title : item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.place = item.place.trimmingCharacters(in: .whitespaces)
        if let m = mins {  // counted from the final start, so a start changed after the alerts keeps them the same time before
            var seen = Set<Int>()
            n.alerts = m.filter { seen.insert($0).inserted }.map { n.start.addingTimeInterval(-Double($0 * 60)) }
        }
        if n.place.isEmpty { n.geo = nil } else if n.geo == nil, n.place != original.place { n.geo = await PlaceSearch.find(n.place) }  // typed, not picked: look it up
        if let a = added { added = nil; app.undo.push { [weak store] in store?.saveEmoji(a.before) } }  // before the edit's own step, so shakes undo newest first
        if n != original {
            if let f = app.change(n, from: original, "Edited") {
                if store.trialOver { app.unlockNext = true } else { problem = f.message; return }
            } else if app.opened[n.id] != nil { app.opened[n.id] = n }  // opened from outside the days in view: show the saved copy
        }
        dismiss()
    }
}

private extension Character {
    var isEmoji: Bool { unicodeScalars.first.map { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && unicodeScalars.count > 1) } ?? false }
}
