import Foundation

/// A value that can live in UserDefaults. Reading always takes a fallback, so a setting behaves the
/// same whether or not `registerDefaults()` has run — which matters for tests, and for the first
/// launch after a new setting is added.
protocol SettingValue {
    static func read(from defaults: UserDefaults, key: String, fallback: Self) -> Self
    func write(to defaults: UserDefaults, key: String)
    var defaultsObject: Any { get }
}

extension Bool: SettingValue {
    static func read(from d: UserDefaults, key: String, fallback: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? fallback
    }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
    var defaultsObject: Any { self }
}

extension Int: SettingValue {
    static func read(from d: UserDefaults, key: String, fallback: Int) -> Int {
        d.object(forKey: key) as? Int ?? fallback
    }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
    var defaultsObject: Any { self }
}

extension Array: SettingValue where Element == String {
    static func read(from d: UserDefaults, key: String, fallback: [String]) -> [String] {
        d.stringArray(forKey: key) ?? fallback
    }
    func write(to d: UserDefaults, key: String) { d.set(self, forKey: key) }
    var defaultsObject: Any { self }
}

/// Key, default, and the words the menu shows — declared in one place, so adding a setting no longer
/// means editing `Settings` and three spots in the menu builder.
struct Setting<Value: SettingValue> {
    let key: String
    let defaultValue: Value
    let label: String
    let help: String?

    init(key: String, default defaultValue: Value, label: String, help: String? = nil) {
        self.key = key
        self.defaultValue = defaultValue
        self.label = label
        self.help = help
    }

    var value: Value {
        get { Value.read(from: Settings.defaults, key: key, fallback: defaultValue) }
        nonmutating set {
            newValue.write(to: Settings.defaults, key: key)
            Settings.didChange(key)
        }
    }

    var descriptor: SettingDescriptor {
        SettingDescriptor(key: key, defaultsObject: defaultValue.defaultsObject)
    }
}

/// A setting with a fixed set of allowed values. Anything else on disk reads back as the default, so
/// a stale or hand-edited value can't leave the menu with no checkmark and no way to tell what's on.
struct Choice<Value: SettingValue & Equatable> {
    let key: String
    let defaultValue: Value
    let label: String
    let help: String?
    let options: [(title: String, value: Value)]

    init(key: String, default defaultValue: Value, label: String, help: String? = nil,
         options: [(title: String, value: Value)]) {
        self.key = key
        self.defaultValue = defaultValue
        self.label = label
        self.help = help
        self.options = options
    }

    var value: Value {
        get {
            let raw = Value.read(from: Settings.defaults, key: key, fallback: defaultValue)
            return options.contains(where: { $0.value == raw }) ? raw : defaultValue
        }
        nonmutating set {
            guard options.contains(where: { $0.value == newValue }) else { return }
            newValue.write(to: Settings.defaults, key: key)
            Settings.didChange(key)
        }
    }

    var descriptor: SettingDescriptor {
        SettingDescriptor(key: key, defaultsObject: defaultValue.defaultsObject)
    }

    /// Title of the active option, for a menu subtitle.
    var activeTitle: String { options.first { $0.value == value }?.title ?? "—" }
}

struct SettingDescriptor {
    let key: String
    let defaultsObject: Any
}

enum Settings {
    static let defaults = UserDefaults.standard

    /// Posted after any setting changes, with the key as `object` (nil when everything was reset).
    static let changed = Notification.Name("PlakkeSettingsChanged")

    // MARK: the settings

    static let rememberSecrets = Setting(
        key: "rememberSecrets", default: true,
        label: "Remember Password Copies for 60 Seconds",
        help: "Copies from a password manager — and anything that looks like a key, token or card "
            + "number — stay in the history for 60 seconds, in memory only, then vanish.")

    /// macOS doesn't hand AppKit or SwiftUI a system text-scale signal the way iOS does, and the
    /// panel is sized from fixed layout constants, so this is an explicit choice rather than an
    /// attempt to follow a setting that isn't there.
    static let largerCards = Setting(
        key: "largerCards", default: false,
        label: "Larger Cards",
        help: "Scales the switcher up by 25% for easier reading.")

    static let autoForget = Choice(
        key: "autoForgetHours", default: 0,
        label: "Forget Clips After",
        help: "Unpinned clips older than this are dropped. Pinned clips are never forgotten.",
        options: [("Never", 0), ("1 Hour", 1), ("8 Hours", 8), ("24 Hours", 24)])

