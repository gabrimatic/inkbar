import SwiftUI
import Translation

/// Callbacks from the bar's views to the controller.
struct BarHandlers {
    var perform: @MainActor (ActionKind) -> Void = { _ in }
    var copy: @MainActor (String) -> Void = { _ in }
    var replace: @MainActor (String) -> Void = { _ in }
    var applyCase: @MainActor (TextAnalysis.Case) -> Void = { _ in }
    var close: @MainActor () -> Void = {}
    var download: @MainActor () -> Void = {}
    var translated: @MainActor (Translator.Outcome) -> Void = { _ in }
    var openTranslationSettings: @MainActor () -> Void = {}
    var chooseWriting: @MainActor (WritingTask) -> Void = { _ in }
    var choose: @MainActor (ReadyChoice) -> Void = { _ in }
    var addEvent: @MainActor (EventDraft) -> Void = { _ in }
    var addContact: @MainActor (ContactDraft) -> Void = { _ in }
    var addTasks: @MainActor ([String]) -> Void = { _ in }
    var openIntelligenceSettings: @MainActor () -> Void = {}
    var openInkbarSettings: @MainActor () -> Void = {}
}

/// An action's glyph: an SF Symbol at one regular weight, so no icon looks heavier than its
/// neighbours, or a short Plex wordmark where no symbol fits.
struct ActionGlyph: View {
    let kind: ActionKind
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let word = kind.wordmark {
                // Plex at the symbols' own weight, as tall as their capitals, with no box:
                // the name reads as a name, and no glyph in the row is heavier than its neighbours.
                Text(word)
                    .font(Typeface.font(size * 0.82))
                    .tracking(-0.2)
                    .fixedSize()
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: size, weight: .regular))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The small boxed number that marks a key shortcut.
struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(Typeface.font(10, .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Glass surface that falls back to a solid one when Reduce Transparency is on.
private struct Surface<S: InsettableShape>: ViewModifier {
    let shape: S
    let model: BarModel

    func body(content: Content) -> some View {
        if model.reduceTransparency {
            content
                .background(shape.fill(Theme.ground))
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        } else {
            // The border goes on the content, so the glass draws it in its own layer.
            content
                .overlay {
                    if model.increaseContrast {
                        shape.strokeBorder(Theme.text.opacity(0.7), lineWidth: 1.5)
                    }
                }
                .glassEffect(.regular, in: shape)
        }
    }
}

struct BarRootView: View {
    let model: BarModel
    let handlers: BarHandlers
    static let padding: CGFloat = 10

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            Group {
                if let card = model.card {
                    CardView(card: card, model: model, handlers: handlers)
                        .modifier(Surface(shape: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous), model: model))
                } else {
                    VStack(spacing: 6) {
                        if model.placedBelow {
                            row
                            glance
                        } else {
                            glance
                            row
                        }
                    }
                }
            }
        }
        .padding(Self.padding)
        .scaleEffect(model.appeared || model.reduceMotion ? 1 : 0.86, anchor: model.placedBelow ? .top : .bottom)
        .opacity(model.appeared ? 1 : 0)
        .offset(y: model.appeared || model.reduceMotion ? 0 : (model.placedBelow ? -6 : 6))
        .fixedSize()
        .environment(\.controlActiveState, .active)
    }
}

// MARK: Bar

private extension BarRootView {
    var row: some View {
        BarRow(model: model, handlers: handlers)
            .modifier(Surface(shape: Capsule(), model: model))
    }

    /// What reading ahead wrote, on its own glass so the row of buttons never moves. A click copies it.
    @ViewBuilder var glance: some View {
        if let text = model.glance, model.feedback == nil {
            Button { handlers.copy(text) } label: {
                Text(text)
                    .font(Typeface.font(12))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            .modifier(Surface(shape: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous), model: model))
            .transition(.opacity)
            .accessibilityLabel(text)
            .accessibilityHint("Copies this.")
        }
    }
}

private struct BarRow: View {
    let model: BarModel
    let handlers: BarHandlers

