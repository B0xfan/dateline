// The four tabs, the round add button on the calendar, and the sheets.
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
            HStack(spacing: 10) {
                TabBar()
                if app.tab == .calendar && app.path.isEmpty { AddButton() }
            }
            .padding(.horizontal, 16)
        }
        .background(T.bg)
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

/// The round + beside the tabs: opens the add box.
struct AddButton: View {
    @EnvironmentObject var app: PhoneState
    var body: some View {
        Button { app.adding = "" } label: {
            Image(systemName: "plus").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 62, height: 62).background(T.tint, in: Circle())
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add an event or task")
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
                        Text(t.rawValue).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.large)  // like Apple's tab bars: labels stay one line; large text shows on press-and-hold
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(on ? T.tint : T.text)
                    .background(on ? T.tint.opacity(0.14) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityShowsLargeContentViewer()
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4).glass()
    }
}
