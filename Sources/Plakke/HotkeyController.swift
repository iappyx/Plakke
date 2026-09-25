import AppKit

/// Global event tap implementing the hold-modifier / tap-key / release-to-paste state machine.
final class HotkeyController {
    static let tapFailed = Notification.Name("PlakkeTapFailed")
    static let tapRecovered = Notification.Name("PlakkeTapRecovered")

    private let switcher: SwitcherController
    private var hotkey: Hotkey
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastRepeatStep = Date.distantPast
    /// True while the recorder window is capturing a new combo; the tap passes everything through.
    private var paused = false

    /// Synchronous mirror of "the switcher is up". The switcher's own work is dispatched so the tap
    /// callback stays fast (slow callbacks are how macOS decides to disable a tap), but routing
    /// decisions have to be made on the spot — so the flag lives here.
    private var active = false
    /// Keys whose keyDown we swallowed; their keyUp has to be swallowed too. Keys the target app
    /// already saw must still get their release, or editors and games are left with a stuck key.
    private var swallowedKeys: Set<Int64> = []
    /// The trigger key, while it is physically down. Its autorepeats keep being swallowed after the
    /// session ends, otherwise releasing ⌥ first types "vvvv" into the document.
    private var heldTriggerKey: Int64?
    /// When ⇧ was last observed held. Lifting ⇧ and ⌥ together can deliver the ⇧-up first, so the
    /// plain-paste intent has to survive a moment — but only a moment: latching it for the whole
    /// session meant that using ⇧V (the documented "previous clip" key) turned the eventual paste
    /// plain, stripping formatting and making an OCR image paste text instead of the image.
    private var lastShiftSeen = Date.distantPast
    private static let shiftGrace: TimeInterval = 0.3
    private var shiftIsRecent: Bool { Date().timeIntervalSince(lastShiftSeen) < Self.shiftGrace }
    private var lastActivity = Date.distantPast
    /// Crop mode latches the session: releasing ⌥ no longer pastes, because you're aiming a
    /// rectangle with the mouse and a slip of the other hand shouldn't fire a paste. ↩ pastes,
    /// esc cancels. Nothing else in the state machine may end the session while this is set.
    private var latched = false {
        didSet {
            guard latched != oldValue else { return }
            // The hint row has to know: while latched, ⌥ release does nothing and most keys are inert.
            let value = latched
            onMain { $0.setLatched(value) }
        }
    }
    private var watchdog: Timer?
    private var latchTimeout: Timer?
    private var retryTimer: Timer?
    private var retries = 0

    private(set) var isRunning = false

    init(switcher: SwitcherController) {
        self.switcher = switcher
        self.hotkey = Hotkey.current
        NotificationCenter.default.addObserver(forName: Hotkey.changed, object: nil, queue: .main) { [weak self] _ in
            self?.hotkey = Hotkey.current
        }
        NotificationCenter.default.addObserver(forName: HotkeyRecorder.recording, object: nil, queue: .main) { [weak self] n in
            self?.paused = (n.object as? Bool) ?? false
        }
        // The switcher can dismiss itself (⌫ emptying the strip); keep our mirror in step.
        switcher.onSelfDismiss = { [weak self] in self?.endSession(commit: false, dispatch: false) }
        // Dragging crop handles produces no key events, so without this the 30s idle timeout fired
        // mid-drag and threw the crop away.
        switcher.onCropActivity = { [weak self] in
            guard let self, self.latched else { return }
            self.armLatchTimeout()
        }
        // Crop mode can decline to open (the selection moved on between the tap's check and the
        // dispatched call). Latching anyway left a session that swallowed every key with nothing on
        // screen to explain it.
        switcher.onCropUnavailable = { [weak self] in
            guard let self, self.latched, !self.switcher.isCropping else { return }
            self.latched = false
        }
    }

    deinit {
        watchdog?.invalidate()
        retryTimer?.invalidate()
    }

