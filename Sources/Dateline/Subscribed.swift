// Phase 7 (F4, F5, approved mockup): calendars from a web address, and a short list of ready-made ones.
// Read-only and kept by Dateline on this Mac: the address is read every hour, day or week, and the last copy stays when it stops working.
import Foundation
import SwiftUI
import AppKit
import DatelineCore

struct SubscribeSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    @State var tab = 0
    @State var address = ""
    @State var name = ""
    @State var color = 3
    @State var hours = 24
    @State var alerts = false
    @State var checking = false
    @State var found: (String, [ICalEvent])?
    @State var problem: String?
    @State var group = "All"
    @State var checked = ""  // the address `found` belongs to

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) { Text("Web address").tag(0); Text("Ready-made").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240).frame(maxWidth: .infinity)
            if tab == 0 { web } else { ready }
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(width: 580)
        .background(Palette.pop)
        .font(.ui(13))
    }

    var web: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Subscribe to a calendar").font(.ui(15, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Paste a calendar's web address", text: $address).textFieldStyle(.roundedBorder)
                    Button("Paste") { if let s = NSPasteboard.general.string(forType: .string) { address = s } }
                }
                Text("Addresses that start with webcal:// or https:// both work.").font(.ui(12)).foregroundStyle(Palette.text3)
            }
            if checking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the address…").foregroundStyle(Palette.text2) }.font(.ui(12))
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.ui(12)).foregroundStyle(Palette.now).fixedSize(horizontal: false, vertical: true)
            } else if let events = found?.1 {
                let next = upcoming(events)
                Label("Found it: \(events.count) event\(events.count == 1 ? "" : "s")" + (next.first.map { ", the next one " + when($0.start) } ?? ", none coming up"),
                      systemImage: "checkmark.circle.fill").font(.ui(12)).foregroundStyle(Palette.tags[2])
                if !next.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("COMING UP IN THIS CALENDAR").font(.ui(11, weight: .semibold)).foregroundStyle(Palette.text3)
                        ForEach(next) { it in
                            HStack(spacing: 8) {
                                Circle().fill(Palette.tags[color]).frame(width: 8, height: 8)
                                Text(dateText(it.start, "EEE MMM d")).foregroundStyle(Palette.text3).monospacedDigit().frame(width: 76, alignment: .leading)
                                Text(it.title + (it.allDay ? "" : ", " + timeText(it.start))).lineLimit(1)
                            }
                        }
                    }
                    .font(.ui(12)).padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.side)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow { Text("Name").foregroundStyle(Palette.text2); TextField("", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Color").foregroundStyle(Palette.text2); Swatches(pick: $color) }
                GridRow {
                    Text("Update").foregroundStyle(Palette.text2)
                    Picker("", selection: $hours) { Text("Every hour").tag(1); Text("Every day").tag(24); Text("Every week").tag(168) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow { Text("Alerts").foregroundStyle(Palette.text2); Toggle("Alert me for these events", isOn: $alerts).toggleStyle(.switch).controlSize(.small) }
            }
            Divider().overlay(Palette.line)
            HStack {
                Text("You can't change these events; they come from the address.").font(.ui(12)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Cancel") { app.panels.subscribing = false }.keyboardShortcut(.cancelAction)
                Button("Subscribe") { add() }.keyboardShortcut(.defaultAction).disabled(found == nil || checking)
            }
        }
        .task(id: address) {
            guard address != checked || found == nil else { return }  // back to a checked address after an error: check it again
            found = nil; problem = nil
            guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { checking = false; return }
            guard let u = subAddress(address) else { checking = false; problem = "That isn't a web address. It should start with webcal:// or https://."; return }
            checking = true
            try? await Task.sleep(nanoseconds: 600_000_000)  // wait for typing to stop
            guard !Task.isCancelled else { return }
            if store.subs.contains(where: { subAddress($0.url) == u }) { checking = false; problem = "You're already subscribed to this calendar."; return }
            let r = await downloadCalendar(u)
            guard !Task.isCancelled else { return }
            checking = false
            switch r {
            case .success(let v):
                found = v; checked = address
                if name.isEmpty { name = calendarName(v.0) ?? u.host ?? "Subscribed" }
            case .failure(let f): problem = f.message
            }
        }
    }

    var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(["All", "Holidays", "Sky", "Sports"], id: \.self) { g in
                    Button(g) { group = g }.buttonStyle(.plain).font(.ui(12))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .foregroundStyle(group == g ? .white : Palette.text2)
                        .background(Capsule().fill(group == g ? Palette.accent : .clear))
                        .overlay(Capsule().strokeBorder(group == g ? Palette.accent : Palette.line))
                }
            }
            VStack(spacing: 0) {
                let list = readyMade.filter { group == "All" || $0.group == group }
                ForEach(list) { r in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).fontWeight(.semibold)
                            Text(r.about).font(.ui(12)).foregroundStyle(Palette.text3)
                        }
                        Spacer()
                        if added(r) { Label("Added", systemImage: "checkmark").font(.ui(12)).foregroundStyle(Palette.tags[2]) }
                        else { Button("Add") { store.subscribe(Sub(url: r.url, kind: r.kind, name: r.name, color: r.color, hours: 168)) } }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    if r.id != list.last?.id { Divider().overlay(Palette.lineSoft) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            Text("The list is small on purpose and free: each one is a public web address checked to work before it went in. More can come in a later update.")
                .font(.ui(12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Palette.line)
            HStack {
                let n = readyMade.filter(added).count
                Text(n == 0 ? "None added" : "\(n) added").font(.ui(12)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Done") { app.panels.subscribing = false }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func added(_ r: ReadyMade) -> Bool { store.subs.contains { r.kind != nil ? $0.kind == r.kind : $0.url == r.url } }

    func upcoming(_ events: [ICalEvent]) -> [Item] {
        let now = sampleToday ?? Date()
        let s = Sub(url: "", name: "", color: color)
        return Array(subItems(s, events, from: now, to: now.addingTimeInterval(400 * 86400)).sorted { $0.start < $1.start }.prefix(3))
    }

    func when(_ d: Date) -> String {
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: sampleToday ?? Date()), to: cal.startOfDay(for: d)).day ?? 99
        return n == 0 ? "today" : n == 1 ? "tomorrow" : n < 7 ? "on " + dateText(d, "EEEE") : "on " + dateText(d, "MMMM d")
    }

    func add() {
        guard let f = found else { return }
        let (text, events) = f
        let n = name.trimmingCharacters(in: .whitespaces)
        store.subscribe(Sub(url: address.trimmingCharacters(in: .whitespacesAndNewlines), name: n.isEmpty ? "Subscribed" : n, color: color, hours: hours, alerts: alerts),
                        text: text, events: events)
        app.panels.subscribing = false
    }
}

struct Swatches: View {
    @Binding var pick: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Palette.tags.indices, id: \.self) { i in
                Button { pick = i } label: {
                    Circle().fill(Palette.tags[i]).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Palette.tags[i], lineWidth: 2).padding(-4).opacity(pick == i ? 1 : 0))
                }.buttonStyle(.plain).padding(4)
            }
        }
    }
}

