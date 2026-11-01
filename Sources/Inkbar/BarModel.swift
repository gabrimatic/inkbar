import AppKit
import Observation
import Translation

/// What the bar shows. The controller owns it; SwiftUI only reads it.
@MainActor @Observable
final class BarModel {
    enum Card: Equatable {
        /// Nil while translating.
        case translation(Translator.Outcome?)
        case calculation(expression: String, result: String)
        case count(words: Int, characters: Int, lines: Int)
        case changeCase
        /// Nil task: the list of writing actions. Otherwise the streamed result so far.
        case writing(task: WritingTask?, text: String, done: Bool, error: String?)
        /// Three answers at once: Reply or Rewrite.
        case choices(WritingTask)
        case event(EventDraft)
        case contact(ContactDraft)
        case tasks([String])
    }

    var actions: [ActionKind] = []
    var card: Card?
    var hovered: ActionKind?
    /// A short confirmation such as "Copied", shown in place of the buttons.
    var feedback: String?
    var feedbackIsError = false
    var editable = false
    /// The bar sits below the selection, so it grows from its top edge.
    var placedBelow = false
    var appeared = false
    var numberKeys = true
    /// Writing actions that fit the selection, in the order the card lists them.
    var writingTasks: [WritingTask] = []
    /// What reading ahead wrote for the selection: a note beside the bar, the meaning of a word,
    /// the point of a passage, or what went wrong.
    var glance: String?
    /// The answers in the choices card. They can be ready before the card opens.
    var choices: [ReadyChoice] = []
    var choicesDone = false
    var choicesError: String?
    /// Bumped on every show, so a new bar that replaces one mid-fade counts as a new appearance.
    var showCount = 0

    // Accessibility display options, read when the bar opens.
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false

    /// Set to start SwiftUI's translationTask, which can show the system download prompt.
    var translationConfig: TranslationSession.Configuration?
    var translationSource = ""
    var translationTarget = ""
    var selectedText = ""
    /// The writing card's error is "Apple Intelligence is off": it offers the button to its pane.
    var writingNeedsSettings = false

    func readDisplayOptions() {
        let ws = NSWorkspace.shared
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
    }

    func reset() {
        actions = []
        card = nil
        hovered = nil
        feedback = nil
        feedbackIsError = false
        appeared = false
        translationConfig = nil
        selectedText = ""
        writingTasks = []
        writingNeedsSettings = false
        glance = nil
        choices = []
        choicesDone = false
        choicesError = nil
    }

    /// Options in the open card that number keys pick, in order.
    var cardOptionCount: Int {
        switch card {
        case .changeCase?: return TextAnalysis.Case.allCases.count
        case .writing(nil, _, _, _)?: return writingTasks.count
        case .choices?: return choicesDone ? choices.count : 0
        default: return 0
        }
    }

    /// The number shown for an action, 1 to 9, or nil past nine.
    func shortcut(for kind: ActionKind) -> Int? {
        guard numberKeys, let index = actions.firstIndex(of: kind), index < 9 else { return nil }
        return index + 1
    }

    /// The Count card's three figures with their labels, exactly as the card shows them
    /// ("1,234 words", "1 word"). Copy writes the same text.
    nonisolated static func countParts(words: Int, characters: Int, lines: Int) -> [(value: String, label: String)] {
        [(words.formatted(), words == 1 ? "word" : "words"),
         (characters.formatted(), characters == 1 ? "character" : "characters"),
         (lines.formatted(), lines == 1 ? "line" : "lines")]
    }

    nonisolated static func countSummary(words: Int, characters: Int, lines: Int) -> String {
        countParts(words: words, characters: characters, lines: lines).map { "\($0.value) \($0.label)" }.joined(separator: ", ")
    }
}
