// Phase 8: self-update through Sparkle 2, the same way Audrey Mail does it. The update list and the downloads live on
// GitHub Releases (scripts/release.sh publishes them); every download is checked against SUPublicEDKey in Info.plist before it installs.
import SwiftUI
import Combine
import Sparkle

final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
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
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &bag)
        lastChecked = c.updater.lastUpdateCheckDate
    }

    func check() { controller?.checkForUpdates(nil) }

    /// "Check for updates every day".
    var daily: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    /// "Install them without asking": download in the background and install when Dateline quits.
    var silent: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
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
                .font(.system(size: 11.5)).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 620)
    }
}

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
