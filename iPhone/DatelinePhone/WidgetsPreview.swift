// Approved mockup "Widgets and alerts", drawn from the calendar for the screen pictures only.
// shortcut: the real Home Screen widgets and the leave alert are a later step (WidgetKit and notifications); this shows what they will hold.
import SwiftUI
import DatelineCore

struct WidgetsPreview: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store

    var body: some View {
        let day = addDays(cal.startOfDay(for: app.today), 2)
        let list = store.shown(on: day).sorted { ($0.allDay ? 1 : 0, $0.start) < ($1.allDay ? 1 : 0, $1.start) }
        let leave = list.first { app.drive[$0.id] != nil }
        let next = store.soon.filter { !store.hidden.contains($0.calendarID) && !$0.allDay && $0.start > app.today }.min { $0.start < $1.start }
        let wx = app.wx(day)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.23, green: 0.36, blue: 0.55), Color(red: 0.12, green: 0.17, blue: 0.28), Color(red: 0.07, green: 0.1, blue: 0.17)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                if let it = leave, let m = app.drive[it.id] {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 10) {
                            Text(dateText(app.today, "d")).font(.caption2.bold()).frame(width: 24, height: 24).background(T.accent, in: RoundedRectangle(cornerRadius: 6))
                            Text("DATELINE").font(.footnote.bold())
                            Spacer()
                            Text("now").font(.footnote).opacity(0.8)
                        }
                        Text("Leave now for \(it.title)").font(.subheadline.weight(.semibold)).padding(.top, 4)
                        Text("\(timeText(it.start, short: true)) at \(it.place) · \(m) min drive").font(.subheadline)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 20))
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dateText(day, "EEEE").uppercased()).font(.caption.bold()).foregroundStyle(T.accent)
                        Text(dateText(day, "d")).font(.system(size: 40, weight: .semibold))
                        if let wx { Text("\(degrees(wx.hi)) · \(wxLook(wx.code).words.lowercased())").font(.caption).foregroundStyle(T.text2).padding(.top, 6) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(list.prefix(2)) { it in
                            HStack(spacing: 8) {
                                Bar(color: store.color(it), height: 30)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(it.title).fontWeight(.semibold).lineLimit(1)
                                    Text(it.allDay ? "All day" : timeText(it.start, short: true) + (app.drive[it.id].map { " · leave " + timeText(it.start.addingTimeInterval(-Double($0) * 60)) } ?? ""))
                                        .foregroundStyle(T.text2).lineLimit(1)
                                }
                            }
                        }
                        if list.count > 2 { Text("+\(list.count - 2) more").foregroundStyle(T.text2) }
                    }
                    .font(.footnote)
                }
                .foregroundStyle(T.text).padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading).background(T.bg, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 8)
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEXT").font(.caption.bold()).foregroundStyle(T.text2)
                        if let n = next {
                            Text(n.title).font(.callout.weight(.semibold)).lineLimit(2)
                            Text(dateText(n.start, "EEE") + " " + timeText(n.start, short: true)).font(.footnote).foregroundStyle(T.text2)
                        }
                        Spacer()
                        Text("+ Add").font(.footnote.weight(.semibold)).foregroundStyle(T.tint).frame(maxWidth: .infinity, minHeight: 32).background(T.bg2, in: Capsule())
                    }
                    .foregroundStyle(T.text).padding(14).frame(width: 158, height: 158).background(T.bg, in: RoundedRectangle(cornerRadius: 22))
                    LazyVGrid(columns: [GridItem(.fixed(60), spacing: 18), GridItem(.fixed(60))], spacing: 22) {
                        ForEach([("Phone", Color.green), ("Mail", Color.blue), ("Notes", Color.orange), ("Photos", Color.indigo)], id: \.0) { name, c in
                            VStack(spacing: 4) { RoundedRectangle(cornerRadius: 14).fill(c).frame(width: 60, height: 60); Text(name).font(.caption2).foregroundStyle(.white) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                (Text("Home Screen: ").bold() + Text("today's list (wide) and the next event with Add (small).\n") + Text("Top: ").bold() + Text("leave-now alert with drive time. ") + Text("Also: ").bold() + Text("a Lock Screen widget, a Control Center button and \"Hey Siri, add to Dateline\"."))
                    .font(.footnote).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 8).padding(.top, 20)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}
