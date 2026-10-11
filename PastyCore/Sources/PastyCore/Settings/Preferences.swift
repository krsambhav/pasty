import Foundation
import Observation

/// A global keyboard shortcut. Modifiers use Carbon's bit layout so they can be handed straight
/// to `RegisterEventHotKey`.
public struct KeyCombo: Codable, Sendable, Hashable {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘⇧V
    public static let `default` = KeyCombo(keyCode: 9, modifiers: command | shift)

    /// Shortcuts need at least one of ⌘, ⌥ or ⌃ to be safe as global hotkeys.
    public var isValidGlobalShortcut: Bool {
        modifiers & (Self.command | Self.option | Self.control) != 0
    }

    /// "⌃⌥⇧⌘" in Apple's canonical order.
    public var modifierSymbols: String {
        var result = ""
        if modifiers & Self.control != 0 { result += "⌃" }
        if modifiers & Self.option != 0 { result += "⌥" }
        if modifiers & Self.shift != 0 { result += "⇧" }
        if modifiers & Self.command != 0 { result += "⌘" }
        return result
    }
}

public enum AppearanceMode: String, Sendable, CaseIterable, Codable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// User preferences, persisted to `UserDefaults` on every change.
@MainActor
@Observable
public final class Preferences {
    public static let historyLimitChoices = [100, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000]

    enum Key {
        static let hotKey = "hotKey"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let appearance = "appearance"
        static let maxHistory = "maxHistory"
        static let isPaused = "isPaused"
        static let duplicateHandling = "duplicateHandling"
        static let captureImages = "captureImages"
        static let keepPinnedOnClear = "keepPinnedOnClear"
        static let excludedApps = "excludedApps"
        static let skipLikelySecrets = "skipLikelySecrets"
        static let pasteOnSelect = "pasteOnSelect"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let autoUpdate = "autoUpdate"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any persisted value changes.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public var hotKey: KeyCombo { didSet { saveCodable(hotKey, Key.hotKey) } }
    public var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, Key.showMenuBarIcon) } }
    public var appearance: AppearanceMode { didSet { save(appearance.rawValue, Key.appearance) } }
    public var maxHistory: Int { didSet { save(maxHistory, Key.maxHistory) } }
    public var isPaused: Bool { didSet { save(isPaused, Key.isPaused) } }
    public var duplicateHandling: DuplicateHandling { didSet { save(duplicateHandling.rawValue, Key.duplicateHandling) } }
    public var captureImages: Bool { didSet { save(captureImages, Key.captureImages) } }
    public var keepPinnedOnClear: Bool { didSet { save(keepPinnedOnClear, Key.keepPinnedOnClear) } }
    public var excludedApps: [ExcludedApp] { didSet { saveCodable(excludedApps, Key.excludedApps) } }
    public var skipLikelySecrets: Bool { didSet { save(skipLikelySecrets, Key.skipLikelySecrets) } }
    /// Return pastes into the frontmost app when true; otherwise it only copies.
    public var pasteOnSelect: Bool { didSet { save(pasteOnSelect, Key.pasteOnSelect) } }
    public var hasLaunchedBefore: Bool { didSet { save(hasLaunchedBefore, Key.hasLaunchedBefore) } }
    /// Download and install new releases in the background.
    public var autoUpdate: Bool { didSet { save(autoUpdate, Key.autoUpdate) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotKey = Self.decode(KeyCombo.self, defaults, Key.hotKey) ?? .default
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        appearance = (defaults.string(forKey: Key.appearance)).flatMap(AppearanceMode.init) ?? .system
        let storedLimit = defaults.object(forKey: Key.maxHistory) as? Int ?? 10_000
        maxHistory = min(max(storedLimit, 10), 50_000)
        isPaused = defaults.bool(forKey: Key.isPaused)
        duplicateHandling = defaults.string(forKey: Key.duplicateHandling).flatMap(DuplicateHandling.init) ?? .moveToTop
        captureImages = defaults.object(forKey: Key.captureImages) as? Bool ?? true
        keepPinnedOnClear = defaults.object(forKey: Key.keepPinnedOnClear) as? Bool ?? true
        excludedApps = Self.decode([ExcludedApp].self, defaults, Key.excludedApps) ?? DefaultExclusions.apps
        skipLikelySecrets = defaults.bool(forKey: Key.skipLikelySecrets)
        pasteOnSelect = defaults.object(forKey: Key.pasteOnSelect) as? Bool ?? true
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore)
        autoUpdate = defaults.object(forKey: Key.autoUpdate) as? Bool ?? true
    }

    /// The subset of preferences the clipboard monitor needs, as a value it can own.
    public var captureRules: CaptureRules {
        CaptureRules(
            isPaused: isPaused,
            captureImages: captureImages,
            excludedBundleIDs: Set(excludedApps.map(\.bundleID)),
            skipLikelySecrets: skipLikelySecrets
        )
    }

    public func resetExcludedApps() {
        excludedApps = DefaultExclusions.apps
    }

    // MARK: Persistence

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
        onChange?()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
