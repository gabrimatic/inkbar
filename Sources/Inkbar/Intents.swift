import AppIntents
import Foundation

/// Inkbar's actions for Shortcuts, Spotlight and Siri, plus its Focus filter. Each one runs
/// in the Inkbar app on this Mac.

enum InkbarIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noSelection
    case notMath
    case translation(String)
    case intelligence(String)
    case empty

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "Inkbar is not running."
        case .noSelection: return "There is no readable selection in the frontmost app, or Inkbar lacks Accessibility access."
        case .notMath: return "That is not a calculation Inkbar understands."
        case .translation(let reason): return "\(reason)"
        case .intelligence(let reason): return "\(reason)"
        case .empty: return "There is no text to work on."
        }
    }
}

struct ShowInkbarIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Inkbar for Selection"
    static let description = IntentDescription("Shows the Inkbar bar for the text selected in the frontmost app.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let app = AppDelegate.shared else { throw InkbarIntentError.notRunning }
        guard app.showForCurrentSelection() else { throw InkbarIntentError.noSelection }
        return .result()
    }
}

struct SetInkbarPausedIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Inkbar"
    static let description = IntentDescription("Pauses or resumes the Inkbar bar.")

    @Parameter(title: "Paused", default: true)
    var paused: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set Inkbar paused to \(\.$paused)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppSettings.shared.paused = paused
        return .result(dialog: paused ? "Inkbar is paused." : "Inkbar is on.")
    }
}

struct CleanTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Text"
    static let description = IntentDescription("Tidies whitespace and removes tracking parameters from links.")

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Clean \(\.$text)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: TextCleaner.clean(text))
    }
}

struct CalculateIntent: AppIntent {
    static let title: LocalizedStringResource = "Calculate"
    static let description = IntentDescription("Works out a sum such as 12 * (3 + 4.5) / 2.")

    @Parameter(title: "Expression")
    var expression: String

    static var parameterSummary: some ParameterSummary { Summary("Calculate \(\.$expression)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let value = MathEvaluator.evaluate(expression) else { throw InkbarIntentError.notMath }
        return .result(value: MathEvaluator.format(value))
    }
}

struct TranslateTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Text on Device"
    static let description = IntentDescription("Translates text on this Mac with Apple Translation. Leave the language empty for Inkbar's setting.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Language code", description: "For example de, fr or ja.")
    var language: String?

    static var parameterSummary: some ParameterSummary { Summary("Translate \(\.$text) into \(\.$language)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InkbarIntentError.empty }
        let target = language.flatMap { $0.isEmpty ? nil : $0 } ?? AppSettings.shared.effectiveTarget
        switch await Translator.translate(text, to: target) {
        case .translated(let result, _, _): return .result(value: result)
        case .sameLanguage: return .result(value: text)
        case .needsDownload(let s, let t):
            throw InkbarIntentError.translation("\(Translator.name(s)) to \(Translator.name(t)) needs a one-time download. Translate once from the Inkbar bar, or add the languages in System Settings > General > Language & Region > Translation Languages.")
        case .unsupported(let s, let t):
            throw InkbarIntentError.translation("Apple Translation cannot translate \(Translator.name(s)) to \(Translator.name(t)) yet.")
        case .undetected: throw InkbarIntentError.translation("Inkbar could not tell which language this is.")
        case .failed(let reason): throw InkbarIntentError.translation(reason)
        }
    }
}

enum WritingTaskOption: String, AppEnum {
    case summarize, explain, rewrite, fixGrammar, reply

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Writing Action"
    static let caseDisplayRepresentations: [WritingTaskOption: DisplayRepresentation] = [
        .summarize: "Summarize", .explain: "Explain", .rewrite: "Rewrite", .fixGrammar: "Proofread", .reply: "Reply",
    ]

    var task: WritingTask { WritingTask(rawValue: rawValue) ?? .summarize }
}

struct WriteWithIntelligenceIntent: AppIntent {
    static let title: LocalizedStringResource = "Write with Apple Intelligence"
    static let description = IntentDescription("Summarizes, explains, rewrites, fixes the grammar of, or replies to text, on this Mac.")

    @Parameter(title: "Action", default: .summarize)
    var action: WritingTaskOption

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InkbarIntentError.empty }
        guard text.utf16.count <= Intelligence.characterLimit(for: action.task) else {
            throw InkbarIntentError.intelligence(Intelligence.tooLong(action.task).errorDescription ?? "That text is too long.")
        }
        guard Intelligence.isAvailable else { throw InkbarIntentError.intelligence(Intelligence.statusMessage) }
        do {
            return .result(value: try await Intelligence.run(action.task, on: text) { _ in })
        } catch {
            throw InkbarIntentError.intelligence(Intelligence.message(for: error))
        }
    }
}

/// Pause Inkbar while a chosen Focus is on, from System Settings > Focus > Focus Filters.
struct InkbarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Inkbar"
    static let description: IntentDescription? = IntentDescription("Pause the Inkbar bar while this Focus is on.")

    /// Nil when the Focus turns off, which resumes Inkbar.
    @Parameter(title: "Pause Inkbar")
    var pause: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: pause == true ? "Pause Inkbar" : "Keep Inkbar on")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppSettings.shared.focusPaused = pause ?? false
        return .result()
    }
}

struct InkbarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowInkbarIntent(), phrases: ["Show \(.applicationName)", "Show \(.applicationName) for my selection"],
                    shortTitle: "Show for Selection", systemImageName: "text.cursor")
        AppShortcut(intent: ToggleInkbarIntent(), phrases: ["Toggle \(.applicationName)", "Pause \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Toggle Inkbar", systemImageName: "pause.circle")
        AppShortcut(intent: CleanTextIntent(), phrases: ["Clean text with \(.applicationName)"],
                    shortTitle: "Clean Text", systemImageName: "text.badge.checkmark")
        AppShortcut(intent: WriteWithIntelligenceIntent(), phrases: ["Summarize with \(.applicationName)"],
                    shortTitle: "Write with Apple Intelligence", systemImageName: "pencil.and.scribble")
    }
}
