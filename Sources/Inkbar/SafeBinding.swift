import SwiftUI

extension Binding where Value: Sendable {
    /// A binding that is safe for SwiftUI to evaluate on any thread.
    ///
    /// `Binding(get:set:)` written inside a `@MainActor` view inherits main-actor isolation, and SwiftUI
    /// can call a binding's getter off the main thread while it updates a view graph. The runtime
    /// isolation check then traps (`_dispatch_assert_queue_fail`). This builds the binding in a
    /// nonisolated context instead: the getter returns `value`, which the caller read on the main
    /// actor while building its body, and the setter hops to the main actor to run `set`.
    /// SwiftUI reads the new value on its next update, because `set` changes observed state.
    nonisolated static func snapshot(
        _ value: Value,
        set: @escaping @MainActor @Sendable (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { @Sendable in value },
            set: { @Sendable newValue in Task { @MainActor in set(newValue) } }
        )
    }
}

extension AppSettings {
    /// The on/off switch of one action, safe to evaluate off the main thread.
    func enabledBinding(for kind: ActionKind) -> Binding<Bool> {
        .snapshot(!disabled.contains(kind)) { [self] on in
            if on { disabled.remove(kind) } else { disabled.insert(kind) }
        }
    }

    /// The rule for one app, safe to evaluate off the main thread.
    func ruleBinding(for bundleID: String) -> Binding<AppRule> {
        .snapshot(rules[bundleID] ?? .never) { [self] rule in rules[bundleID] = rule }
    }
}