    static let ignoredApps = Setting(
        key: "ignoredApps", default: [String](),
        label: "Never Record From",
        help: "Copies made in these apps are never recorded at all.")

    /// The hotkey lives here too, rather than in its own corner of UserDefaults with its own
    /// accessors. `Hotkey.current` is still the typed way to read it; -1 means "never set".
    static let hotkeyModifiers = Setting(key: "hotkeyModifiers", default: 0, label: "Hotkey Modifiers")
    static let hotkeyKey = Setting(key: "hotkeyKey", default: -1, label: "Hotkey Key")

    /// Every key we own, for `registerDefaults()` and `resetAll()`.
    static let all: [SettingDescriptor] = [
        rememberSecrets.descriptor, largerCards.descriptor, autoForget.descriptor,
        ignoredApps.descriptor, hotkeyModifiers.descriptor, hotkeyKey.descriptor,
    ]

    /// What the preferences submenu shows, in order. The menu is a projection of this list rather
    /// than a second copy of it.
    enum Preference {
        case toggle(Setting<Bool>)
        case choice(Choice<Int>)
        case appList(Setting<[String]>)
        case launchAtLogin
    }

    static let preferences: [Preference] = [
        .toggle(rememberSecrets),
        .toggle(largerCards),
        .choice(autoForget),
        .appList(ignoredApps),
        .launchAtLogin,
    ]

    // MARK: lifecycle

    private static var externalObserver: NSObjectProtocol?

    static func registerDefaults() {
        var dict: [String: Any] = [:]
        for s in all { dict[s.key] = s.defaultsObject }
        defaults.register(defaults: dict)

        // A `defaults write`, a configuration push, or a second copy of Plakke changes the store
        // without going through `Setting.value` — and the derived caches would stay stale until some
        // unrelated setting happened to change. An uncached read self-heals; a cache has to be told.
        guard externalObserver == nil else { return }
        externalObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { _ in invalidateCaches() }
    }

    /// Applies several writes, then announces once. Used by the hotkey, which is two keys: posting
    /// between them published a torn combo — new modifiers with the old key.
    static func batch(_ changes: () -> Void, announcing key: String) {
        suppressNotifications = true
        changes()
        suppressNotifications = false
        didChange(key)
    }

    private static var suppressNotifications = false

    static func resetAll() {
        for s in all { defaults.removeObject(forKey: s.key) }
        invalidateCaches()
        NotificationCenter.default.post(name: changed, object: nil)
        NotificationCenter.default.post(name: Hotkey.changed, object: nil)
    }

    static func didChange(_ key: String) {
        invalidateCaches()
        guard !suppressNotifications else { return }
        NotificationCenter.default.post(name: changed, object: key)
    }

    /// Flips a boolean setting by key, so every toggle in the menu can share one action.
    static func toggleBool(key: String) {
        for case let .toggle(setting) in preferences where setting.key == key {
            setting.value.toggle()
            return
        }
    }

    // MARK: derived values, cached

    private static var ignoredAppSetCache: Set<String>?
    private static var cardScaleCache: CGFloat?

    private static func invalidateCaches() {
        ignoredAppSetCache = nil
        cardScaleCache = nil
    }

    /// Lowercased, and rebuilt once per change rather than once per clipboard event — the old
    /// accessor allocated a fresh Set (twice) on every copy.
    static var ignoredAppSet: Set<String> {
        if let cached = ignoredAppSetCache { return cached }
        let set = Set(ignoredApps.value.map { $0.lowercased() })
        ignoredAppSetCache = set
        return set
    }

    static func isIgnoredApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let set = ignoredAppSet
        return !set.isEmpty && set.contains(bundleID.lowercased())
    }

    static func toggleIgnoredApp(_ bundleID: String) {
        let key = bundleID.lowercased()
        var apps = Set(ignoredApps.value.map { $0.lowercased() })
        if apps.contains(key) { apps.remove(key) } else { apps.insert(key) }
        ignoredApps.value = apps.sorted()
    }

    /// Read by every layout constant in the strip, so it can't afford to hit UserDefaults each time.
    static var cardScale: CGFloat {
        if let cached = cardScaleCache { return cached }
        let scale: CGFloat = largerCards.value ? 1.25 : 1.0
        cardScaleCache = scale
        return scale
    }
}
