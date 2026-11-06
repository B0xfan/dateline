// The Places tab (approved mockup "Places map"): this week's events with a place, on the map and as a list.
import SwiftUI
import MapKit
import DatelineCore

struct PlacesView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store

    var body: some View {
        let from = cal.startOfDay(for: app.today)
        let list = store.between(from, addDays(from, 7)).filter { $0.geo != nil && !store.hidden.contains($0.calendarID) }
        ZStack(alignment: .top) {
            Map(initialPosition: .automatic) {
                ForEach(list) { it in
                    Annotation("", coordinate: it.geo!.coord, anchor: .bottom) {
                        VStack(spacing: 3) {
                            Text(it.place.isEmpty ? it.title : it.place).font(.caption.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(T.bg, in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            Circle().fill(store.color(it)).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .frame(height: 440)
            .frame(maxHeight: .infinity, alignment: .top)
            Text("This week's places").font(.subheadline).foregroundStyle(T.text2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 44).glass()
                .padding(.horizontal, 16).padding(.top, 8)
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(T.line).frame(width: 36, height: 5).frame(maxWidth: .infinity).padding(.top, 6)
                Text("This week").font(.title3.bold()).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
                ScrollView {
                    if list.isEmpty {
                        Text("No events with a place this week.").font(.subheadline).foregroundStyle(T.text2).padding(.horizontal, 16)
                    } else {
                        Card {
                            ForEach(list) { it in
                                Button { app.tab = .calendar; app.open(it) } label: {
                                    Row(last: it.id == list.last?.id) {
                                        Dot(color: store.color(it), size: 12)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(it.place.isEmpty || it.title.contains(it.place) ? it.shownTitle : "\(it.shownTitle) · \(it.place)").lineLimit(1)
                                            Text(([dateText(it.start, "EEE") + " " + timeText(it.start, short: true)] + (app.drive[it.id].map { ["\($0) min drive"] } ?? [])).joined(separator: " · "))
                                                .font(.footnote).foregroundStyle(T.text2)
                                        }
                                        .padding(.vertical, 6)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .background(T.grouped, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            .shadow(color: .black.opacity(0.08), radius: 6, y: -2)
            .padding(.top, 410)
        }
        .background(T.bg)
    }
}
