// The four tabs, the add bar on the day and week views, and the sheets.
import SwiftUI
import DatelineCore

struct RootView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        if app.demoWidgets { WidgetsPreview() } else { main }
    }

    private var main: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch app.tab {
                case .calendar: CalendarTab()
                case .tasks: TasksView()
                case .places: PlacesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                if app.tab == .calendar && app.path.isEmpty && (app.mode == .day || app.mode == .week) { AddBar() }
                TabBar()
            }
        }
        .background(T.bg)
        .preferredColorScheme(Look.appearance == "Light" ? .light : Look.appearance == "Dark" ? .dark : nil)  // app.look changing redraws this
        .onReceive(NotificationCenter.default.publisher(for: Look.synced)) { _ in app.lookChanged() }  // a Look choice arrived from the Mac
        .sheet(isPresented: Binding(get: { app.adding != nil }, set: { if !$0 { app.adding = nil } }), onDismiss: { app.sheetClosed() }) { AddSheet(start: app.adding ?? "") }
        .sheet(item: $app.email, onDismiss: { app.sheetClosed() }) { EmailSheet(find: $0) }
        .sheet(isPresented: $app.showUnlock) { UnlockView() }
        .alert(app.problem ?? "", isPresented: Binding(get: { app.problem != nil }, set: { if !$0 { app.problem = nil } })) { Button("OK") {} }
        .onReceive(clock) { now in
            guard !app.sample else { return }  // the pictures keep the mockup's 9:41
            app.today = now
            License.shared.tick(now)
        }
        .task { if !app.sample { Here.shared.start() } }  // sunrise and weather for where the phone is; never in a test
    }
}

struct AddBar: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        Button { app.adding = "" } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").fontWeight(.bold).foregroundStyle(T.tint)
                Text("Add: Dinner with Ana Friday 7pm").foregroundStyle(T.text2)
                Spacer()
            }
            .font(.subheadline).padding(.horizontal, 16).frame(height: 44).glass()
        }
        .buttonStyle(.plain).padding(.horizontal, 16)
        .accessibilityLabel("Add an event")
    }
}

struct TabBar: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        HStack(spacing: 4) {
            ForEach(PhoneState.Tab.allCases, id: \.self) { t in
                let on = app.tab == t
                Button { app.tab = t } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.system(size: 19))
                        Text(t.rawValue).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(on ? T.tint : T.text)
                    .background(on ? T.tint.opacity(0.14) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4).glass().padding(.horizontal, 16)
    }
}