// The "Subscribed" group in the sidebar, with its right-click menu.
struct SubscribedList: View {
    @ObservedObject var app: AppState
    @ObservedObject var store: Store
    let row: (CalInfo, AnyView?) -> AnyView
    @State var renaming: Sub?
    @State var newName = ""

    var body: some View {
        if !store.subs.isEmpty {
            Text("Subscribed").font(.ui(11)).foregroundStyle(Palette.text3).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            ForEach(store.subs) { s in
                if let c = store.calendar(s.id) {
                    row(c, AnyView(status(s)))
                        .contextMenu {
                            if s.kind == nil { Button("Update now") { store.refreshSub(s.id) } }
                            Button("Rename…") { newName = s.name; renaming = s }
                            Menu("Color") {
                                ForEach(Array(["Red", "Orange", "Green", "Teal", "Blue", "Purple", "Pink", "Gray"].enumerated()), id: \.offset) { i, n in
                                    Button(n) { store.editSub(s.id) { $0.color = i } }
                                }
                            }
                            if s.kind == nil {
                                Toggle("Alert me for these events", isOn: Binding(get: { s.alerts }, set: { v in store.editSub(s.id) { $0.alerts = v } }))
                                Menu("Update") {
                                    ForEach([(1, "Every hour"), (24, "Every day"), (168, "Every week")], id: \.0) { h, n in
                                        Toggle(n, isOn: Binding(get: { s.hours == h }, set: { _ in store.editSub(s.id) { $0.hours = h } }))
                                    }
                                }
                            }
                            Divider()
                            Button("Remove", role: .destructive) { store.unsubscribe(s.id) }
                        }
                }
            }
        }
        Color.clear.frame(height: 0)
            .alert("Rename calendar", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    if let s = renaming, !n.isEmpty { store.editSub(s.id) { $0.name = n } }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }

    @ViewBuilder func status(_ s: Sub) -> some View {
        if let p = s.problem {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.tags[1]).help(p + " The last events stay until it works again.")
        } else if let u = s.updated {
            let when = cal.isDateInToday(u) ? timeText(u) : dateText(u, "MMM d")
            // A long name keeps its room: the label drops the word "updated" before the name is cut.
            ViewThatFits(in: .horizontal) {
                Text("updated " + when)
                Text(when).fixedSize()
            }.font(.ui(11)).foregroundStyle(Palette.text3).help("Updated " + when)
        }
    }
}

// MARK: sample and self-test

