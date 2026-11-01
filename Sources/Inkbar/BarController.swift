import AppKit
import Darwin
import SwiftUI
import Translation
import os

/// A floating panel that never takes focus from the app the user is working in.
final class FloatingPanel: NSPanel {
    /// Only the translation download prompt needs a key window.
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        // Hide Others, or a hidden launch, must not take this off the screen.
        canHide = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that takes the first click, so a button works while another app is active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the bar and its cards, runs the actions, and dismisses on any outside input.
@MainActor
final class BarController {
    private let log = Logger(subsystem: "info.gabrimatic.inkbar", category: "bar")
    let model = BarModel()
    private let settings: AppSettings
    let panel = FloatingPanel()
    let hintPanel = FloatingPanel()
    private var hosting: FirstClickHostingView<BarRootView>?
    private var hintHosting: NSHostingView<HintView>?
    private let keyTap = KeyTap()
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    /// False when the system refused the key tap for the current bar.
    private var tapActive = true
    private var context: SelectionContext?
    private var hideWork: DispatchWorkItem?
    private var hoverObservation = 0
    /// Bumped on every show, so late async results never land on a newer selection.
    private var session = 0
    /// The buttons for a selection, given what it names when that is known.
    var planActions: (SelectionContext, SelectionTopic?, SelectionReading?) -> [ActionKind] = { _, _, _ in [] }
    private var topicWork: Task<Void, Never>?
    private var writingWork: Task<Void, Never>?
    private var choicesWork: Task<Void, Never>?
    private var settleWork: DispatchWorkItem?
    /// What reading ahead found for the bar on screen.
    private var topic: SelectionTopic?
    private var reading: SelectionReading?
    private var effects = Effects.State()
    /// When the open card replaced the bar: a double-click's second click must not pick a row in it.
    private var cardOpenedAt: CFTimeInterval = 0
    private(set) var isVisible = false
    /// Clear space between the bar's glass and the hover hint's glass, as drawn.
    static let hintGap: CGFloat = 8
    /// Liquid Glass draws its edge highlight half a point outside the layout bounds of its shape, on
    /// every side, so two glass shapes look closer than their layouts say. Each of the two shapes
    /// gives up this much of the gap.
    static let glassRim: CGFloat = 0.5
    /// The gap between the two layout bounds that makes the drawn gap `hintGap`.
    static var hintLayoutGap: CGFloat { hintGap + 2 * glassRim }
    private var placementScreens: [Placement.Screen] { NSScreen.screens.map(Self.placementScreen) }

    init(settings: AppSettings) {
        self.settings = settings
        hintPanel.ignoresMouseEvents = true
        keyTap.handler = { [weak self] decision in self?.apply(decision) }
        keyTap.onRecovered = { [weak self] in
            guard let self else { return }
            self.log.info("key tap had been switched off by the system and is on again")
            if !self.tapActive { self.setTapActive(true) }
        }
        keyTap.onFailed = { [weak self] in
            guard let self else { return }
            self.log.error("key tap was switched off by the system and could not be turned on again")
            self.setTapActive(false)
        }
    }

    static func placementScreen(_ s: NSScreen) -> Placement.Screen {
        Placement.Screen(frame: s.frame, visibleFrame: s.visibleFrame, safeTop: s.safeAreaInsets.top)
    }

    // MARK: Show and hide

