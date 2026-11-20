// Repeat and Ends under When in the event panel, and the Custom window (approved Repeat mockup, 2026-11-20).
import SwiftUI
import DatelineCore

struct RepeatRows: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let item: Item
    let locked: Bool
    @State private var now: RepeatNow?
    @State private var custom: Repeat?
    @State private var asking: Repeat??  // waiting for "this and future" or "all"

    var current: Repeat? { if case .rule(let r) = now { return r.normal(item.start) }; return nil }

    var body: some View {
        row("Repeat") {
            Menu {
                ForEach(Array(Repeat.menu(item.start).enumerated()), id: \.offset) { _, r in
                    // A menu choice keeps the end already set.
                    let pick = r.map { var x = $0; x.count = current?.count; x.until = current?.until; return x }
                    Button { choose(pick) } label: {
                        if pick == current || (pick == nil && now == .never) { Label(r?.text(item.start) ?? "Never", systemImage: "checkmark") } else { Text(r?.text(item.start) ?? "Never") }
                    }
                }
                Divider()
                Button("Custom…") { custom = current ?? Repeat(unit: "w", n: 1).normal(item.start) }
            } label: { Text(title) }
            .menuStyle(.borderlessButton).fixedSize().disabled(locked || now == nil)
        }
        if let r = current {
            row("Ends") { EndsPicker(r: Binding(get: { r }, set: { apply($0, all: true) }), start: item.start).disabled(locked) }
        }
        Color.clear.frame(height: 0)  // carries the reading and the windows, which a bare EmptyView would never show
            .task(id: item.id) { now = await store.repeatNow(item) }
            .sheet(isPresented: Binding(get: { custom != nil }, set: { if !$0 { custom = nil } })) {
                if let r = custom { CustomRepeat(r: r, start: item.start) { done in custom = nil; if let done { choose(done) } } }
            }
            .confirmationDialog("Change the repeat?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible) {
                Button("This and future events") { if let r = asking { apply(r, all: false) } }
                Button("All events") { if let r = asking { apply(r, all: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This is a repeating event.") }
    }

    var title: String {
        switch now {
        case nil: return "…"
        case .never: return "Never"
        case .other: return "Repeats (set in another app)"
        case .rule(let r): var shape = r; shape.count = nil; shape.until = nil; return shape.text(item.start)
        }
    }

    // A one-time event just takes it; a repeating one asks which times it is for, as delete does.
    func choose(_ r: Repeat?) {
        if now == .never { if r != nil { apply(r, all: true) } } else if r != current { asking = .some(r) }
    }

    // shortcut: a repeat change is not on the Command Z list; add it if undoing one is missed.
    func apply(_ r: Repeat?, all: Bool) {
        if let f = store.setRepeat(item, r, all: all) { app.error = f.message; return }
        now = r.map(RepeatNow.rule) ?? .never
        // Becoming (or ending) a series can give the event a new identifier: keep it selected.
        if !store.items.contains(where: { $0.id == item.id }), let same = store.items.first(where: { $0.calendarID == item.calendarID && $0.title == item.title && $0.start == item.start }) {
            app.selectedID = same.id
        }
    }

    func row<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 64, alignment: .leading); v(); Spacer(minLength: 0) }.padding(.top, 8)
    }
}

// Never, on a date, or after a number of times.
struct EndsPicker: View {
    @Binding var r: Repeat
    let start: Date
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Never") { r.count = nil; r.until = nil }
                Button("On a date") { r.count = nil; r.until = cal.date(byAdding: .month, value: 3, to: cal.startOfDay(for: start)) }
                Button("After a number of times") { r.until = nil; r.count = 10 }
            } label: { Text(r.count != nil ? "After" : r.until != nil ? "On" : "Never") }.menuStyle(.borderlessButton).fixedSize()
            if let u = r.until {
                DatePicker("", selection: Binding(get: { u }, set: { r.until = cal.startOfDay(for: $0) }), in: cal.startOfDay(for: start)..., displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
            }
            if let n = r.count { Stepper(value: Binding(get: { n }, set: { r.count = max(1, $0) }), in: 1...999) { Text("\(n) " + (n == 1 ? "time" : "times")) } }
        }
    }
}

