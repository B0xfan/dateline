// Full screen on the desktop the window is already on (John 2026-11-07). Apple's full screen moves the window to a desktop of
// its own, and from there Mission Control (Control-Up) opens on Desktop 1. This fills the screen and hides the menu bar and Dock instead, as cmux does.
import AppKit

@MainActor final class FullScreen: NSObject, ObservableObject {
    static let shared = FullScreen()
    @Published private(set) var on = false
    private var saved = NSRect.zero  // the window's size and place before full screen
    private var filled = NSRect.zero  // the size full screen gave it; any other size means the person moved or tiled it
    private var moving = false
    private var leavingApple = false
    private weak var window: NSWindow?
    private var watches: [NSObjectProtocol] = []

    // Each time the main window appears: Apple's full screen off for it, the green button and Control-Command-F come here.
    func adopt(_ w: NSWindow) {
        if w.styleMask.contains(.fullScreen) {  // macOS reopened it in Apple's full screen: leave that, then fill the screen this way
            guard !leavingApple else { return }
            leavingApple = true
            // shortcut: a failed exit only reaches the window's delegate (SwiftUI's), so this waits until a later exit; rare, upgrade if it is ever seen
            var t: NSObjectProtocol?
            t = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { [weak self] _ in
                if let t { NotificationCenter.default.removeObserver(t) }
                MainActor.assumeIsolated { self?.leavingApple = false; self?.adopt(w); self?.toggle(w) }
            }
            w.toggleFullScreen(nil)
            return
        }
        window = w
        w.collectionBehavior.remove(.fullScreenPrimary)
        w.collectionBehavior.insert(.fullScreenNone)
        if let b = w.standardWindowButton(.zoomButton) { b.target = self; b.action = #selector(greenButton(_:)) }
        watches.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        watches = [
            // Closing or quitting while full: the normal size goes back first, so macOS saves that one and not the screen size.
            nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak w] _ in MainActor.assumeIsolated { if let w { self?.leave(w, animate: false) } } },
            nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self, weak w] _ in MainActor.assumeIsolated { if let w { self?.leave(w, animate: false) } } },
            // Tiled, resized or dragged: that ends full screen.
        ] + [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            nc.addObserver(forName: name, object: w, queue: .main) { [weak self, weak w] _ in
                MainActor.assumeIsolated { if let self, let w, self.on, !self.moving, w.frame != self.filled { self.on = false; NSApp.presentationOptions = [] } }
            }
        }
    }

    @objc private func greenButton(_ sender: NSButton) { if let w = sender.window { toggle(w) } }

    func toggle(_ w: NSWindow? = nil) {
        guard let w = w ?? window else { return }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil); return }  // macOS put it back in Apple's full screen after adopt: just leave it
        if on { leave(w, animate: true); return }
        guard let screen = w.screen ?? NSScreen.main else { return }
        saved = w.frame
        on = true
        moving = true  // before the menu bar hides: that alone already moves the window
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]  // only while Dateline is the front app
        w.setFrame(screen.frame, display: true, animate: true); moving = false
        filled = w.frame
    }

    private func leave(_ w: NSWindow, animate: Bool) {
        guard on else { return }
        on = false
        moving = true
        NSApp.presentationOptions = []
        w.setFrame(saved, display: true, animate: animate); moving = false
    }
}
