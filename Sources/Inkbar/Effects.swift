import AppKit

/// How much motion and feedback the bar uses right now: less under Reduce Motion, Low
/// Power Mode, or when the Mac is running hot.
@MainActor
enum Effects {
    struct State: Equatable {
        var reduceMotion = false
        var lowPower = false
        var hot = false

        /// The spring entrance runs only when nothing asks for less.
        var full: Bool { !reduceMotion && !lowPower && !hot }
    }

    static func current() -> State {
        let info = ProcessInfo.processInfo
        return State(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                     lowPower: info.isLowPowerModeEnabled,
                     hot: info.thermalState == .serious || info.thermalState == .critical)
    }

    /// A light tap from the Force Touch trackpad. Felt only while a finger rests on it,
    /// which is exactly when the user just selected or clicked.
    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern, enabled: Bool) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Tells VoiceOver users the bar is there and how to use it, without moving their cursor.
    static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// Scroll events left over from a fling that began before the bar appeared carry only a
    /// momentum phase. They must not dismiss it; a new scroll or a plain mouse wheel does.
    static func scrollDismisses(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Bool {
        !(phase.isEmpty && !momentumPhase.isEmpty)
    }
}