    var body: some View {
        HStack(spacing: 2) {
            if let feedback = model.feedback {
                Label {
                    Text(feedback).foregroundStyle(Theme.text)
                } icon: {
                    // A word does the work; the mark is a plain outline. Only a real error takes colour.
                    Image(systemName: model.feedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(model.feedbackIsError ? Theme.error : Theme.text)
                }
                    .labelStyle(.titleAndIcon)
                    .font(Typeface.font(13))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                ForEach(model.actions) { kind in
                    ActionButton(kind: kind, model: model, handlers: handlers)
                }
            }
        }
        .padding(4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inkbar actions")
    }
}

private struct ActionButton: View {
    let kind: ActionKind
    let model: BarModel
    let handlers: BarHandlers

    private var isHovered: Bool { model.hovered == kind }

    var body: some View {
        Button {
            handlers.perform(kind)
        } label: {
            ActionGlyph(kind: kind)
                .frame(width: 32, height: 30)
                .contentShape(Capsule())
                .background {
                    Capsule()
                        .fill(Theme.fill.opacity(isHovered ? 1 : 0))
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .onHover { inside in
            if inside {
                model.hovered = kind
            } else if model.hovered == kind {
                model.hovered = nil
            }
        }
        .help(helpText)
        .accessibilityLabel(kind.title)
        .accessibilityHint(accessibilityHint)
    }

    private var helpText: String {
        if let n = model.shortcut(for: kind) { return "\(kind.title)  (\(n))" }
        return kind.title
    }

    private var accessibilityHint: String {
        if let n = model.shortcut(for: kind) { return "\(kind.detail) Shortcut: \(n)." }
        return kind.detail
    }
}

/// The hover label that floats beside the bar, shown in its own small panel.
struct HintView: View {
    let text: String
    let shortcut: Int?
    /// Transparent room around the capsule inside the hint's panel.
    static let padding: CGFloat = 6

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Typeface.font(12))
                .foregroundStyle(Theme.text)
            if let shortcut { NumberBadge(number: shortcut) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // A hover label is not interactive, so it is flat: the ground and a hairline, no glass.
        .background(Capsule().fill(Theme.ground))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .padding(Self.padding)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: Cards

/// The icon column of a card: the header and every option row share it. It is as wide as the widest
/// symbol (the ABC of UPPERCASE), and each symbol is centred in it, so the titles line up.
private let iconColumn: CGFloat = 28


private struct CardView: View {
    let card: BarModel.Card
    let model: BarModel
    let handlers: BarHandlers

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .translationTask(model.translationConfig) { session in
            // SwiftUI hands the session to this task alone and never shares it.
            nonisolated(unsafe) let session = session
            let outcome = await Translator.translate(model.selectedText, with: session,
                                                     source: model.translationSource, target: model.translationTarget)
            handlers.translated(outcome)
        }
    }

    private var title: (String, String) {
        switch card {
        case .translation(let outcome):
            if case .translated(_, let source, let target)? = outcome {
                return (ActionKind.translate.symbol, "\(Translator.languageName(source)) → \(Translator.languageName(target))")
            }
            return (ActionKind.translate.symbol, "Translate")
        case .calculation: return (ActionKind.calculate.symbol, "Calculate")
        case .count: return (ActionKind.count.symbol, "Count")
        case .changeCase: return (ActionKind.changeCase.symbol, "Change Case")
        case .writing(let task?, _, _, _): return (task.symbol, task.title)
        case .writing(nil, _, _, _): return (ActionKind.intelligence.symbol, "Apple Intelligence")
        case .choices(let task): return (task.symbol, task == .reply ? "Replies" : "Rewrite")
        case .event: return (ActionKind.addEvent.symbol, ActionKind.addEvent.title)
        case .contact: return (ActionKind.addContact.symbol, ActionKind.addContact.title)
        case .tasks: return (ActionKind.addTasks.symbol, ActionKind.addTasks.title)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Same icon column and gap as the option rows below, so the titles line up.
            Image(systemName: title.0)
                .frame(width: iconColumn)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(title.1)
                .font(Typeface.font(13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: handlers.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .regular))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .translation(nil):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating on this Mac…").foregroundStyle(Theme.secondary)
            }
            .font(Typeface.font(13))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .translation(let outcome?):
            translation(outcome)
        case .calculation(let expression, let result):
            VStack(alignment: .leading, spacing: 2) {
                Text(expression)
                    .font(Typeface.font(12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("= \(result)")
                    .font(Typeface.font(24, .light))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .accessibilityElement(children: .combine)
            footer(copy: result, replace: result)
        case .count(let words, let characters, let lines):
            HStack(spacing: 0) {
                ForEach(BarModel.countParts(words: words, characters: characters, lines: lines), id: \.label) { part in
                    stat(part.value, part.label)
                }
            }
            footer(copy: BarModel.countSummary(words: words, characters: characters, lines: lines), replace: nil)
        case .changeCase:
            // The same rows, numbers and alignment as the Apple Intelligence list.
            VStack(spacing: 2) {
                ForEach(Array(TextAnalysis.Case.allCases.enumerated()), id: \.element) { index, c in
                    OptionRow(title: c.title, symbol: c.symbol, number: model.numberKeys ? index + 1 : nil) {
                        handlers.applyCase(c)
                    }
                    .accessibilityHint(model.editable ? "Replaces the selection." : "Copies the result.")
                }
            }
            .padding(.horizontal, -OptionRow.inset)
            Text(model.editable ? "Replaces the selected text." : "Copies the changed text.")
                .font(Typeface.font(11))
                .foregroundStyle(Theme.secondary)
        case .choices:
            readyChoices
        case .event(let draft):
            detail("text.alignleft", draft.title)
            detail("clock", when(draft))
            if !draft.place.isEmpty { detail("mappin", draft.place) }
            draftFooter("Add", copy: "\(draft.title), \(when(draft))") { handlers.addEvent(draft) }
        case .contact(let draft):
            detail("person", draft.name)
            let work = [draft.role, draft.company].filter { !$0.isEmpty }.joined(separator: ", ")
            if !work.isEmpty { detail("building.2", work) }
            ForEach(draft.emails, id: \.self) { detail("envelope", $0) }
            ForEach(draft.phones, id: \.self) { detail("phone", $0) }
            draftFooter("Add", copy: ([draft.name, work] + draft.emails + draft.phones).filter { !$0.isEmpty }.joined(separator: "\n")) { handlers.addContact(draft) }
        case .tasks(let list):
            ForEach(list, id: \.self) { detail("circle", $0) }
            draftFooter("Add \(list.count)", copy: list.map { "- \($0)" }.joined(separator: "\n")) { handlers.addTasks(list) }
        case .writing(nil, _, _, _):
            VStack(spacing: 2) {
                ForEach(Array(model.writingTasks.enumerated()), id: \.element) { index, task in
                    OptionRow(title: task.title, symbol: task.symbol, number: model.numberKeys ? index + 1 : nil) {
                        handlers.chooseWriting(task)
                    }
                }
            }
            // The rows pad their content by their hover fill; pull them out so the icons and titles
            // line up with the header and the footer text while the fill still reaches past them.
            .padding(.horizontal, -OptionRow.inset)
            Text("Runs on this Mac with Apple Intelligence. Nothing is sent anywhere.")
                .font(Typeface.font(11))
                .foregroundStyle(Theme.secondary)
        case .writing(let task?, let text, let done, let error):
            if let error {
                message(error)
                if model.writingNeedsSettings {
                    HStack {
                        Spacer()
                        PillButton(title: "Open Apple Intelligence Settings…", prominent: true, action: handlers.openIntelligenceSettings)
                    }
                }
            } else if done, task == .fixGrammar, ProofDiff.same(model.selectedText, text) {
                message("No mistakes found.")
            } else if text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing on this Mac…").foregroundStyle(Theme.secondary)
                }
                .font(Typeface.font(13))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                let rtl = Translator.detect(text).map(Translator.isRightToLeft) ?? false
                ScrollView {
                    Text(done && task == .fixGrammar ? ProofDiff.marked(from: model.selectedText, to: text) : AttributedString(text))
                        .font(Typeface.font(CardView.resultFontSize))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .defaultScrollAnchor(done ? .top : .bottom)
                .scrollBounceBehavior(.basedOnSize)
                .fadesScrollEdges()
                .frame(height: CardView.resultHeight(text))
                .accessibilityLabel(text)
                if done {
                    footer(copy: text, replace: task.replaces ? text : nil)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Writing…").font(Typeface.font(11)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var readyChoices: some View {
        if let error = model.choicesError {
            message(error)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(model.choices.enumerated()), id: \.element.id) { index, choice in
                    ChoiceRow(choice: choice, number: model.numberKeys && model.choicesDone ? index + 1 : nil,
                              enabled: model.choicesDone) { handlers.choose(choice) }
                }
            }
            .padding(.horizontal, -OptionRow.inset)
            HStack(spacing: 6) {
                if !model.choicesDone { ProgressView().controlSize(.mini) }
                Text(model.choicesDone ? (model.editable ? "Replaces the selected text." : "Copies the one you pick.") : "Writing on this Mac…")
                    .font(Typeface.font(11))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: iconColumn)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(Typeface.font(13))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func draftFooter(_ title: String, copy: String, add: @escaping @MainActor () -> Void) -> some View {
        HStack(spacing: 6) {
            Spacer()
            PillButton(title: "Copy", prominent: false) { handlers.copy(copy) }
            PillButton(title: title, prominent: true, action: add)
        }
    }

    private func when(_ event: EventDraft) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: event.allDay ? .omitted : .shortened)
        return event.allDay ? event.start.formatted(style)
            : "\(event.start.formatted(style)) to \(event.end.formatted(date: .omitted, time: .shortened))"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(Typeface.font(22, .light))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(Typeface.font(11))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func translation(_ outcome: Translator.Outcome) -> some View {
        switch outcome {
        case .translated(let text, _, let target):
            // In a right-to-left environment "leading" is the right edge.
            let rtl = Translator.isRightToLeft(target)
            ScrollView {
                Text(text)
                    .font(Typeface.font(CardView.resultFontSize))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .scrollBounceBehavior(.basedOnSize)
            .fadesScrollEdges()
            .frame(height: CardView.resultHeight(text))
            footer(copy: text, replace: text)
        case .needsDownload(let source, let target):
            message("\(Translator.languageName(source)) to \(Translator.languageName(target)) needs a one-time download. It stays on this Mac.")
            HStack(spacing: 6) {
                Spacer()
                PillButton(title: "Language Settings…", prominent: false, action: handlers.openTranslationSettings)
                PillButton(title: "Download", prominent: true, action: handlers.download)
            }
        case .sameLanguage(let code):
            message("This is already in \(Translator.languageName(code)). Pick another target language in Inkbar Settings.")
            HStack {
                Spacer()
                PillButton(title: "Inkbar Settings…", prominent: true, action: handlers.openInkbarSettings)
            }
        case .unsupported(let source, let target):
            message("Apple Translation cannot translate \(Translator.languageName(source)) to \(Translator.languageName(target)) yet.")
            HStack {
                Spacer()
                PillButton(title: "Inkbar Settings…", prominent: true, action: handlers.openInkbarSettings)
            }
        case .undetected:
            message("Inkbar could not tell which language this is.")
        case .failed(let reason):
            message(reason)
            HStack {
                Spacer()
                PillButton(title: "Language Settings…", prominent: false, action: handlers.openTranslationSettings)
            }
        }
    }

    static let resultFontSize: CGFloat = 14
    static let textWidth: CGFloat = 340 - 28

    /// The text's own height, capped so a long translation scrolls instead of growing off screen.
    static func resultHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth - 4, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Typeface.ns(resultFontSize)])
        return min(ceil(bounds.height) + 4, 220)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Typeface.font(13))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(copy: String, replace: String?) -> some View {
        HStack(spacing: 6) {
            Spacer()
            PillButton(title: "Copy", prominent: !(model.editable && replace != nil)) { handlers.copy(copy) }
            if model.editable, let replace {
                PillButton(title: "Replace", prominent: true) { handlers.replace(replace) }
            }
        }
    }
}

/// One ready answer: its label over the whole text, with its number key.
private struct ChoiceRow: View {
    let choice: ReadyChoice
    let number: Int?
    let enabled: Bool
    let action: @MainActor () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: choice.symbol)
                    .frame(width: iconColumn, height: 18)
                    .foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label)
                        .font(Typeface.font(11))
                        .foregroundStyle(Theme.secondary)
                    Text(choice.text)
                        .font(Typeface.font(13))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let number { NumberBadge(number: number) }
            }
            .padding(.horizontal, OptionRow.inset)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.fill.opacity(hovered ? 1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(choice.label): \(choice.text)")
        .accessibilityHint(number.map { "Shortcut: \($0)." } ?? "")
    }
}

/// One choice in a card list, with its number key.
private struct OptionRow: View {
    /// Horizontal padding between the hover fill and the content.
    static let inset: CGFloat = 8
    let title: String
    let symbol: String
    let number: Int?
    let action: @MainActor () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: iconColumn)
                    .foregroundStyle(Theme.secondary)
                Text(title)
                    .font(Typeface.font(13))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let number { NumberBadge(number: number) }
            }
            .padding(.horizontal, Self.inset)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.fill.opacity(hovered ? 1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(number.map { "Shortcut: \($0)." } ?? "")
    }
}