struct CustomRepeat: View {
    @State var r: Repeat
    let start: Date
    let done: (Repeat?) -> Void  // nil: Cancel
    static let units: [(Character, String, String)] = [("d", "Daily", "day"), ("w", "Weekly", "week"), ("m", "Monthly", "month"), ("y", "Yearly", "year")]

    var body: some View {
        let wd = cal.component(.weekday, from: start)
        let unit = Self.units.first { $0.0 == r.unit }!
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom repeat").font(.ui(15, weight: .semibold))
            line("Repeats") {
                Seg(options: Self.units.map(\.1), selected: unit.1, small: true) { name in
                    let u = Self.units.first { $0.1 == name }!.0
                    r = Repeat(unit: u, n: r.n, days: u == "w" ? [wd] : [], count: r.count, until: r.until)
                }
            }
            line("Every") {
                Stepper(value: $r.n, in: 1...99) { Text("\(r.n)").monospacedDigit() }
                Text(unit.2 + (r.n == 1 ? "" : "s") + (r.unit == "w" ? " on" : ""))
            }
            if r.unit == "w" {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { d in
                        let on = r.days.contains(d)
                        Button { if on { r.days.removeAll { $0 == d } } else { r.days = (r.days + [d]).sorted() } } label: {
                            Text(String(Repeat.dayNames[d - 1].prefix(1))).font(.ui(12, weight: .medium)).frame(width: 28, height: 28)
                                .foregroundStyle(on ? Color.white : Palette.text2).background(Circle().fill(on ? Color.accentColor : Palette.lineSoft))
                        }.buttonStyle(.plain).accessibilityLabel(Repeat.dayNames[d - 1]).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.padding(.leading, 72)
            }
            if r.unit == "m" {
                VStack(alignment: .leading, spacing: 8) {
                    radio(r.nth == nil, "On day \(cal.component(.day, from: start))") { r.nth = nil; r.days = [] }
                    HStack(spacing: 6) {
                        radio(r.nth != nil, "On the") { if r.nth == nil { r.nth = Repeat.nthOf(start); r.days = [wd] } }
                        Menu { ForEach([1, 2, 3, 4, -1], id: \.self) { k in Button(Repeat.nthNames[k]!) { r.nth = k; if r.days.isEmpty { r.days = [wd] } } } }
                            label: { Text(Repeat.nthNames[r.nth ?? Repeat.nthOf(start)]!) }.menuStyle(.borderlessButton).fixedSize()
                        Menu {
                            ForEach(1...7, id: \.self) { d in Button(Repeat.dayNames[d - 1]) { r.days = [d]; if r.nth == nil { r.nth = Repeat.nthOf(start) } } }
                            Button("weekday") { r.days = Repeat.weekdays; if r.nth == nil { r.nth = Repeat.nthOf(start) } }
                        } label: { Text(r.days == Repeat.weekdays ? "weekday" : Repeat.dayNames[(r.days.first ?? wd) - 1]) }.menuStyle(.borderlessButton).fixedSize()
                    }
                }.padding(.leading, 72)
            }
            line("Ends") { EndsPicker(r: $r, start: start) }
            Text(r.unit == "w" && r.days.isEmpty ? "Pick at least one day." : r.text(start))
                .foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Done") { done(r) }.keyboardShortcut(.defaultAction).disabled(r.unit == "w" && r.days.isEmpty)
            }
        }.padding(20).frame(width: 400).background(Palette.pop)
    }

    func line<V: View>(_ k: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 8) { Text(k).foregroundStyle(Palette.text3).frame(width: 64, alignment: .leading); v(); Spacer(minLength: 0) }
    }
    func radio(_ on: Bool, _ text: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { HStack(spacing: 6) { Image(systemName: on ? "largecircle.fill.circle" : "circle"); Text(text) } }
            .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}
