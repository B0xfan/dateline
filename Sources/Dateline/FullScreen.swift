// Full screen on the desktop the window is already on (John 2026-11-07). Apple's full screen moves the window to a desktop of
// its own, and from there Mission Control (Control-Up) opens on Desktop 1. This fills the screen and hides the menu bar and Dock instead, as cmux does.
import AppKit

@MainActor final class FullScreen: NSObject, ObservableObject {
    static let shared = FullScreen()
    @Published private(set) var on = false
    private var saved = NSRect.zero  // the window's size and place before full screen
    private weak var window: NSWindow?
    private var closeWatch: NSObjectProtocol?

    // Each time the main window appears: Apple's full screen off for it, the green button and Control-Command-F come here.
    func adopt(_ w: NSWindow) {
        if w.styleMask.contains(.fullScreen) {  // macOS reopened it in Apple's full screen: leave that, then fill the screen this way
            var t: NSObjectProtocol?
            t = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { [weak self] _ in
                if let t { NotificationCenter.default.removeObserver(t) }
                MainActor.assumeIsolated { self?.adopt(w); self?.toggle(w) }
            }
            w.toggleFullScreen(nil)
            return
        }
        window = w
        w.collectionBehavior.remove(.fullScreenPrimary)
        w.collectionBehavior.insert(.fullScreenNone)
        if let b = w.standardWindowButton(.zoomButton) { b.target = self; b.action = #selector(greenButton(_:)) }
        if let closeWatch { NotificationCenter.default.removeObserver(closeWatch) }
        closeWatch = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.on == true { self?.on = false; NSApp.presentationOptions = [] } }
        }
    }

    @objc private func greenButton(_ sender: NSButton) { if let w = sender.window { toggle(w) } }

    func toggle(_ w: NSWindow? = nil) {
        guard let w = w ?? window else { return }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil); return }  // still in Apple's full screen: just leave it
        if on {
            on = false
            NSApp.presentationOptions = []
            w.setFrame(saved, display: true, animate: true)
        } else if let screen = w.screen ?? NSScreen.main {
            saved = w.frame
            on = true
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]  // only while Dateline is the front app
            w.setFrame(screen.frame, display: true, animate: true)
        }
    }
}
