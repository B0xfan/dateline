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
                            ForEach(writable) { k in Text(k.title + " (" + k.account + ")").tag(k.id) }
                        }
                    }
                }
                if locked { Section { Text("This calendar is read only. You can still add an emoji, a color and tags.").font(.footnote).foregroundStyle(T.text2) } }
                when
                Section("Show as") {
                    Picker("Show as", selection: $item.showAs) { ForEach(ShowAs.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).disabled(locked)
                }
                Section("Place") {
                    if locked { Text(item.place.isEmpty ? "No place" : item.place).foregroundStyle(item.place.isEmpty ? T.text2 : T.text) }
                    else { TextField("Place", text: $item.place) }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: save).fontWeight(.semibold) }
            }
            .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} }
        }
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
    private func save() {
        addTag()
        var n = item
        n.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.title : item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.place = item.place.trimmingCharacters(in: .whitespaces)
        if n.place != original.place { n.geo = nil }  // a typed place has no spot on the map until it is looked up
        if n != original {
            if let f = store.update(n) {
                if store.trialOver { app.unlockNext = true } else { problem = f.message; return }
            } else if app.opened[n.id] != nil { app.opened[n.id] = n }  // opened from outside the days in view: show the saved copy
        }
        dismiss()
    }
}

private extension Character {
    var isEmoji: Bool { unicodeScalars.first.map { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && unicodeScalars.count > 1) } ?? false }
}
