// Entry. No argument (or only arguments macOS adds) = the app on the Mac's real calendars.
//   --sample            the app on made-up calendars, without asking for calendar access
//   --selftest          pure logic checks, no calendar access
//   --accounts-check <address>   the iCloud account code against scripts/caldav-standin.py (no settings, no passwords saved)
//   --render <folder>   draws the window on sample calendars to PNG files off-screen (no window, no calendar access)
import SwiftUI
import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest()) }
if let i = args.firstIndex(of: "--accounts-check"), i + 1 < args.count {
    Task { @MainActor in exit(await accountsCheck(server: args[i + 1])) }
    dispatchMain()
}
if args.contains("--sample") { MainActor.assumeIsolated { WeatherStore.sample = true } }  // made-up weather, no network
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    exit(MainActor.assumeIsolated { renderAll(to: args[i + 1]) } ? 0 : 1)
}

final class Delegate: NSObject, NSApplicationDelegate {
    // Before launch ends, so a click on a leave alert that started the app is still handled.
    // Only inside the app bundle: the bare built program has no bundle and alerts would stop it.
    func applicationWillFinishLaunching(_ n: Notification) { if Bundle.main.bundleIdentifier != nil { LeaveAlerts.shared.install() } }
    // Keeps running with the window closed, so quick add from any app still works; the Dock icon brings the window back.
    // Phase 8: the daily update check, only for the real app (never --sample).
    func applicationDidFinishLaunching(_ n: Notification) { if !CommandLine.arguments.contains("--sample") { Updater.shared.start() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct DatelineApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @StateObject private var app = AppState(store: Store(sample: CommandLine.arguments.contains("--sample")))
    var body: some Scene {
        Window("Dateline", id: "main") {
            MainView(app: app, store: app.store)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { Look.apply(); app.startKeys() }
        }
        .defaultSize(width: 1380, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Subscribe to Calendar…") { app.openMain?(); app.subscribing = true } }
            CommandGroup(after: .appInfo) { CheckForUpdatesItem() }
        }
        Settings { SettingsView(app: app) }
    }
}

DatelineApp.main()
