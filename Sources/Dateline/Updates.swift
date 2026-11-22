// Phase 8: self-update through Sparkle 2, the same way Audrey Mail does it. The update list and the downloads live on
// GitHub Releases (scripts/release.sh publishes them); every download is checked against SUPublicEDKey in Info.plist before it installs.
import SwiftUI
import Combine
import CoreGraphics
import Sparkle
import DatelineCore

final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private var bag = Set<AnyCancellable>()
    @Published var canCheck = false
    @Published var lastChecked: Date?
    /// nil = no answer yet in this session, false = the last check found nothing newer, true = a newer version was found.
    @Published var newerFound: Bool?

    /// Starts the updater once, only in the real app bundle: --sample, --render and the bare built program never reach the network.
    func start() {
        guard controller == nil, Bundle.main.bundleIdentifier != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &bag)
        lastChecked = c.updater.lastUpdateCheckDate
        // Just updated: look again now, so a version that came out after the one just installed follows in the same go.
        let last = UserDefaults.standard.string(forKey: "lastLaunchedVersion")
        UserDefaults.standard.set(Self.version, forKey: "lastLaunchedVersion")
        if justUpdated(last: last, now: Self.version), c.updater.automaticallyChecksForUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if c.updater.canCheckForUpdates { c.updater.checkForUpdatesInBackground() } }
        }
    }

    func check() { controller?.checkForUpdates(nil) }

    /// "Check for updates every day".
    var daily: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    /// "Install them without asking": download in the background, install when Dateline quits or the Mac has been left alone a while.
    var silent: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    /// Sparkle installs a background download only when Dateline quits, and until then every check (even Check for Updates) offers that
    /// saved copy instead of reading the feed again. Dateline stays open for days, so the copy went stale and each newer version needed
    /// its own round (John 2026-11-21: three updates in a row). So the saved copy installs once the Mac has been left alone for a while.
    private var awayTimer: Timer?
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        awayTimer?.invalidate()  // Sparkle calls this on the main thread
        awayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            if macIsAway(idle: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)) {
                immediateInstallHandler()  // Sparkle 2.3+: safe to call again if a quit was cancelled
            }
        }
        return true
    }

    /// Sparkle's boxes ("You're up to date" and the rest) open as modal alerts. One opened on another desktop and its OK did nothing
    /// (John 2026-11-21). So Dateline comes to the front, and the box shows on the desktop in use, above a full-screen window.
    func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { NSApp.activate() }  // Sparkle calls this on the main thread
        DispatchQueue.main.async {  // runs inside the alert's modal loop, once its window exists
            MainActor.assumeIsolated {
                guard let w = NSApp.modalWindow else { return }
                w.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { DispatchQueue.main.async { self.newerFound = true; self.lastChecked = updater.lastUpdateCheckDate } }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { DispatchQueue.main.async { self.newerFound = nil; self.lastChecked = updater.lastUpdateCheckDate } }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { DispatchQueue.main.async { self.newerFound = false; self.lastChecked = updater.lastUpdateCheckDate } }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }
}

/// "Check for Updates…" in the Dateline menu.
struct CheckForUpdatesItem: View {
    @ObservedObject private var up = Updater.shared
    var body: some View { Button("Check for Updates…") { up.check() }.disabled(!up.canCheck) }
}

/// Settings, Updates tab (mockup section 5).
struct UpdateSettings: View {
    @ObservedObject private var up = Updater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Check for updates every day", isOn: Binding(get: { up.daily }, set: { up.daily = $0 })).toggleStyle(.switch).controlSize(.small)
            Toggle("Install them without asking", isOn: Binding(get: { up.silent }, set: { up.silent = $0 })).toggleStyle(.switch).controlSize(.small).disabled(!up.daily)
            HStack {
                Text(updateStatus(version: Updater.version, last: up.lastChecked, newer: up.newerFound, now: Date())).foregroundStyle(Palette.text3)
                Spacer()
                Button("Check now") { up.check() }.disabled(!up.canCheck)
            }
            Text("Dateline looks on GitHub for a new version. Your calendars and settings stay as they are when it updates.")
                .font(.system(size: 12)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 620)
    }
}

/// Ten minutes with no key, mouse or trackpad use: a restart for an update will not get in the way.
func macIsAway(idle: TimeInterval) -> Bool { idle >= 600 }
/// This launch is the first one on a new version (not the very first launch).
func justUpdated(last: String?, now: String) -> Bool { last != nil && last != now }

/// The status line under the switches. Pure, so the self-test can check it.
func updateStatus(version: String, last: Date?, newer: Bool?, now: Date) -> String {
    guard let last else { return "Dateline \(version) · not checked yet" }
    let t = timeText(last)
    let when = cal.isDate(last, inSameDayAs: now) ? "today, \(t)" : dateText(last, "MMM d") + ", " + t
    switch newer {
    case true?: return "Last checked \(when) · a new version is ready"
    case false?: return "Last checked \(when) · you're up to date"
    case nil: return "Dateline \(version) · last checked \(when)"
    }
}
