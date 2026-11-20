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
    let duplicate: Bool  // Duplicate on the details screen: a new copy, a day later, saved with Add
    @State private var repeatNow: RepeatNow?  // as saved; nil while it is read
    @State private var repeatPick: Repeat?
    @State private var repeatTouched = false
    @State private var askSpan = false
    @State private var saving = false
    @State private var mins: [Int]?  // the alerts, in minutes before the start, once changed here; applied to the final start on Done
    @State private var added: (emoji: String, before: [Item])?  // what "Add to all" just did, for its Undo
    @StateObject private var search = PlaceSearch()

    init(_ it: Item, duplicate: Bool = false) {
        original = it; self.duplicate = duplicate
        var copy = it
        if duplicate { copy.start = addDays(it.start, 1); copy.end = addDays(it.end, 1) }
        _item = State(initialValue: copy)
    }

    private var locked: Bool { !duplicate && store.calendar(item.calendarID)?.writable != true }  // an invite's title is the sender's, as on the Mac
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
                if locked && !duplicate { Section { Text("This calendar is read only. You can still add an emoji, a color, tags and travel.").font(.footnote).foregroundStyle(T.text2) } }
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
            .navigationTitle(duplicate ? "Duplicate" : "Edit event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(duplicate ? "Add" : "Done", action: save).fontWeight(.semibold).disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { if let q = app.demoPlace { app.demoPlace = nil; item.place = q; item.geo = nil; search.query(q) } }
            .task {
                // A copy of a read-only event goes to one of your own calendars.
                if duplicate, store.calendar(item.calendarID)?.writable != true, let c = store.calendars.first(where: { $0.id == store.defaultCalendarID && $0.writable }) ?? writable.first { item.calendarID = c.id }
                guard !duplicate else { return }
                let now = await store.repeatNow(original)
                repeatNow = now
                if case .rule(let r) = now { repeatPick = r.normal(original.start) }
            }
            .confirmationDialog("Change the repeat?", isPresented: $askSpan, titleVisibility: .visible) {
                Button("This and future events") { run(all: false) }
                Button("All events") { run(all: true) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This is a repeating event.") }
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
            if let now = repeatNow, !isBlocks(item.calendarID) {  // the Planner's time blocks don't repeat
                NavigationLink {
                    RepeatPicker(r: Binding(get: { repeatPick }, set: { repeatPick = $0; repeatTouched = true }), start: item.start)
                } label: {
                    LabeledContent("Repeat", value: now == .other && !repeatTouched ? "Set in another app" : repeatPick.map { var shape = $0; shape.count = nil; shape.until = nil; return shape.text(item.start) } ?? "Never")
                }.disabled(locked)
                if let r = repeatPick {
                    RepeatEnds(r: Binding(get: { r }, set: { repeatPick = $0; repeatTouched = true }), start: item.start).disabled(locked)
                }
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
                ForEach(Array(cur.enumerated()), id: \.offset) { i, m in alertPicker(i, m, cur, choices) }
                .onDelete { (gone: IndexSet) in mins = cur.enumerated().filter { !gone.contains($0.offset) }.map(\.element) }
                if cur.count < maxAlerts, let next = nextAlert(cur, choices) {
                    Button("Add alert") { mins = cur + [next] }
                }
            }
        }
    }
    private static let names = ["Alert", "Second alert", "Third alert", "Fourth alert", "Fifth alert"]
    private func nextAlert(_ cur: [Int], _ choices: [Int]) -> Int? {
        let first: Int = item.allDay ? 900 : 15
        return ([first] + choices).first { (m: Int) in choices.contains(m) && !cur.contains(m) }
    }
    private func alertPicker(_ i: Int, _ m: Int, _ cur: [Int], _ choices: [Int]) -> some View {
        let set = Binding<Int>(get: { m }, set: { v in var a = cur; a[i] = v; mins = a })
        let list: [Int] = choices.contains(m) ? choices : [m] + choices
        return Picker(i < Self.names.count ? Self.names[i] : "Alert", selection: set) {
            ForEach(list, id: \.self) { (v: Int) in Text(alertText(v, allDay: item.allDay)).tag(v) }
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

    private var repeatChanged: Bool {
        guard repeatTouched, let now = repeatNow else { return false }
        if case .rule(let r) = now { return repeatPick?.normal(item.start) != r.normal(original.start) }
        return now == .never ? repeatPick != nil : true
    }

    /// A repeat change on a repeating event asks which times it is for, as delete does.
    private func save() {
        if repeatChanged, repeatNow != .never { askSpan = true } else { run(all: true) }
    }

    private func run(all: Bool) { saving = true; Task { await commit(all: all); saving = false } }

    /// The Mac's commit(): a read-only calendar takes only the extras; an ended trial changes nothing.
    private func commit(all: Bool) async {
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
        if duplicate {
            if let f = app.duplicate(n) { if store.trialOver { app.unlockNext = true } else { problem = f.message; return } }
            dismiss(); return
        }
        // The repeat first, on the event as it was, so the series (not one changed time) takes it; then the other edits.
        var was = original
        if repeatChanged {
            if let f = store.setRepeat(original, repeatPick, all: all) { if store.trialOver { app.unlockNext = true } else { problem = f.message; return } }
            // Becoming (or ending) a series can give the event a new identifier: keep its details open.
            if app.item(original.id) == nil, let same = store.items.first(where: { $0.calendarID == original.calendarID && $0.title == original.title && $0.start == original.start }) {
                app.path = app.path.map { $0 == original.id ? same.id : $0 }
                was = same; n.id = same.id
            }
        }
        if n != was {
            if let f = app.change(n, from: was, "Edited") {
                if store.trialOver { app.unlockNext = true } else { problem = f.message; return }
            } else if app.opened[n.id] != nil { app.opened[n.id] = n }  // opened from outside the days in view: show the saved copy
        }
        dismiss()
    }
}

private extension Character {
    var isEmoji: Bool { unicodeScalars.first.map { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && unicodeScalars.count > 1) } ?? false }
}

/// The Repeat screen (approved Repeat mockup, 2026-11-20): the choices for the event's own day, then Custom to fine-tune.
struct RepeatPicker: View {
    @Binding var r: Repeat?
    let start: Date
    static let units: [(Character, String, String)] = [("d", "Daily", "day"), ("w", "Weekly", "week"), ("m", "Monthly", "month"), ("y", "Yearly", "year")]

    var body: some View {
        let wd = cal.component(.weekday, from: start)
        Form {
            Section {
                ForEach(Array(Repeat.menu(start).enumerated()), id: \.offset) { _, choice in
                    let pick = choice.map { var x = $0; x.count = r?.count; x.until = r?.until; return x }  // a choice keeps the end already set
                    Button { r = pick } label: {
                        HStack { Text(choice?.text(start) ?? "Never").foregroundStyle(T.text); Spacer(); if pick == r?.normal(start) { Image(systemName: "checkmark").foregroundStyle(T.tint) } }
                    }
                }
            }
            Section {
                if let cur = r {
                    let unit = Self.units.first { $0.0 == cur.unit }!
                    Picker("Repeats", selection: Binding(get: { cur.unit }, set: { u in r = Repeat(unit: u, n: cur.n, days: u == "w" ? [wd] : [], count: cur.count, until: cur.until) })) {
                        ForEach(Self.units, id: \.0) { Text($0.1).tag($0.0) }
                    }.pickerStyle(.segmented)
                    Stepper(value: Binding(get: { cur.n }, set: { r?.n = $0 }), in: 1...99) { Text("Every \(cur.n) " + unit.2 + (cur.n == 1 ? "" : "s")) }
                    if cur.unit == "w" {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { d in
                                let on = cur.normal(start).days.contains(d)
                                Button {
                                    var days = cur.normal(start).days
                                    if on { if days.count > 1 { days.removeAll { $0 == d } } } else { days.append(d) }
                                    r?.days = days.sorted()
                                } label: {
                                    Text(String(Repeat.dayNames[d - 1].prefix(1))).font(.subheadline.weight(.medium)).frame(width: 38, height: 38)
                                        .foregroundStyle(on ? Color.white : T.text).background(Circle().fill(on ? T.tint : T.line))
                                }.buttonStyle(.borderless).frame(maxWidth: .infinity).accessibilityLabel(Repeat.dayNames[d - 1]).accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    if cur.unit == "m" {
                        Picker("On", selection: Binding(get: { cur.nth == nil }, set: { onDate in
                            if onDate { r?.nth = nil; r?.days = [] } else { r?.nth = Repeat.nthOf(start); r?.days = [wd] }
                        })) {
                            Text("Day \(cal.component(.day, from: start))").tag(true)
                            Text("A weekday").tag(false)
                        }.pickerStyle(.segmented)
                        if let k = cur.nth {
                            Picker("Which", selection: Binding(get: { k }, set: { r?.nth = $0 })) { ForEach([1, 2, 3, 4, -1], id: \.self) { Text(Repeat.nthNames[$0]!.capitalized).tag($0) } }
                            Picker("Day", selection: Binding(get: { cur.days == Repeat.weekdays ? 0 : cur.days.first ?? wd }, set: { r?.days = $0 == 0 ? Repeat.weekdays : [$0] })) {
                                ForEach(1...7, id: \.self) { Text(Repeat.dayNames[$0 - 1]).tag($0) }
                                Text("Weekday").tag(0)
                            }
                        }
                    }
                } else {
                    Button("Custom…") { r = Repeat(unit: "w", n: 1).normal(start) }
                }
            } header: { Text("Custom") } footer: { if let cur = r { Text(cur.text(start)) } }
        }
        .navigationTitle("Repeat").navigationBarTitleDisplayMode(.inline)
    }
}

/// Never, on a date, or after a number of times.
struct RepeatEnds: View {
    @Binding var r: Repeat
    let start: Date
    var body: some View {
        Picker("Ends", selection: Binding(get: { r.count != nil ? 2 : r.until != nil ? 1 : 0 }, set: { k in
            r.count = k == 2 ? 10 : nil
            r.until = k == 1 ? cal.date(byAdding: .month, value: 3, to: cal.startOfDay(for: start)) : nil
        })) { Text("Never").tag(0); Text("On a date").tag(1); Text("After a number of times").tag(2) }
        if let u = r.until {
            DatePicker("End date", selection: Binding(get: { u }, set: { r.until = cal.startOfDay(for: $0) }), in: cal.startOfDay(for: start)..., displayedComponents: .date)
        }
        if let n = r.count { Stepper(value: Binding(get: { n }, set: { r.count = max(1, $0) }), in: 1...999) { Text("\(n) " + (n == 1 ? "time" : "times")) } }
    }
}
