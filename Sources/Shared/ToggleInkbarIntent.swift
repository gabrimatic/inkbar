import AppIntents

/// Pauses or resumes Inkbar. Compiled into both the app and the Control Center extension,
/// so the control can name it, but it runs only inside the Inkbar app: the extension has no
/// way to change Inkbar, and no other process can send Inkbar a pause or resume.
struct ToggleInkbarIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Inkbar"
    static let description = IntentDescription("Pauses Inkbar when it is on, and resumes it when it is paused.")

    /// Run in the main app only, never in an extension.
    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if INKBAR_APP
        AppSettings.shared.paused.toggle()
        return .result(dialog: AppSettings.shared.paused ? "Inkbar is paused." : "Inkbar is on.")
        #else
        // Unreachable: the system runs this intent in the app. If it ever lands here, change nothing.
        return .result(dialog: "Open Inkbar to pause or resume it.")
        #endif
    }
}