    func show(_ context: SelectionContext, actions: [ActionKind]) {
        guard !actions.isEmpty else {
            log.info("no action fits this selection")
            hide(animated: false)
            return
        }
        // The next click of a multi-click replaces the bar in place: the same bar changes its
        // actions and moves, instead of one bar vanishing and another popping up.
        if context.continuesClick, isVisible, model.card == nil, model.feedback == nil {
            replaceInPlace(context, actions: actions)
            return
        }
        log.info("bar shown with \(actions.count, privacy: .public) actions")
        hideWork?.cancel()
        session += 1
        self.context = context
        model.reset()
        model.readDisplayOptions()
        model.actions = actions
        model.editable = context.editable
        model.numberKeys = settings.numberKeys
        model.selectedText = context.text
        model.writingTasks = WritingTask.relevant(for: context.analysis, editable: context.editable)
        effects = Effects.current()
        model.showCount += 1
        installHosting()
        layout()
        // Replace any fade-out still running from the previous selection.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        isVisible = true
        syncKeyGate()
        startDismissWatchers()
        observeHover()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            withAnimation(self.effects.full ? .spring(duration: 0.34, bounce: 0.28) : .easeOut(duration: 0.12)) {
                self.model.appeared = true
            }
        }
        Effects.haptic(.alignment, enabled: settings.haptics)
        Effects.announce(spoken(actions))
        readAhead(context)
    }

    /// Reads the selection on this Mac while the user looks at it, and gets the next step ready. The
    /// bar never waits: buttons slide in at the end of the row, so nothing moves under the pointer,
    /// and the note beside the bar writes itself.
    private func readAhead(_ context: SelectionContext) {
        topicWork?.cancel()
        choicesWork?.cancel()
        topicWork = nil
        topic = TopicReader.known(context.analysis)
        reading = nil
        let a = context.analysis
        guard Intelligence.isAvailable else { return }
        let token = session
        let current = { [weak self] in
            guard let self, !Task.isCancelled else { return false }
            return self.isVisible && self.session == token && self.model.card == nil && self.model.feedback == nil
        }
        topicWork = Task { [weak self] in
            if self?.topic == nil, TopicReader.canRead(a),
               !ActionKind.topicActions.isDisjoint(with: self?.settings.enabledActions ?? []) {
                guard let found = await TopicReader.read(a), current(), let self else { return }
                self.topic = found
                self.refreshActions(context)
            }
            guard let self, self.settings.readAhead, self.topic == nil || self.topic == .other,
                  SelectionReader.canRead(a) else { return }
            let kind = await SelectionReader.kind(of: a)
            guard current() else { return }
            self.log.debug("read ahead: \(kind.rawValue, privacy: .public)")
            switch kind {
            case .event:
                guard let draft = await SelectionReader.event(from: a), current() else { return }
                self.found(.event(draft), context)
            case .contact:
                guard let draft = await SelectionReader.contact(from: a), current() else { return }
                self.found(.contact(draft), context)
            case .tasks:
                let tasks = await SelectionReader.tasks(from: a)
                guard !tasks.isEmpty, current() else { return }
                self.found(.tasks(tasks), context)
            case .message:
                guard !context.editable else { return }
                self.found(.message, context)
                self.prepareChoices(.reply, on: context.text)
            case .passage, .problem, .term:
                await SelectionReader.glance(for: kind, of: a) { text in
                    guard current(), !text.isEmpty else { return }
                    self.model.glance = text
                    // SwiftUI takes the new text on its next pass; size the panel after it.
                    DispatchQueue.main.async { MainActor.assumeIsolated { if current() { self.layout() } } }
                }
                if current(), let line = self.model.glance { Effects.announce(line) }
            case .other:
                break
            }
        }
    }

    private func found(_ reading: SelectionReading, _ context: SelectionContext) {
        self.reading = reading
        refreshActions(context)
    }

    /// Puts the buttons that reading ahead earned into the row.
    private func refreshActions(_ context: SelectionContext) {
        let actions = planActions(context, topic, reading)
        guard actions != model.actions else { return }
        hintPanel.orderOut(nil)
        model.hovered = nil
        withAnimation(effects.full ? .spring(duration: 0.3, bounce: 0.15) : .easeOut(duration: 0.12)) {
            model.actions = actions
        }
        layout(animated: effects.full)
        Effects.announce(spoken(actions))
    }

