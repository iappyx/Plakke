import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ClipStore!
    private var watcher: ClipboardWatcher!
    private var switcher: SwitcherController!
    private var hotkeys: HotkeyController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        store    = ClipStore(capacity: 10)
        watcher  = ClipboardWatcher(store: store)
        switcher = SwitcherController(store: store, watcher: watcher)
        hotkeys  = HotkeyController(switcher: switcher)
        statusBar = StatusBarController(store: store, watcher: watcher)

        watcher.start()

        Permissions.ensureAccessibility { [weak self] in
            self?.hotkeys.start()
        }
    }

    /// History is written asynchronously and coalesced, so the last change can still be in flight.
    /// Without this, Clear History followed immediately by Quit left the cleared clips on disk and
    /// they reappeared on the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        store?.flush()
    }
}
