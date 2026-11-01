// Entry. No argument (or only arguments macOS adds) = the app on the Mac's real calendars.
//   --sample            the app on made-up calendars, without asking for calendar access
//   --selftest          pure logic checks, no calendar access
//   --email-check <file.eml>  reads one email with Apple's on-device AI and prints the event it found
//   --assistant         started by Claude: passes its messages to the running app (Settings, Assistant)
//   --accounts-check <address>   the iCloud account code against scripts/caldav-standin.py (no settings, no passwords saved)
//   --a4-check <folder>  reads and edits every A4 task note in a COPY of the tasks folder (it changes the files it is given)
//   --a4-code <vault> <path> <day>  prints what is sent to A4's engine, for the sandbox test
//   --render <folder> [names]  draws the window on sample calendars to PNG files off-screen (no calendar access); names picks some of the main window pictures
import SwiftUI
import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest()) }
if let i = args.firstIndex(of: "--a4-code"), i + 3 < args.count { print(a4EngineCode(vault: args[i + 1], path: args[i + 2], day: args[i + 3].isEmpty ? nil : args[i + 3])); exit(0) }  // what the engine is sent, for the sandbox test
if let i = args.firstIndex(of: "--a4-check"), i + 1 < args.count { exit(a4Check(args[i + 1])) }
if args.contains("--assistant") { exit(assistantRelay()) }
if let i = args.firstIndex(of: "--email-check"), i + 1 < args.count {  // reads one email file with the on-device AI and prints the draft; saves nothing
    Task { @MainActor in
        let m = readMail((try? Data(contentsOf: URL(fileURLWithPath: args[i + 1]))) ?? Data()), d = await readEvent(m, now: Date())
        print(m.subject, "|", d.title, "|", d.start.map { dateText($0, "EEE MMM d h:mm a") } ?? "no date", "to", d.end.map { dateText($0, "EEE MMM d h:mm a") } ?? "-", "|", d.place, "|", d.notes, "| unsure:", d.unsure, d.whenNote, d.problem, "| quotes:", d.quotes)
        exit(0)
    }
    dispatchMain()
}
if let i = args.firstIndex(of: "--accounts-check"), i + 1 < args.count {
    Task { @MainActor in exit(await accountsCheck(server: args[i + 1])) }
    dispatchMain()
}
if args.contains("--sample") { MainActor.assumeIsolated { WeatherStore.sample = true } }  // made-up weather, no network
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    exit(MainActor.assumeIsolated { renderAll(to: args[i + 1], only: i + 2 < args.count ? Set(args[i + 2].split(separator: ",").map(String.init)) : []) } ? 0 : 1)
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
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands(app: app, store: app.store) }
        Settings { SettingsView(app: app) }
    }
}

DatelineApp.main()
