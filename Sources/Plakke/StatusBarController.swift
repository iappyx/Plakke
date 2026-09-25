import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {
    private let store: ClipStore
    private let watcher: ClipboardWatcher
    private let item: NSStatusItem
    private let menu = NSMenu()
    /// The event tap couldn't be created even after retrying — otherwise the app looks perfectly
    /// healthy while the hotkey does nothing at all.
    private var tapFailed = false
    /// Resolved display names, so the menu doesn't hit LaunchServices and the filesystem dozens of
    /// times per open — `appName` was previously called twice per comparison inside a sort.
    private var appNameCache: [String: String] = [:]

    /// Carries a choice's key and the option clicked, so one action serves every exclusive list.
    private struct ChoiceSelection {
        let key: String
        let value: Int
    }

    init(store: ClipStore, watcher: ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        refreshIcon()
        menu.delegate = self
        // Without this, `isEnabled = false` is overwritten at display time for any row whose target
        // responds to the action — which is why "Clear History" stayed clickable with no recents and
        // silently did nothing.
        menu.autoenablesItems = false
        item.menu = menu

        NotificationCenter.default.addObserver(forName: HotkeyController.tapFailed,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.tapFailed = true
        }
        // Cleared when the tap comes back — otherwise the menu kept telling the user to relaunch a
        // perfectly working app for the rest of the process.
        NotificationCenter.default.addObserver(forName: HotkeyController.tapRecovered,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.tapFailed = false
        }
    }

    /// Dimmed while recording is paused, so a forgotten pause is visible rather than silent.
    private func refreshIcon() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                               accessibilityDescription: watcher.isPaused ? "Plakke (paused)" : "Plakke")
        button.image?.isTemplate = true
        button.appearsDisabled = watcher.isPaused
    }

    // MARK: - Menu
    //
    // One rule: actions at the top level, preferences in a single Settings submenu. Before this the
    // split was arbitrary — "Larger Cards" sat beside Quit while a Privacy submenu held two toggles —
    // and the settings were buried under as many as twenty clip rows.

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addHint(to: menu)
        addClips(to: menu)
        addActions(to: menu)
        addHealth(to: menu)
        addAbout(to: menu)
    }

    /// The one builder every row goes through.
    @discardableResult
    private func add(_ title: String, _ action: Selector?, to m: NSMenu,
                     state: NSControl.StateValue = .off, help: String? = nil,
                     represented: Any? = nil, symbol: String? = nil,
                     enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if action != nil { mi.target = self }
        mi.state = state
        mi.toolTip = help
        mi.representedObject = represented
        mi.isEnabled = enabled && action != nil
        if let symbol {
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        m.addItem(mi)
        return mi
    }

    private func addHint(to m: NSMenu) {
        let hk = Hotkey.current
        add("Hold \(hk.modifierSymbols), tap \(hk.keyName), release to plakke", nil, to: m, enabled: false)
        m.addItem(.separator())
    }

    private func addClips(to m: NSMenu) {
        if store.items.isEmpty {
            add("No clips yet", nil, to: m, enabled: false)
            return
        }
        let recents = store.recents
        for clip in recents { addItems(for: clip, to: m) }
        let pinned = store.pinned
        guard !pinned.isEmpty else { return }
        // Only separate the two sections when there is something above to separate from, or the menu
        // opens with two rules in a row and a "Pinned" heading for the whole list.
        if !recents.isEmpty {
            m.addItem(.separator())
            add("Pinned", nil, to: m, enabled: false)
        }
        for clip in pinned { addItems(for: clip, to: m) }
    }

    private func addActions(to m: NSMenu) {
        m.addItem(.separator())
        // Pausing is something you do, not something you set — and it deliberately doesn't persist.
        add("Pause Recording", #selector(togglePause), to: m,
            state: watcher.isPaused ? .on : .off,
            help: "Stop recording copies until you turn this off. Resets when Plakke restarts.")
        add("Clear History", #selector(clear), to: m,
            help: "Removes the recent clips. Pinned clips are kept.",
            enabled: !store.recents.isEmpty)
        add("Change Hotkey…  (\(Hotkey.current.label))", #selector(changeHotkey), to: m)

        let settings = add("Settings", nil, to: m)
        settings.isEnabled = true
        settings.submenu = buildSettingsMenu()
    }

    private func addHealth(to m: NSMenu) {
        if !Permissions.isTrusted {
            m.addItem(.separator())
            add("Grant Accessibility Access…", #selector(openAccessibility), to: m,
                symbol: "exclamationmark.triangle.fill")
        } else if tapFailed {
            m.addItem(.separator())
            add("The hotkey isn't working — relaunch Plakke", nil, to: m,
                symbol: "exclamationmark.triangle.fill", enabled: false)
        }
        if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            if Permissions.isTrusted && !tapFailed { m.addItem(.separator()) }
            add("Move Plakke to /Applications so login launch survives rebuilds", nil, to: m,
                enabled: false)
        }
    }

    private func addAbout(to m: NSMenu) {
        m.addItem(.separator())
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Plakke"
        add("About \(appName)", #selector(showAbout), to: m)
        m.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
    }

    /// Built by walking `Settings.preferences`, so adding a setting is one line in Settings.swift.
    private func buildSettingsMenu() -> NSMenu {
        let m = NSMenu()
        for preference in Settings.preferences {
            switch preference {
            case let .toggle(setting):
                add(setting.label, #selector(toggleSetting(_:)), to: m,
                    state: setting.value ? .on : .off, help: setting.help, represented: setting.key)

            case let .choice(choice):
                // The active option in the title, so you don't have to open the submenu to see it.
                let parent = add("\(choice.label)  (\(choice.activeTitle))", nil, to: m, help: choice.help)
                parent.isEnabled = true
                parent.submenu = buildChoiceMenu(choice)

            case let .appList(setting):
                let count = Settings.ignoredAppSet.count
                let suffix = count == 0 ? "" : "  (\(count) app\(count == 1 ? "" : "s"))"
                let parent = add(setting.label + suffix, nil, to: m, help: setting.help)
                parent.isEnabled = true
                parent.submenu = buildIgnoreMenu()

            case .launchAtLogin:
                add("Launch at Login", #selector(toggleLogin), to: m,
                    state: SMAppService.mainApp.status == .enabled ? .on : .off)
            }
        }
        m.addItem(.separator())
        add("Reset to Defaults…", #selector(resetSettings), to: m,
            help: "Puts every setting back the way it shipped. Your clips are not touched.")
        return m
    }

    private func buildChoiceMenu(_ choice: Choice<Int>) -> NSMenu {
        let m = NSMenu()
        let current = choice.value
        for option in choice.options {
            add(option.title, #selector(setChoice(_:)), to: m,
                state: option.value == current ? .on : .off,
                represented: ChoiceSelection(key: choice.key, value: option.value))
        }
        return m
    }

    /// Lists the apps in the current history plus anything already ignored, so there's nothing to
    /// type and no guessing about which app is "frontmost" while a menu is open.
    private func buildIgnoreMenu() -> NSMenu {
        let m = NSMenu()
        var seen: [String] = []
        func note(_ id: String) {
            guard !seen.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
            seen.append(id)
        }
        store.items.compactMap(\.sourceBundleID).forEach(note)
        Settings.ignoredAppSet.forEach(note)

        guard !seen.isEmpty else {
            add("No apps yet", nil, to: m, enabled: false)
            return m
        }
        let sorted = seen.sorted {
            appName(for: $0).localizedCaseInsensitiveCompare(appName(for: $1)) == .orderedAscending
        }
        for id in sorted {
            add(appName(for: id), #selector(toggleIgnoredApp(_:)), to: m,
                state: Settings.isIgnoredApp(id) ? .on : .off, represented: id)
        }
        return m
    }

    private func appName(for bundleID: String) -> String {
        if let cached = appNameCache[bundleID] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
        } else {
            name = bundleID
        }
        appNameCache[bundleID] = name
        return name
    }

    private func addItems(for clip: ClipItem, to m: NSMenu) {
        // `safeTitle` redacts secrets. The plain `title` is cleartext, and the ⌥-alternate item
        // below used it verbatim — which put the first 48 characters of a password on screen.
        let label = clip.safeTitle
        add(label, #selector(copyClip(_:)), to: m, represented: clip.id,
            symbol: clip.isSecret ? "lock.fill" : (clip.pinned ? "pin.fill" : clip.kind.symbol))

        // ⌥-click a clip to pin/unpin it — but secrets can't be pinned, so don't offer it for them.
        guard !clip.isSecret else { return }
        let alt = add((clip.pinned ? "Unpin " : "Pin ") + label, #selector(togglePin(_:)), to: m,
                      represented: clip.id)
        alt.isAlternate = true
        alt.keyEquivalentModifierMask = .option
    }

    // MARK: - Actions

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        // The store and the switcher observe `Settings.changed` and react for themselves, so there's
        // nothing to call here.
        Settings.toggleBool(key: key)
    }

    @objc private func setChoice(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ChoiceSelection else { return }
        for case let .choice(choice) in Settings.preferences where choice.key == selection.key {
            choice.value = selection.value
        }
    }

    @objc private func toggleIgnoredApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.toggleIgnoredApp(id)
        // Adding an app to the list should also clear what it already put here (pins excepted).
        if Settings.isIgnoredApp(id) { store.purge(sourceBundleID: id) }
    }

    @objc private func resetSettings() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Reset all settings?"
        alert.informativeText = "The hotkey, the privacy options and the card size go back to their "
            + "defaults. Launch at Login and your clips are left alone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard confirm(alert) else { return }
        Settings.resetAll()
    }

    /// Runs a modal with the global hotkey silenced, then hands focus back.
    ///
    /// The event tap is installed in `.commonModes`, which includes modal mode — so ⌥V could open the
    /// switcher *over* our own alert, where ⏎ was read as "paste" instead of the default button and the
    /// synthesised ⌘V went into the alert itself. And `activate(ignoringOtherApps:)` with nothing to
    /// undo it left Plakke frontmost afterwards, stealing focus from whatever the user was typing in.
    private func confirm(_ alert: NSAlert) -> Bool {
        NotificationCenter.default.post(name: HotkeyRecorder.recording, object: true)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            NotificationCenter.default.post(name: HotkeyRecorder.recording, object: false)
            NSApp.hide(nil)
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { store.togglePin(id) }
    }

    @objc private func copyClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let clip = store.items.first(where: { $0.id == id }) else { return }
        // The same write path the switcher uses. This used to be a separate copy that had drifted:
        // it never re-flagged a secret as concealed, so clicking one published the password in the
        // clear to every other clipboard manager.
        Paster.place(clip, plain: false, transforms: [], store: store, watcher: watcher)
    }

    @objc private func clear() {
        // Clear History can't be undone once it's flushed, so it asks first.
        guard !store.recents.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear clipboard history?"
        let pinned = store.pinned.count
        alert.informativeText = pinned > 0
            ? "This removes \(store.recents.count) recent clip(s). Your \(pinned) pinned clip(s) are kept."
            : "This removes \(store.recents.count) recent clip(s). This can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if confirm(alert) { store.clear() }
    }

    @objc private func togglePause() {
        watcher.isPaused.toggle()
        refreshIcon()
    }

    @objc private func showAbout() { AboutController.show() }

    @objc private func changeHotkey() { HotkeyRecorder.show() }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        // `requiresApproval` means the user switched Plakke off in System Settings → Login Items.
        // Registering again from here does nothing, and the checkmark never moved — a dead switch with
        // no explanation.
        if svc.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Plakke is switched off in Login Items"
            alert.informativeText = "macOS is holding this setting. Turn Plakke back on in "
                + "System Settings → General → Login Items."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Cancel")
            if confirm(alert), let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Plakke: launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nAn ad-hoc signed build outside "
                + "/Applications often can't register itself."
            alert.addButton(withTitle: "OK")
            _ = confirm(alert)
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