    private func replaceInPlace(_ context: SelectionContext, actions: [ActionKind]) {
        log.info("bar updated to \(actions.count, privacy: .public) actions")
        hideWork?.cancel()
        session += 1
        self.context = context
        hintPanel.orderOut(nil)
        model.hovered = nil
        model.editable = context.editable
        model.numberKeys = settings.numberKeys && tapActive
        model.selectedText = context.text
        model.writingTasks = WritingTask.relevant(for: context.analysis, editable: context.editable)
        withAnimation(effects.full ? .spring(duration: 0.3, bounce: 0.15) : .easeOut(duration: 0.12)) {
            model.actions = actions
        }
        model.glance = nil
        model.choices = []
        model.choicesDone = false
        model.choicesError = nil
        layout(animated: effects.full)
        Effects.announce(spoken(actions))
        readAhead(context)
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        syncKeyGate()
        stopDismissWatchers()
        hintPanel.orderOut(nil)
        panel.allowsKey = false
        context = nil
        hideWork?.cancel()
        writingWork?.cancel()
        writingWork = nil
        topicWork?.cancel()
        choicesWork?.cancel()
        settleMemory()
        if animated && effects.full {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible else { return }
                    self.panel.orderOut(nil)
                    self.model.reset()
                }
            })
        } else {
            panel.orderOut(nil)
            model.reset()
        }
    }

    /// Once selecting has stopped for a while, hands freed heap back to the system.
    private func settleMemory() {
        settleWork?.cancel()
        let work = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func installHosting() {
        guard hosting == nil else { return }
        let view = FirstClickHostingView(rootView: BarRootView(model: model, handlers: handlers()))
        // The panel is sized by layout() from the view's own size, never by the view; only the
        // intrinsic size is reported (with no options at all, fittingSize is zero).
        view.sizingOptions = [.intrinsicContentSize]
        panel.contentView = view
        hosting = view
    }

    /// Sizes the panel to its content and places it against the selection.
    private func layout(animated: Bool = false) {
        // Every change to the bar, its card or its feedback ends in a layout, so this is where the
        // key tap's view of them is refreshed.
        syncKeyGate()
        keyTap.ensureEnabled()
        guard let hosting, let context else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let pad = BarRootView.padding
        // Place the visible surface; the transparent padding hangs around it.
        let surface = CGSize(width: size.width - pad * 2, height: size.height - pad * 2)
        let frame = Placement.frame(size: surface, anchor: context.anchor, screens: placementScreens)
        model.placedBelow = frame.midY < context.anchor.midY
        let target = frame.insetBy(dx: -pad, dy: -pad)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = effects.full ? 0.3 : 0.12
                ctx.timingFunction = effects.full
                    ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                    : CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: Hover hint

    private func observeHover() {
        hoverObservation += 1
        let token = hoverObservation
        withObservationTracking {
            _ = model.hovered
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.hoverObservation, self.isVisible else { return }
                    self.updateHint()
                    self.observeHover()
                }
            }
        }
    }

    private func updateHint() {
        guard let kind = model.hovered, model.card == nil, model.feedback == nil,
              let index = model.actions.firstIndex(of: kind) else {
            hintPanel.orderOut(nil)
            return
        }
        let view = HintView(text: kind.title, shortcut: model.shortcut(for: kind))
        if let hintHosting {
            hintHosting.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            hintPanel.contentView = h
            hintHosting = h
        }
        guard let hintHosting else { return }
        hintHosting.layoutSubtreeIfNeeded()
        let size = hintHosting.fittingSize
        // Button centre: bar padding + row padding + index * (button width + spacing) + half a button.
        let pad = BarRootView.padding
        // A glance wider than the row leaves the row centred in the panel.
        let rowWidth = 8 + CGFloat(model.actions.count) * 34 - 2
        let rowInset = max(0, (panel.frame.width - pad * 2 - rowWidth) / 2)
        let buttonX = panel.frame.minX + pad + rowInset + 4 + CGFloat(index) * 34 + 16
        let barTop = panel.frame.maxY - pad
        let barBottom = panel.frame.minY + pad
        // The hint's own 6 pt of padding is transparent: these offsets leave `hintGap` of clear space between
        // the two glass shapes as drawn (rims included), so they never crowd or fuse.
        let gap = Self.hintLayoutGap - HintView.padding
        var origin = CGPoint(x: buttonX - size.width / 2, y: model.placedBelow ? barBottom - size.height - gap : barTop + gap)
        if let screen = Placement.screen(for: panel.frame, in: placementScreens) {
            let area = Placement.usable(screen)
            if origin.y + size.height > area.maxY + HintView.padding { origin.y = barBottom - size.height - gap }
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        }
        hintPanel.setFrame(CGRect(origin: origin, size: size), display: true)
        hintPanel.orderFrontRegardless()
    }

    // MARK: Dismissal

    private func startDismissWatchers() {
        removeMonitors()
        syncKeyGate()
        tapActive = keyTap.enable()
        if !tapActive {
            // No tap (should not happen with Accessibility granted): typing still dismisses,
            // but number keys stay off, and their hints with them, so the bar never promises
            // keys that would be typed into the document instead.
            model.numberKeys = false
        }
        syncKeyGate()
        // The tap is the only thing that can swallow a key. It runs on its own thread and decides
        // from a snapshot, so a busy main thread cannot make the system switch it off; should that
        // happen anyway (the system also does it for other reasons), keys sent meanwhile pass it by.
        // This monitor still sees them, so Esc and typing close the bar even then. A key the tap
        // swallowed never reaches it.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let phase = event.phase
            let momentum = event.momentumPhase
            MainActor.assumeIsolated { self?.scrolled(phase: phase, momentumPhase: momentum) }
        }
    }

    /// A scroll anywhere dismisses the bar, except momentum left over from a fling that began
    /// before it appeared.
    func scrolled(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        if Effects.scrollDismisses(phase: phase, momentumPhase: momentumPhase) { hide() }
    }

    private func stopDismissWatchers() {
        keyTap.disable()
        removeMonitors()
    }

    private func removeMonitors() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        scrollMonitor = nil
        keyMonitor = nil
    }

    /// The live state, as the key tap's thread needs it.
    private func currentKeyGate() -> KeyGate {
        KeyGate(visible: isVisible, cardOpen: model.card != nil, feedbackOpen: model.feedback != nil,
                numberKeys: model.numberKeys, actionCount: model.actions.count, cardOptionCount: model.cardOptionCount)
    }

    private func syncKeyGate() { keyTap.update(currentKeyGate()) }

    /// The key tap could not be kept on, or is on again: number keys and their hints follow it,
    /// so the bar never shows keys that would leak into the document.
    private func setTapActive(_ active: Bool) {
        tapActive = active
        model.numberKeys = active && settings.numberKeys
        syncKeyGate()
    }

    /// The same decision the key tap makes, for one event, in the caller's thread. Returns true to
    /// swallow the key. The tap itself decides on its own thread.
    func handleKey(_ event: CGEvent) -> Bool {
        let decision = KeyRouting.decide(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                         modifiers: event.flags, gate: currentKeyGate())
        if decision != .pass { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.apply(decision) } } }
        return decision.swallows
    }

    /// Carries out what the key tap decided, on the main thread. The key itself is already swallowed
    /// or passed; the state may have moved on since, so each case checks it again.
    private func apply(_ decision: KeyDecision) {
        guard isVisible else { return }
        switch decision {
        case .pass:
            break
        case .close:
            hide()
        case .dismissAndPass:
            hide(animated: false)
        case .action(let index):
            guard model.card == nil, model.feedback == nil, model.actions.indices.contains(index) else { return }
            perform(model.actions[index])
        case .cardOption(let index):
            guard model.card != nil, index < model.cardOptionCount else { return }
            pickCardOption(index)
        case .ignore:
            break
        }
    }

    /// What VoiceOver says when the bar appears. Numbers only when the keys really work.
    private func spoken(_ actions: [ActionKind]) -> String {
        let names = actions.prefix(9).enumerated().map { model.numberKeys ? "\($0.offset + 1) \($0.element.title)" : $0.element.title }
        return "Inkbar: \(names.joined(separator: ", ")). Escape closes."
    }

    /// Top-row and keypad digits by physical key, independent of layout.
    static func digit(forKeyCode code: Int64) -> Int? { KeyRouting.digit(forKeyCode: code) }

    // MARK: Actions

    /// The bar's own buttons, and the buttons and rows of its cards. A click on a card is ignored for
    /// one double-click interval after the card replaced the bar: a double-click on a bar button
    /// would otherwise land its second click on whichever row appeared under the pointer.
    func handlers() -> BarHandlers {
        var h = BarHandlers()
        h.perform = { [weak self] kind in self?.perform(kind) }
        h.copy = { [weak self] text in
            self?.cardClick { me in
                Clipboard.copy(text)
                me.flash("Copied")
            }
        }
        h.replace = { [weak self] text in self?.cardClick { $0.replace(with: text) } }
        h.applyCase = { [weak self] c in self?.cardClick { $0.applyCase(c) } }
        h.close = { [weak self] in self?.cardClick { $0.hide() } }
        h.download = { [weak self] in self?.cardClick { $0.startDownload() } }
        h.translated = { [weak self] outcome in
            guard let self, self.isVisible else { return }
            self.panel.allowsKey = false
            self.model.translationConfig = nil
            self.showCard(.translation(outcome))
        }
        h.chooseWriting = { [weak self] task in self?.cardClick { $0.write(task) } }
        h.choose = { [weak self] choice in self?.cardClick { $0.useChoice(choice) } }
        h.addEvent = { [weak self] draft in self?.cardClick { $0.handOff(Handoff.addEvent(draft), "Sent to Calendar") } }
        h.addContact = { [weak self] draft in self?.cardClick { $0.handOff(Handoff.addContact(draft), "Sent to Contacts") } }
        h.addTasks = { [weak self] tasks in
            self?.cardClick { me in
                Task { @MainActor [weak me] in
                    let added = await Handoff.addReminders(tasks)
                    if !added, !Handoff.remindersAllowed {
                        me?.flash("Allow Reminders in Inkbar Settings", error: true)
                    } else {
                        me?.handOff(added, "Added to Reminders")
                    }
                }
            }
        }
        h.openIntelligenceSettings = { [weak self] in
            self?.cardClick { me in
                Self.openIntelligenceSettings()
                me.hide()
            }
        }
        h.openTranslationSettings = { [weak self] in
            self?.cardClick { me in
                Self.openTranslationSettings()
                me.hide()
            }
        }
        h.openInkbarSettings = { [weak self] in
            self?.cardClick { me in
                SettingsWindowController.shared.show(pane: .general)
                me.hide()
            }
        }
        return h
    }

    /// Runs a card button's action unless the card only just opened.
    private func cardClick(_ body: (BarController) -> Void) {
        guard isVisible else { return }
        guard CACurrentMediaTime() - cardOpenedAt >= NSEvent.doubleClickInterval else {
            log.debug("ignored a click that landed as the card opened")
            return
        }
        body(self)
    }

    func perform(_ kind: ActionKind) {
        guard isVisible, let context else { return }
        let a = context.analysis
        log.debug("action \(kind.rawValue, privacy: .public)")
        Effects.haptic(.generic, enabled: settings.haptics)
        switch kind {
        case .copy:
            Clipboard.copy(context.text)
            flash("Copied")
        case .cleanCopy:
            Clipboard.copy(TextCleaner.clean(context.text))
            flash("Copied clean")
        case .pasteClean:
            guard let clip = Clipboard.plainText() else { flash("Clipboard has no text", error: true); return }
            let element = context.element
            hide(animated: false)
            TextInserter.insert(TextCleaner.clean(clip), into: element)
        case .search: open(Links.search(a.trimmed, engine: settings.engine))
        case .letterboxd: open(Links.letterboxd(a.trimmed))
        case .imdb: open(Links.imdb(a.trimmed))
        case .openURL: open(a.url.map { Links.upgraded(URL(string: TextCleaner.cleanURL($0.absoluteString)) ?? $0) })
        case .email: open(a.email.flatMap(Links.mail))
        case .call: open(a.phone.flatMap(Links.call))
        case .maps: open(Links.maps(a.address ?? a.trimmed))
        case .shop: open(Links.shop(a.trimmed))
        case .amazon: open(Links.amazon(a.trimmed))
        case .wikipedia: open(Links.wikipedia(a.trimmed))
        case .goodreads: open(Links.goodreads(a.trimmed))
        case .appleMusic: open(Links.appleMusic(a.trimmed))
        case .define: open(Links.define(a.trimmed))
        case .calculate:
            guard let value = a.mathResult else { return }
            showCard(.calculation(expression: a.trimmed, result: MathEvaluator.format(value)))
        case .count:
            showCard(.count(words: a.wordCount, characters: a.characterCount, lines: max(1, a.lineCount)))
        case .changeCase:
            showCard(.changeCase)
        case .addEvent:
            if case .event(let draft)? = reading { showCard(.event(draft)) }
        case .addContact:
            if case .contact(let draft)? = reading { showCard(.contact(draft)) }
        case .addTasks:
            if case .tasks(let list)? = reading { showCard(.tasks(list)) }
        case .replies:
            showChoices(.reply)
        case .intelligence:
            if model.writingTasks.count == 1, let only = model.writingTasks.first {
                write(only)
            } else {
                showCard(.writing(task: nil, text: "", done: false, error: nil))
            }
        case .translate:
            translate(context.text)
        }
    }

    private func open(_ url: URL?) {
        if Links.open(url) {
            hide()
        } else {
            flash(url == nil ? "Could not make a link from this" : "No app can open this link", error: true)
        }
    }

    private func replace(with text: String) {
        guard let context, context.editable else { return }
        let element = context.element
        hide(animated: false)
        // After the download prompt Inkbar was active; give focus back before pasting.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != context.pid,
           let app = NSRunningApplication(processIdentifier: context.pid) {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { TextInserter.insert(text, into: element) }
            }
            return
        }
        TextInserter.insert(text, into: element)
    }

    private func applyCase(_ c: TextAnalysis.Case) {
        guard let context else { return }
        let result = TextAnalysis.transform(context.text, to: c)
        if context.editable {
            replace(with: result)
        } else {
            Clipboard.copy(result)
            flash("Copied")
        }
    }

    private func flash(_ text: String, error: Bool = false) {
        model.card = nil
        withAnimation(.easeOut(duration: 0.15)) {
            model.feedback = text
            model.feedbackIsError = error
        }
        hintPanel.orderOut(nil)
        layout(animated: true)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 1.6 : 0.7), execute: work)
    }

    private func showCard(_ card: BarModel.Card) {
        hintPanel.orderOut(nil)
        model.hovered = nil
        // A card taller than the bar may need the other side of the selection. The panel's frame
        // moves with the content, on the same clock, so nothing ever jumps.
        let opening = model.card == nil
        if opening { cardOpenedAt = CACurrentMediaTime() }
        withAnimation(effects.full ? .spring(duration: 0.3, bounce: 0.15) : .easeOut(duration: 0.12)) {
            model.card = card
        }
        layout(animated: true)
    }

    private func pickCardOption(_ index: Int) {
        switch model.card {
        case .changeCase?:
            applyCase(TextAnalysis.Case.allCases[index])
        case .writing(nil, _, _, _)?:
            write(model.writingTasks[index])
        case .choices?:
            guard model.choices.indices.contains(index) else { return }
            useChoice(model.choices[index])
        default:
            break
        }
    }

    // MARK: Apple Intelligence

    /// Streams the on-device model's answer into the card, resizing as it grows.
    private func write(_ task: WritingTask) {
        guard isVisible, let context else { return }
        Effects.haptic(.generic, enabled: settings.haptics)
        if task == .reply || task == .rewrite {
            showChoices(task)
            return
        }
        guard Intelligence.isAvailable else {
            model.writingNeedsSettings = Intelligence.status == .notEnabled
            showCard(.writing(task: task, text: "", done: true, error: Intelligence.statusMessage))
            return
        }
        showCard(.writing(task: task, text: "", done: false, error: nil))
        let token = session
        let text = context.text
        writingWork?.cancel()
        writingWork = Task { [weak self] in
            do {
                let result = try await Intelligence.run(task, on: text) { partial in
                    guard let self, self.isVisible, self.session == token else { return }
                    self.model.card = .writing(task: task, text: partial, done: false, error: nil)
                    self.layout(animated: true)
                }
                guard let self, self.isVisible, self.session == token else { return }
                self.model.card = .writing(task: task, text: result, done: true,
                                           error: result.isEmpty ? "Apple Intelligence returned nothing. Try again." : nil)
                self.layout(animated: true)
                Effects.announce("\(task.title) ready.")
            } catch {
                guard let self, self.isVisible, self.session == token, !(error is CancellationError) else { return }
                self.model.card = .writing(task: task, text: "", done: true, error: Intelligence.message(for: error))
                self.layout(animated: true)
            }
        }
    }

    /// Opens the three-answer card. Replies read ahead may be there already.
    private func showChoices(_ task: WritingTask) {
        guard let context else { return }
        guard Intelligence.isAvailable else {
            model.writingNeedsSettings = Intelligence.status == .notEnabled
            showCard(.writing(task: task, text: "", done: true, error: Intelligence.statusMessage))
            return
        }
        if task == .rewrite || model.choices.isEmpty && !model.choicesDone { prepareChoices(task, on: context.text) }
        showCard(.choices(task))
    }

    private func prepareChoices(_ task: WritingTask, on text: String) {
        let token = session
        choicesWork?.cancel()
        model.choices = []
        model.choicesDone = false
        model.choicesError = nil
        choicesWork = Task { [weak self] in
            do {
                try await SelectionReader.stream(task, on: text) { list in
                    guard let self, self.isVisible, self.session == token else { return }
                    self.model.choices = list
                    if self.model.card != nil { self.layout(animated: true) }
                }
                guard let self, self.isVisible, self.session == token else { return }
                self.model.choicesDone = true
                if self.model.choices.isEmpty { self.model.choicesError = "Apple Intelligence returned nothing. Try again." }
                if self.model.card != nil { self.layout(animated: true) }
                Effects.announce("\(task.title) ready.")
            } catch {
                guard let self, self.isVisible, self.session == token, !(error is CancellationError) else { return }
                self.model.choicesDone = true
                self.model.choicesError = Intelligence.message(for: error)
                if self.model.card != nil { self.layout(animated: true) }
            }
        }
    }

    /// A ready answer stands in for the selection where it can, and goes on the clipboard otherwise.
    private func useChoice(_ choice: ReadyChoice) {
        if model.editable {
            replace(with: choice.text)
        } else {
            Clipboard.copy(choice.text)
            flash("Copied")
        }
    }

    private func handOff(_ succeeded: Bool, _ done: String) {
        succeeded ? flash(done) : flash("Could not hand that over", error: true)
    }

    // MARK: Translation

    private func translate(_ text: String) {
        let target = settings.effectiveTarget
        showCard(.translation(nil))
        let token = session
        Task { [weak self] in
            let outcome = await Translator.translate(text, to: target)
            guard let self, self.isVisible, self.session == token,
                  self.model.card == .translation(nil) else { return }
            if case .needsDownload(let source, let target) = outcome {
                self.model.translationSource = source
                self.model.translationTarget = target
            }
            self.showCard(.translation(outcome))
        }
    }

    /// The user asked to download: SwiftUI's translationTask shows the system prompt,
    /// which needs Inkbar active and the card able to become key, for this step only.
    private func startDownload() {
        guard isVisible, !model.translationSource.isEmpty else { return }
        panel.allowsKey = true
        NSApp.activate()
        panel.makeKey()
        showCard(.translation(nil))
        model.translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: model.translationSource),
            target: Locale.Language(identifier: model.translationTarget))
    }

    static func openIntelligenceSettings() {
        // Apple Intelligence & Siri.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openTranslationSettings() {
        // Language & Region, where Translation Languages lives.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
