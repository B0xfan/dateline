// The four tabs, the round add button on the calendar, and the sheets.
import SwiftUI
import UIKit
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
        .overlay(alignment: .bottom) { if let t = app.toast { UndoBanner(toast: t).padding(.horizontal, 16).padding(.bottom, 92).transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .animation(.easeOut(duration: 0.2), value: app.toast?.id)
        .background(ShakeToUndo { app.undoLast() })
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
                        Image(systemName: t.icon).font(.system(size: 19)).frame(height: 24)  // same box for every icon so the labels line up
                        Text(t.rawValue).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 6)  // room between the label and the highlight's edge
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

/// The short banner after a change: what happened, and Undo.
struct UndoBanner: View {
    @EnvironmentObject var app: PhoneState
    let toast: Toast
    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline).lineLimit(2).foregroundStyle(T.text)
            Spacer(minLength: 0)
            Button("Undo") { app.undoLast() }.font(.body.weight(.semibold)).foregroundStyle(T.tint).frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 2).glass()
        .accessibilityElement(children: .contain)
    }
}

/// Shake the phone to undo the last change, the way iPhone apps do. Lives in the background, so it only listens.
struct ShakeToUndo: UIViewControllerRepresentable {
    let action: () -> Void
    final class Catcher: UIViewController {
        var action: () -> Void = {}
        override var canBecomeFirstResponder: Bool { true }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) { if motion == .motionShake { action() } else { super.motionEnded(motion, with: event) } }
    }
    func makeUIViewController(context: Context) -> Catcher { let c = Catcher(); c.action = action; return c }
    func updateUIViewController(_ c: Catcher, context: Context) { c.action = action }
}
