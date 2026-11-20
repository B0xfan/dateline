// The watch screens, from the approved mockups: Next up and Today (the crown moves between them), the event details, and Add by voice.
import SwiftUI
import DatelineCore

struct WatchRoot: View {
    @EnvironmentObject var app: WatchState
    var body: some View {
        #if DEBUG
        if let f = app.face { FacePictures(stack: f == "stack") } else { screens }
        #else
        screens
        #endif
    }
    var screens: some View {
        NavigationStack(path: $app.path) {
            TabView(selection: $app.page) {
                NextUp().tag(0)
                TodayList().tag(1)
            }
            .tabViewStyle(.verticalPage)
            .navigationDestination(for: String.self) { id in EventDetails(id: id) }
        }
        .sheet(isPresented: $app.adding) { AddByVoice(text: app.addStart) }
    }
}

/// 1 · Next up: the next event, how long until it starts, and when to leave when it has a drive time.
struct NextUp: View {
    @EnvironmentObject var app: WatchState
    @EnvironmentObject var store: Store
    var body: some View {
        VStack {
            if let it = pickNext(app.coming, at: app.now) {
                NavigationLink(value: it.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.start <= app.now ? "Now" : countdown(to: it.start, from: app.now))
                            .font(.title3.weight(.semibold)).foregroundStyle(store.color(it))
                        Text((it.emoji.isEmpty ? "" : it.emoji + " ") + it.title).font(.headline).lineLimit(2)
                        Text(timeText(it.start) + (it.place.isEmpty ? "" : " · " + it.place)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        if let m = app.drive[it.id] {
                            Label("Leave \(timeText(it.start.addingTimeInterval(-Double(m) * 60))) · \(m) min", systemImage: "car.fill")
                                .font(.footnote).foregroundStyle(Palette.tags[3]).padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text("Nothing more today").font(.headline).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            Text("Turn the crown for today").font(.caption2).foregroundStyle(.tertiary)
        }
        .navigationTitle("Next")
    }
}

/// 2 · Today: events and tasks together. A circle ticks a task off; the phone saves it to Reminders.
struct TodayList: View {
    @EnvironmentObject var app: WatchState
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            ForEach(app.tasks) { t in
                Button { app.tick(t) } label: {
                    HStack {
                        Image(systemName: app.isDone(t) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOverdue(t, now: app.now) ? .red : store.taskList(t.listID)?.color ?? .accentColor)
                        VStack(alignment: .leading) {
                            Text(t.title).strikethrough(app.isDone(t)).foregroundStyle(app.isDone(t) ? .secondary : .primary)
                            if isOverdue(t, now: app.now), let d = t.due { Text("from " + shortDay(d, now: app.now)).font(.caption2).foregroundStyle(.red) }
                        }
                    }
                }
            }
            ForEach(app.today) { it in
                NavigationLink(value: it.id) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(store.color(it)).frame(width: 4)
                        VStack(alignment: .leading) {
                            Text(it.title).lineLimit(2)
                            Text(it.allDay ? "All day" : timeText(it.start, short: true) + (it.place.isEmpty ? "" : " · " + it.place))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .opacity(!it.allDay && it.end <= app.now ? 0.5 : 1)  // already over
            }
        }
        .navigationTitle(dayText(app.now, month: false))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { app.addStart = ""; app.adding = true } label: { Image(systemName: "mic.fill") } } }
    }
}

/// Tap an event: time, place, drive time and Directions; a video call shows Join instead. Editing stays on the phone.
struct EventDetails: View {
    @EnvironmentObject var app: WatchState
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    let id: String
    var body: some View {
        ScrollView {
            if let it = app.item(id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(it.title).font(.headline).foregroundStyle(store.color(it))
                    Text(it.allDay ? "All day" : timeText(it.start, short: true) + " to " + timeText(it.end)).font(.footnote)
                    if !it.place.isEmpty { Text(it.place).font(.footnote).foregroundStyle(.secondary) }
                    if let m = app.drive[it.id] {
                        Label("\(m) min drive · leave \(timeText(it.start.addingTimeInterval(-Double(m) * 60)))", systemImage: "car.fill")
                            .font(.footnote).foregroundStyle(Palette.tags[3])
                    }
                    if let call = callLink(it) {
                        Button("Join " + call.service) { openURL(call.url) }.tint(.green)
                    } else if let g = it.geo {
                        Button("Directions") { openInMaps(g, name: it.place, directions: true) }.tint(Palette.tags[3])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("That event is gone.").foregroundStyle(.secondary)
            }
        }
    }
}

/// 5 · Add by voice: speak, see what Dateline understood, tap Add. The phone reads the same sentence and saves it.
struct AddByVoice: View {
    @EnvironmentObject var app: WatchState
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    @State private var problem: String?
    @State private var sending = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Say an event", text: $text)  // tapping it opens dictation
                if !text.isEmpty {
                    let p = parseSentence(text, now: app.now)
                    Text(p.title.isEmpty ? "New event" : p.title).font(.headline)
                    Text(dayText(p.start) + (p.allDay ? "" : " · " + timeText(p.start)))
                        .font(.footnote)
                    if !p.place.isEmpty { Text(p.place).font(.footnote).foregroundStyle(.secondary) }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    Button(sending ? "Adding…" : "Add") {
                        sending = true
                        app.add(text) { err in sending = false; if let err { problem = err } else { dismiss() } }
                    }
                    .tint(Palette.tags[3]).disabled(sending)
                }
            }
        }
        .navigationTitle("Add")
    }
}

#if DEBUG
/// Pictures only: the face pieces as they sit on a Modular face (mockup 4), or the Smart Stack card, on the sample calendars.
/// A stand-in for the real face, which the simulator can't set up; the pieces are the same views the extension shows.
struct FacePictures: View {
    let stack: Bool
    @EnvironmentObject var app: WatchState
    @EnvironmentObject var store: Store
    var body: some View {
        let e = FaceEntry.timeline(now: app.now, items: store.between(app.now, addDays(cal.startOfDay(for: app.now), 1)),
                                   colors: Dictionary(store.calendars.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a }),
                                   drive: app.drive, tasks: store.todos)[0]
        VStack(spacing: 6) {
            if stack {
                Text(dateText(app.now, "h:mm")).font(.system(size: 34, weight: .semibold, design: .rounded))
                FacePiece(kind: .card, e: e).padding(10).background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            } else {
                FacePiece(kind: .inline, e: e).font(.footnote.weight(.semibold)).foregroundStyle(.red).lineLimit(1)
                Text(dateText(app.now, "h:mm")).font(.system(size: 40, weight: .semibold, design: .rounded))
                FacePiece(kind: .box, e: e).padding(8).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    ForEach([FaceKind.countdown, .date, .tasks], id: \.self) { k in FacePiece(kind: k, e: e).frame(width: 46, height: 46).clipShape(Circle()) }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}
#endif
