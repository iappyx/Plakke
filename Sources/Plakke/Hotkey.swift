import AppKit
import CoreGraphics

/// The switcher trigger. Hold `modifiers`, tap `key` to cycle, release to paste.
/// Only ⌃ and ⌥ are allowed as modifiers: ⌘ would collide with real shortcuts,
/// ⇧ is used inside the switcher (reverse, plain paste).
struct Hotkey: Equatable {
    var modifiers: CGEventFlags
    var key: Int64

    static let `default` = Hotkey(modifiers: .maskAlternate, key: Key.v)
    static let allowedModifiers: CGEventFlags = [.maskControl, .maskAlternate]
    static let changed = Notification.Name("PlakkeHotkeyChanged")

    /// Keys that already mean something inside the switcher and can't be the trigger.
    static let reservedKeys: Set<Int64> = {
        var s: Set<Int64> = [Key.escape, Key.delete, Key.left, Key.right, Key.up, Key.down,
                             Key.space, Key.p, Key.z, Key.x, Key.return,
                             32, 37, 17, 15, 46, 8, 38]   // U L T R M C J
        s.formUnion(Key.digits.keys)
        return s
    }()

    var modifierSymbols: String {
        (modifiers.contains(.maskControl) ? "⌃" : "") + (modifiers.contains(.maskAlternate) ? "⌥" : "")
    }
    var keyName: String { KeyNames.name(for: key) }
    var label: String { modifierSymbols + " " + keyName }

    // MARK: persistence

    static var current: Hotkey {
        get {
            let stored = Settings.hotkeyKey.value
            guard stored >= 0 else { return .default }
            let key = Int64(stored)
            // `UInt64(_:)` traps on a negative value, so a corrupt or hand-edited default crashed the
            // app on the very first read of the hotkey.
            let storedModifiers = Settings.hotkeyModifiers.value
            guard storedModifiers >= 0 else { return .default }
            let mods = CGEventFlags(rawValue: UInt64(storedModifiers)).intersection(allowedModifiers)
            guard !mods.isEmpty else { return .default }
            // A key that has *since* become a switcher command would silently collide with it — the
            // reserved set grows as features are added, and a combo saved before that still loads.
            guard !reservedKeys.contains(key) else {
                NSLog("Plakke: saved hotkey \(KeyNames.name(for: key)) is now used inside the switcher — using ⌥V")
                return .default
            }
            return Hotkey(modifiers: mods, key: key)
        }
        set {
            // Both keys, then one announcement: posting between them published a combo that was half
            // new and half old.
            Settings.batch({
                Settings.hotkeyModifiers.value = Int(newValue.modifiers.rawValue)
                Settings.hotkeyKey.value = Int(newValue.key)
            }, announcing: Settings.hotkeyKey.key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

enum Key {
    static let v: Int64 = 9
    static let escape: Int64 = 53
    static let delete: Int64 = 51
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let up: Int64 = 126
    static let down: Int64 = 125
    static let space: Int64 = 49
    static let p: Int64 = 35
    static let command: Int64 = 55
    static let z: Int64 = 6
    static let x: Int64 = 7
    static let `return`: Int64 = 36

    /// Digit keys 1…9 → index 0…8, and 0 → index 9, so the card labelled "10" is reachable too.
    static let digits: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
                                       29: 9]
}

enum KeyNames {
    private static let table: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 76: "⌤",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static func name(for key: Int64) -> String { table[key] ?? "key \(key)" }
}
