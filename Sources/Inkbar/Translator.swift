import Foundation
import NaturalLanguage
import Translation

/// On-device translation with Apple's Translation framework. Text never leaves the Mac.
@MainActor
enum Translator {
    enum Outcome: Equatable {
        case translated(text: String, source: String, target: String)
        /// The pair is supported but its languages are not downloaded yet.
        case needsDownload(source: String, target: String)
        case sameLanguage(String)
        case unsupported(source: String, target: String)
        case undetected
        case failed(String)
    }

    /// The language of the text, or nil when the recognizer is not sure: a word or two is often
    /// misread, and a wrong guess is worse than none.
    nonisolated static func detect(_ text: String) -> String? {
        TextAnalysis.dominantLanguage(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func translate(_ text: String, to target: String) async -> Outcome {
        guard let source = detect(text) else { return .undetected }
        if ActionKind.sameLanguage(source, target) { return .sameLanguage(source) }
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: from, to: to)
        switch status {
        case .installed:
            do {
                let session = TranslationSession(installedSource: from, target: to)
                let response = try await session.translate(text)
                return .translated(text: response.targetText, source: source, target: target)
            } catch {
                return .failed(message(for: error))
            }
        case .supported:
            return .needsDownload(source: source, target: target)
        case .unsupported:
            return .unsupported(source: source, target: target)
        @unknown default:
            return .unsupported(source: source, target: target)
        }
    }

    /// Runs inside SwiftUI's translationTask, which can show the system download prompt.
    nonisolated static func translate(_ text: String, with session: TranslationSession, source: String, target: String) async -> Outcome {
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            return .translated(text: response.targetText, source: source, target: target)
        } catch {
            return .failed(message(for: error))
        }
    }

    nonisolated static func message(for error: Error) -> String {
        if error is CancellationError { return "Translation was cancelled." }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "Translation did not finish. Try again." : text
    }

    /// A language's name in the user's own language, e.g. "German".
    nonisolated static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }

    /// Just the language, without the region: "English" for en-US.
    nonisolated static func languageName(_ code: String) -> String {
        let base = Locale.Language(identifier: code).languageCode?.identifier ?? code
        return name(base)
    }

    nonisolated static func isRightToLeft(_ code: String) -> Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    /// Languages offered as targets in Settings, sorted by name.
    nonisolated static func supportedTargets() async -> [(code: String, name: String)] {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var result: [(code: String, name: String)] = []
        for language in languages {
            let short = language.minimalIdentifier
            guard seen.insert(short).inserted else { continue }
            result.append((short, name(short)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
