import AppKit

/// A tiny window: press the combination you want, and it's saved.
final class HotkeyRecorder: NSObject, NSWindowDelegate {
    static let recording = Notification.Name("PlakkeHotkeyRecording")
    private static var shared: HotkeyRecorder?

    private var window: NSWindow!
    private var comboLabel: NSTextField!
    private var noteLabel: NSTextField!
    private var monitor: Any?

    static func show() {
        if shared == nil { shared = HotkeyRecorder() }
        shared?.open()
    }

    private func open() {
        if window == nil { build() }
        NotificationCenter.default.post(name: Self.recording, object: true)   // pause the global tap
        comboLabel.stringValue = Hotkey.current.label
        noteLabel.stringValue = "Hold ⌃ and/or ⌥, then press a key."
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Reopening used to stack monitors: the orphaned one lived for the whole process and kept
        // consuming every keystroke in the app.
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            self?.handle(e) == true ? nil : e
        }
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Hotkey"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "Press the new switcher hotkey")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center

        comboLabel = NSTextField(labelWithString: "")
        comboLabel.font = .monospacedSystemFont(ofSize: 26, weight: .medium)
        comboLabel.alignment = .center

        noteLabel = NSTextField(labelWithString: "")
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.alignment = .center

        let reset = NSButton(title: "Reset to ⌥ V", target: self, action: #selector(reset))
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [reset, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, comboLabel, noteLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
    }

    /// Returns true when the event was consumed.
    private func handle(_ e: NSEvent) -> Bool {
        var mods: CGEventFlags = []
        if e.modifierFlags.contains(.control) { mods.insert(.maskControl) }
        if e.modifierFlags.contains(.option)  { mods.insert(.maskAlternate) }
        let disallowed = e.modifierFlags.intersection([.command, .shift])

        if e.type == .flagsChanged {
            let held = (e.modifierFlags.contains(.control) ? "⌃" : "") + (e.modifierFlags.contains(.option) ? "⌥" : "")
            comboLabel.stringValue = held.isEmpty ? Hotkey.current.label : held + " …"
            return true
        }

        let key = Int64(e.keyCode)
        if key == Key.escape && mods.isEmpty { cancel(); return true }
        // Let the app's own commands through — consuming every ⌘ keystroke meant the recorder
        // window could not be closed (⌘W) and Plakke could not be quit (⌘Q).
        if e.modifierFlags.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased(),
           ch == "q" || ch == "w" {
            return false
        }
        guard disallowed.isEmpty else {
            noteLabel.stringValue = "⌘ and ⇧ can't be part of the hotkey — use ⌃ and/or ⌥."
            return true
        }
        guard !mods.isEmpty else {
            noteLabel.stringValue = "Hold ⌃ and/or ⌥ while pressing the key."
            return true
        }
        guard !Hotkey.reservedKeys.contains(key) else {
            noteLabel.stringValue = "That key is used inside the switcher. Pick another."
            return true
        }
        Hotkey.current = Hotkey(modifiers: mods, key: key)
        close()
        return true
    }

    @objc private func reset() { Hotkey.current = .default; close() }
    @objc private func cancel() { close() }

    private func close() {
        window.orderOut(nil)
        windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        NotificationCenter.default.post(name: Self.recording, object: false)   // resume the global tap
    }

    /// Clicking back into another app cancels. We're an accessory app, so this window can otherwise
    /// sit unnoticed behind everything else — and while it's open the global tap stays paused,
    /// leaving the hotkey dead with nothing on screen to explain why.
    func windowDidResignKey(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        cancel()
    }
}
