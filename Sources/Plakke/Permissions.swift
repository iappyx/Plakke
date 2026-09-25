import ApplicationServices
import Foundation

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var monitor: Timer?

    /// Prompts for Accessibility if needed, then calls `onGranted` (possibly later, after the user
    /// flips the switch in System Settings) — and again if the grant is revoked and restored, which
    /// otherwise left the app running with a dead event tap until the next relaunch.
    static func ensureAccessibility(_ onGranted: @escaping () -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        var trusted = AXIsProcessTrustedWithOptions(options)
        if trusted { onGranted() }

        monitor?.invalidate()
        monitor = Timer.plakkeRepeating(1.5) {
            let now = AXIsProcessTrusted()
            if now && !trusted { onGranted() }
            trusted = now
        }
    }
}
