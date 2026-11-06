// The four tabs and the sheets.
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import DatelineCore

struct RootView: View {
    @EnvironmentObject var app: PhoneState
    @EnvironmentObject var store: Store
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        if app.demoWidgets { WidgetsPreview() } else { main }
    }

    private var main: some View {
        // The standard iPhone tab bar (2026-11-06 design); adding moved to the + in the calendar's top bar.
        TabView(selection: $app.tab) {
            CalendarTab().tabItem { Label("Calendar", systemImage: "calendar") }.tag(PhoneState.Tab.calendar)
            TasksView().tabItem { Label("Tasks", systemImage: "checkmark.circle") }.tag(PhoneState.Tab.tasks)
            PlacesView().tabItem { Label("Places", systemImage: "mappin") }.tag(PhoneState.Tab.places)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(PhoneState.Tab.settings)
        }
        .overlay(alignment: .bottom) { if let t = app.toast { UndoBanner(toast: t).padding(.horizontal, 16).padding(.bottom, 92).transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .animation(.easeOut(duration: 0.2), value: app.toast?.id)
        .background(ShakeToUndo { app.undoLast() })
        .background(T.bg)
        .preferredColorScheme(Look.appearance == "Light" ? .light : Look.appearance == "Dark" ? .dark : nil)  // app.look changing redraws this
        .onReceive(NotificationCenter.default.publisher(for: Look.synced)) { _ in app.lookChanged() }  // a Look choice arrived from the Mac
        .sheet(isPresented: Binding(get: { app.adding != nil }, set: { if !$0 { app.adding = nil } }), onDismiss: { app.sheetClosed() }) { AddSheet(start: app.adding ?? "") }
        .sheet(isPresented: $app.searching) { SearchSheet() }
        .sheet(item: $app.email, onDismiss: { app.sheetClosed() }) { EmailSheet(find: $0) }
        .sheet(isPresented: $app.showUnlock) { UnlockView() }
        .fileImporter(isPresented: $app.pickingEmail, allowedContentTypes: [.emailMessage]) { r in
            if case .success(let url) = r { Task { await app.readEmail(url) } }
        }
        .onOpenURL { url in if url.isFileURL { app.tab = .calendar; Task { await app.readEmail(url) } } }  // an .eml shared or opened in Dateline
        .alert(app.problem ?? "", isPresented: Binding(get: { app.problem != nil }, set: { if !$0 { app.problem = nil } })) { Button("OK") {} }
        .onReceive(clock) { now in
            guard !app.sample else { return }  // the pictures keep the mockup's 9:41
            app.today = now
            License.shared.tick(now)
        }
        .task { if !app.sample { Here.shared.start() } }  // sunrise and weather for where the phone is; never in a test
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
