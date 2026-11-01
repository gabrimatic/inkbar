import AppKit
import Observation

enum TriggerMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, modifier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatically"
        case .modifier: return "Only with a key held"
        }
    }
}

enum AppRule: String, CaseIterable, Identifiable, Sendable {
    case modifierOnly, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modifierOnly: return "Only with key held"
        case .never: return "Never"
        }
    }
}

enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case option, command, control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: return "Option\u{00A0}⌥"
        case .command: return "Command\u{00A0}⌘"
        case .control: return "Control\u{00A0}⌃"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }
}

/// All settings, stored in UserDefaults. Nothing else Inkbar keeps touches the disk.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Apps where a stray selection is common (terminals) or text is private.
    static let defaultRules: [String: AppRule] = [
        "com.apple.Terminal": .modifierOnly,
        "dev.warp.Warp-Stable": .modifierOnly,
        "dev.warp.Warp": .modifierOnly,
        "com.googlecode.iterm2": .modifierOnly,
        "com.mitchellh.ghostty": .modifierOnly,
        "com.apple.keychainaccess": .never,
        "com.1password.1password": .never,
        "com.bitwarden.desktop": .never,
        "com.apple.Passwords": .never,
    ]

    private enum Key {
        static let paused = "paused"
        static let order = "actionOrder"
        static let disabled = "disabledActions"
        static let engine = "searchEngine"
        static let target = "translateTarget"
        static let rules = "appRules"
        static let trigger = "triggerMode"
        static let triggerKey = "triggerKey"
        static let numberKeys = "numberKeys"
        static let copyFallback = "copyFallback"
        static let haptics = "haptics"
        static let focusPaused = "focusPaused"
        static let loginConfigured = "loginConfigured"
        static let onboardingDone = "onboardingDone"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let readAhead = "readAhead"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called when Inkbar is paused or resumed from anywhere (menu or Settings).
    @ObservationIgnored var onPausedChange: (() -> Void)?
    /// Called when the menu bar icon is switched on or off.
    @ObservationIgnored var onMenuBarIconChange: (() -> Void)?

    var paused: Bool {
        didSet {
            defaults.set(paused, forKey: Key.paused)
            onPausedChange?()
        }
    }
    var order: [ActionKind] { didSet { defaults.set(order.map(\.rawValue), forKey: Key.order) } }
    var disabled: Set<ActionKind> { didSet { defaults.set(disabled.map(\.rawValue).sorted(), forKey: Key.disabled) } }
    var engine: SearchEngine { didSet { defaults.set(engine.rawValue, forKey: Key.engine) } }
    /// Empty means the system language.
    var translateTarget: String { didSet { defaults.set(translateTarget, forKey: Key.target) } }
    var rules: [String: AppRule] { didSet { defaults.set(rules.mapValues(\.rawValue), forKey: Key.rules) } }
    var trigger: TriggerMode { didSet { defaults.set(trigger.rawValue, forKey: Key.trigger) } }
    var triggerKey: TriggerKey { didSet { defaults.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
    var numberKeys: Bool { didSet { defaults.set(numberKeys, forKey: Key.numberKeys) } }
    var copyFallback: Bool { didSet { defaults.set(copyFallback, forKey: Key.copyFallback) } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: Key.haptics) } }
    /// Apple Intelligence reads each selection on this Mac and offers what it finds.
    var readAhead: Bool { didSet { defaults.set(readAhead, forKey: Key.readAhead) } }
    /// The menu bar icon is optional: everything it offers is also in Settings.
    var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
            onMenuBarIconChange?()
        }
    }
    /// Set by an Inkbar Focus filter: paused while that Focus is on.
    var focusPaused: Bool {
        didSet {
            defaults.set(focusPaused, forKey: Key.focusPaused)
            onPausedChange?()
        }
    }

    /// Paused by the user or by a Focus.
    var isPaused: Bool { paused || focusPaused }

    var loginConfigured: Bool {
        get { defaults.bool(forKey: Key.loginConfigured) }
        set { defaults.set(newValue, forKey: Key.loginConfigured) }
    }

    /// The welcome window was finished: Done, Esc or its close button. Never set ahead of that.
    var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paused = defaults.bool(forKey: Key.paused)
        order = ActionPlanner.normalized(defaults.stringArray(forKey: Key.order) ?? [])
        disabled = Set((defaults.stringArray(forKey: Key.disabled) ?? []).compactMap(ActionKind.init(rawValue:)))
        engine = SearchEngine(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .google
        translateTarget = defaults.string(forKey: Key.target) ?? ""
        if let stored = defaults.dictionary(forKey: Key.rules) as? [String: String] {
            rules = stored.compactMapValues(AppRule.init(rawValue:))
        } else {
            rules = Self.defaultRules
        }
        trigger = TriggerMode(rawValue: defaults.string(forKey: Key.trigger) ?? "") ?? .automatic
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: Key.triggerKey) ?? "") ?? .option
        numberKeys = defaults.object(forKey: Key.numberKeys) as? Bool ?? true
        copyFallback = defaults.object(forKey: Key.copyFallback) as? Bool ?? true
        haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        readAhead = defaults.object(forKey: Key.readAhead) as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        focusPaused = defaults.bool(forKey: Key.focusPaused)
    }

    var enabledActions: Set<ActionKind> { Set(order).subtracting(disabled) }

    /// The language translations go into, as a BCP 47 code.
    var effectiveTarget: String {
        if !translateTarget.isEmpty { return translateTarget }
        return Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    func rule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return rules[bundleID]
    }

    func resetActions() {
        order = ActionKind.defaultOrder
        disabled = []
    }
}