    func start() {
        // A revoked-then-restored Accessibility grant leaves a tap object behind that no longer
        // receives anything; drop it so we build a fresh one.
        if let existing = tap, !CGEvent.tapIsEnabled(tap: existing) { teardown() }
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotkeyController>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            // Creating the tap can fail in the window right after the Accessibility grant lands.
            // Without a retry the app looked healthy with a completely dead hotkey until relaunch.
            NSLog("Plakke: could not create event tap (attempt \(retries + 1))")
            scheduleRetry()
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        retryTimer?.invalidate()
        retryTimer = nil
        retries = 0
        isRunning = true
        NotificationCenter.default.post(name: Self.tapRecovered, object: nil)
    }

    private func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
        isRunning = false
        endSession(commit: false)
        heldTriggerKey = nil
        swallowedKeys.removeAll()
    }

    private func scheduleRetry() {
        guard retryTimer == nil, retries < 10 else {
            if retries >= 10 { NotificationCenter.default.post(name: Self.tapFailed, object: nil) }
            return
        }
        retries += 1
        let t = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.start()
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    // MARK: the tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS disables taps that are slow; re-enable and move on. A disabled tap also means we
        // may have missed the modifier release that ends the session, so don't stay armed —
        // staying armed made the tap swallow every keystroke system-wide until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if active { endSession(commit: false) }
            // We also can't trust what we think is still held, and a stale `heldTriggerKey` would
            // keep swallowing that key forever.
            heldTriggerKey = nil
            swallowedKeys.removeAll()
            return pass
        }

        // Our own synthesised ⌘V. Without this, pasting while ⇧ was still held could land inside a
        // fresh switcher session, where the ⌘V was read as another tap of the trigger key.
        if event.getIntegerValueField(.eventSourceUserData) == Paster.syntheticMarker { return pass }

        if paused && !active { return pass }

        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // Exact match among the real modifiers: a subset test let ⌃⌥V hijack another app's ⌃⌥V.
        let modifiersMatch = flags.intersection([.maskControl, .maskAlternate, .maskCommand]) == hotkey.modifiers

        if active {
            lastActivity = Date()
            if flags.contains(.maskShift) { lastShiftSeen = Date() }
        }

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if !active {
                // Autorepeats of a trigger key still held after esc or a paste: eat them, and don't
                // let them re-open the switcher (which made esc impossible to use while holding V).
                // Only repeats — a fresh press is a new gesture, so a missed keyUp can't strand the
                // key in a permanently swallowed state.
                if key == heldTriggerKey {
                    if isRepeat { return nil }
                    heldTriggerKey = nil
                }
                if modifiersMatch, key == hotkey.key, !isRepeat {
                    beginSession(triggerKey: key, shift: flags.contains(.maskShift))
                    return nil
                }
                return pass
            }

            if isRepeat {
                let cycles = key == hotkey.key || key == Key.left || key == Key.right
                guard cycles, Date().timeIntervalSince(lastRepeatStep) > 0.14 else {
                    // Deliberately NOT recorded as swallowed: if the key was already held when the
                    // session opened, its first press went to the app underneath, and eating the
                    // matching keyUp would leave that app believing the key is still down.
                    return nil
                }
                lastRepeatStep = Date()
            }
            if key == hotkey.key { heldTriggerKey = key }
            if !isRepeat { swallowedKeys.insert(key) }
            route(key: key, flags: flags)
            return nil   // swallow everything while the switcher is up

        case .keyUp:
            if key == heldTriggerKey { heldTriggerKey = nil }
            if swallowedKeys.remove(key) != nil { return nil }
            return pass

        case .flagsChanged:
            // Latched: the modifier release is just a release. ↩ / esc end the session instead.
            if active, !latched, !flags.contains(hotkey.modifiers) {
                endSession(commit: true, plain: flags.contains(.maskShift) || shiftIsRecent)
            }
            return pass

        default:
            return pass
        }
    }

    private func route(key: Int64, flags: CGEventFlags) {
        // While latched, only the three keys that make sense in a crop do anything. Everything else
        // is still swallowed, so a stray keystroke can't leak into the app underneath.
        if latched {
            switch key {
            case Key.x:      onMain { $0.toggleCropMode() }
            case Key.return: endSession(commit: true, plain: false)
            case Key.escape: endSession(commit: false)
            default:         break
            }
            if active, latched { armLatchTimeout() }   // not for the ⏎/esc cases that just ended it
            return
        }

        switch key {
        case hotkey.key, Key.right:
            let back = flags.contains(.maskShift) && key == hotkey.key
            onMain { $0.step(back ? -1 : 1) }
        case Key.left:          onMain { $0.step(-1) }
        case Key.delete:        onMain { $0.removeSelected() }
        // ⌘Z while cycling: take back the last ⌫. The trigger modifier is still held, so this
        // never reaches the app underneath.
        case Key.z where flags.contains(.maskCommand):
                                onMain { $0.undoRemove() }
        case Key.escape:        endSession(commit: false)
        case Key.space:         onMain { $0.togglePeek() }
        case Key.up, Key.down:  onMain { $0.toggleTextMode() }
        case Key.p:             onMain { $0.togglePin() }
        case Key.return:        endSession(commit: true, plain: flags.contains(.maskShift))
        case Key.x:
            // Entering crop mode latches the session. Read synchronously — the tap has to decide now
            // whether a later ⌥ release still means "paste".
            guard switcher.canEnterCropMode else { break }
            latched = true
            armLatchTimeout()
            onMain { $0.toggleCropMode() }
        default:
            if let i = Key.digits[key] {
                onMain { $0.select(i) }
            } else if let t = Transform.forKey(key) {
                onMain { $0.toggleTransform(t) }
            }
        }
    }

    /// Switcher work runs just after the tap callback returns, so a slow SwiftUI layout pass can't
    /// make macOS time the tap out mid-gesture.
    private func onMain(_ body: @escaping (SwitcherController) -> Void) {
        let switcher = self.switcher
        DispatchQueue.main.async { body(switcher) }
    }

    // MARK: session

    private func beginSession(triggerKey: Int64, shift: Bool) {
        active = true
        heldTriggerKey = triggerKey
        lastShiftSeen = shift ? Date() : .distantPast
        swallowedKeys.insert(triggerKey)
        lastActivity = Date()
        lastRepeatStep = .distantPast
        onMain { $0.begin() }
        startWatchdog()
    }

    private func endSession(commit: Bool, plain: Bool = false, dispatch: Bool = true) {
        guard active else { return }
        active = false
        latched = false
        latchTimeout?.invalidate()
        latchTimeout = nil
        stopWatchdog()
        lastShiftSeen = .distantPast
        lastRepeatStep = .distantPast
        guard dispatch else { return }
        onMain { commit ? $0.commit(plain: plain) : $0.cancel() }
    }

    /// The only reliable way out of a desync: ask the hardware. If the trigger modifier isn't
    /// actually held any more we end the session even though no release event arrived — the case
    /// where the tap was disabled and *no further events are delivered at all*, which is exactly
    /// when an event-driven check can never run.
    private func startWatchdog() {
        stopWatchdog()
        watchdog = Timer.plakkeRepeating(0.25) { [weak self] in
            guard let self, self.active, !self.latched else { return }
            let live = CGEventSource.flagsState(.combinedSessionState)
            guard !live.contains(self.hotkey.modifiers) else { return }
            // Released a moment ago: honour it as a paste. Long gone: the user has moved on, so
            // just close the strip rather than pasting into whatever now has focus.
            // A main-thread stall (peek decoding a large image, a SwiftUI layout pass) can delay the
            // real flagsChanged past the watchdog's tick, and a 0.6s threshold then turned an ordinary
            // paste into a cancel. 1.5s still catches a genuinely abandoned session.
            let stale = Date().timeIntervalSince(self.lastActivity) > 1.5
            self.endSession(commit: !stale, plain: self.shiftIsRecent)
        }
    }

    /// A latched session has no held modifier to end it, so an abandoned crop would sit there
    /// swallowing every keystroke. Thirty seconds of silence closes it.
    private func armLatchTimeout() {
        latchTimeout?.invalidate()
        let t = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, self.active, self.latched else { return }
            self.endSession(commit: false)
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        latchTimeout = t
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}