/// A capsule text button drawn without its own glass, so the card never stacks glass on glass.
/// The one accent button of a surface is the prominent one. Welcome uses it too, on its flat ground.
struct PillButton: View {
    let title: String
    let prominent: Bool
    var height: CGFloat = 26
    var fullWidth = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typeface.font(height > 30 ? 13 : 12, .medium))
                .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .background(Capsule().fill(prominent ? Theme.accent : Theme.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Fades the top and bottom edge of a scroll view while there is more text beyond it, so a result
/// taller than its card reads as scrollable instead of cut off. Nothing fades when it all fits.
private struct ScrollEdgeFade: ViewModifier {
    static let depth: CGFloat = 18
    @State private var moreAbove = false
    @State private var moreBelow = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { g in
                let top = g.contentOffset.y + g.contentInsets.top
                let bottom = g.contentSize.height - (g.contentOffset.y + g.containerSize.height - g.contentInsets.bottom)
                return [top > 1, bottom > 1]
            } action: { _, edges in
                moreAbove = edges[0]
                moreBelow = edges[1]
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(moreAbove ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.depth)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.depth)
                }
            }
            .animation(.easeOut(duration: 0.15), value: moreAbove)
            .animation(.easeOut(duration: 0.15), value: moreBelow)
    }
}

extension View {
    func fadesScrollEdges() -> some View { modifier(ScrollEdgeFade()) }
}
