import SwiftUI
import AppKit

// Global environment access for fallbacks
final class AppEnv {
    static var prefs: AppPrefs?
    static var store: ChatStore?
}

// Persistent fallback controller to avoid multiple windows
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private override init(window: NSWindow?) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                           styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isMovableByWindowBackground = false
        super.init(window: win)
        self.shouldCascadeWindows = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(prefs: AppPrefs, store: ChatStore) {
        window?.contentView = NSHostingView(
            rootView: SettingsView()
                .environmentObject(prefs)
                .environmentObject(store)
        )
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.styleMask.insert(.fullSizeContentView)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Utilities for app-level actions
func openSettingsWindow() {
    // Always ensure the fallback window is shown with the live preferences instance
    let prefs = AppEnv.prefs ?? AppPrefs()
    let store = AppEnv.store ?? ChatStore()
    SettingsWindowController.shared.show(prefs: prefs, store: store)
    // Also attempt to trigger native settings windows (harmless if they do nothing)
    _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
}
