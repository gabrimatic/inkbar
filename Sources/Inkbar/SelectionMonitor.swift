import AppKit
import ApplicationServices
import Carbon
import os

/// One selection, ready for the bar.
struct SelectionContext {
    let text: String
    let analysis: TextAnalysis
    let pid: pid_t
    let bundleID: String?
    /// The field the text came from, for Replace and Paste Clean. Nil after the copy fallback
    /// when the app exposes nothing.
    let element: AXUIElement?
    let editable: Bool
    /// Where the bar points at, in Cocoa coordinates.
    let anchor: CGRect
    /// Part of a multi-click: the bar that the earlier click of the chain opened is still up, and
    /// this selection replaces it in place instead of popping a second bar.
    var continuesClick = false
}

/// Watches for finished selections in the frontmost app, event-driven only: an
/// Accessibility observer on that app plus global mouse monitors. Nothing polls.
@MainActor
final class SelectionMonitor {
    enum Gesture {
        case mouse(down: CGPoint, up: CGPoint, modifiers: NSEvent.ModifierFlags)
        case keyboard(modifiers: NSEvent.ModifierFlags)
    }

    private let log = Logger(subsystem: "info.gabrimatic.inkbar", category: "selection")
    private let settings: AppSettings
    /// Called with a selection to show.
    var onSelection: ((SelectionContext) -> Void)?
    var onDismiss: (() -> Void)?
    /// True while the bar is visible, so a click elsewhere dismisses it.
    var isShowing: () -> Bool = { false }

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var mouseMonitor: Any?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var downPoint: CGPoint = .zero
    private var generation = 0
    private var keyboardWork: DispatchWorkItem?
    /// A third click began while the double-click's bar was up. The bar stays until the line it
    /// selects arrives (and replaces it in place) or turns out to show nothing.
    private var holdingBar = false
    /// A mouse selection still waiting for its app to publish the selection.
    private struct Pending {
        let gesture: Gesture
        let generation: Int
        /// Index of the attempt the next timer will run.
        var next: Int
        let startedAt: Date
    }
    private var pending: Pending?
    /// Sources of truth, replaceable.
    var readSelection: (pid_t) -> AXText.Read = { AXText.read(pid: $0) }
    var frontmost: () -> (pid: pid_t, bundleID: String?)? = {
        NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
    }
    /// The app that owns the window under a point, in Cocoa coordinates. A click can land in an
    /// app that never became the frontmost one (a non-activating panel, a window the click did
    /// not bring forward); the selection belongs to that app, not to whatever is in front.
    var appUnderPoint: (CGPoint) -> (pid: pid_t, bundleID: String?)? = { SelectionMonitor.appAt($0) }
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var secureInputOn: () -> Bool = { IsSecureEventInputEnabled() }
    /// The app that last came forward, whether or not an observer could be attached to it.
    private var frontPID: pid_t = 0
    var deliveries = 0
    private(set) var running = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let electronApps = NSCache<NSString, NSNumber>()

    /// Mouse travel that counts as a drag, in points.
    static let dragThreshold: CGFloat = 4
    /// Wait after mouse-up so the app has updated its selection.
    static let mouseSettle: TimeInterval = 0.06
    /// Gaps between further reads when the app has not published the selection yet (about
    /// 1.1 s in all). An AX selection notification cuts the wait short.
    static let retryGaps: [TimeInterval] = [0.1, 0.18, 0.3, 0.5]
    /// An app that comes forward this soon after a selection was released is the app the
    /// click went to, not an app switch.
    static let activationGrace: TimeInterval = 0.5
    /// Wait after the last keyboard selection change.
    static let keyboardSettle: TimeInterval = 0.35

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { self?.frontmostChanged(pid: pid) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid == self.observedPID else { return }
                self.detach()
                self.cancelPending()
                self.onDismiss?()
            }
        })
        // Displays added, removed or rearranged mid-show: the anchor may now be somewhere else.
        workspaceTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelPending()
                self?.onDismiss?()
            }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelPending()
                    self?.onDismiss?()
                }
            })
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            let clicks = event.clickCount
            let modifiers = event.modifierFlags
            MainActor.assumeIsolated { self?.mouse(type: type, at: location, clicks: clicks, modifiers: modifiers) }
        }
        frontmostChanged(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        guard running else { return }
        running = false
        frontPID = 0
        cancelPending()
        detach()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        // Tokens come from the workspace centre and the default one; removing from the wrong one is a no-op.
        workspaceTokens.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        workspaceTokens.removeAll()
    }

    private func cancelPending() {
        holdingBar = false
        generation += 1
        pending = nil
        keyboardWork?.cancel()
        keyboardWork = nil
    }

    // MARK: Frontmost app

    func frontmostChanged(pid: pid_t?) {
        // Inkbar itself becomes active only for Settings or the translation download
        // prompt; the bar and the observed app stay as they are.
        guard pid != ownPID else { return }
        // The app we already watch coming forward again changes nothing. Cancelling here would
        // drop a selection that was just released in a window the click had to activate first.
        if let pid, pid == frontPID { return }
        // A click into another app's inactive window activates it a moment after the mouse-up.
        // That selection belongs to the new app: read it there instead of dropping it.
        frontPID = pid ?? 0
        var replay: Gesture?
        if let p = pending, Date().timeIntervalSince(p.startedAt) < Self.activationGrace { replay = p.gesture }
        cancelPending()
        onDismiss?()
        detach()
        guard let pid else { return }
        attach(pid: pid)
        if let replay { schedule(replay, after: Self.mouseSettle) }
    }

    private func attach(pid: pid_t) {
        detach()
        if Self.isElectron(pid: pid) { AXText.enableManualAccessibility(pid: pid) }
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<SelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.selectionChanged() }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else {
            log.info("no AX observer for pid \(pid, privacy: .public)")
            return
        }
        let app = AXText.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(newObserver, app, kAXSelectedTextChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedPID = pid
        if result != .success {
            log.info("selection notifications unavailable for pid \(pid, privacy: .public): \(result.rawValue, privacy: .public)")
        }
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    private static func isElectron(pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let key = url.path as NSString
        if let cached = electronApps.object(forKey: key) { return cached.boolValue }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let result = FileManager.default.fileExists(atPath: framework.path)
        electronApps.setObject(NSNumber(value: result), forKey: key)
        return result
    }

    // MARK: Gestures

    func mouse(type: NSEvent.EventType, at point: CGPoint, clicks: Int, modifiers: NSEvent.ModifierFlags) {
        switch type {
        case .leftMouseDown:
            cancelPending()
            downPoint = point
            if isShowing() {
                // Click three of a triple-click: keep the double-click's bar, the line's bar replaces it.
                if clicks >= 3 { holdingBar = true } else { onDismiss?() }
            }
        case .leftMouseUp:
            let distance = hypot(point.x - downPoint.x, point.y - downPoint.y)
            let isSelection = distance >= Self.dragThreshold || clicks >= 2 || (clicks == 1 && modifiers.contains(.shift))
            guard isSelection else { return }
            schedule(.mouse(down: downPoint, up: point, modifiers: modifiers), after: Self.mouseSettle)
        default:
            cancelPending()
            if isShowing() { onDismiss?() }
        }
    }

    /// AX says the selection changed. Mouse selections are handled at mouse-up; this path
    /// catches keyboard selections (Shift with arrows), debounced until the keys rest.
    func selectionChanged() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        // A mouse selection is waiting for exactly this: read it now instead of at the next timer.
        if let p = pending {
            evaluate(p.gesture, generation: p.generation, attempt: p.next, fromNotification: true)
            return
        }
        let modifiers = NSEvent.modifierFlags
        // Other changes (typing, Cmd+A, an app settling after a click) are ignored: any key
        // already dismisses the bar through the key tap, and a late notification after a
        // mouse selection must not close the bar it just opened.
        guard modifiers.contains(.shift) else { return }
        if isShowing() { onDismiss?() }
        keyboardWork?.cancel()
        generation += 1
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.evaluate(.keyboard(modifiers: NSEvent.modifierFlags.union(modifiers)), generation: gen)
            }
        }
        keyboardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyboardSettle, execute: work)
    }

    private func schedule(_ gesture: Gesture, after delay: TimeInterval) {
        generation += 1
        let gen = generation
        pending = Pending(gesture: gesture, generation: gen, next: 0, startedAt: Date())
        arm(generation: gen, attempt: 0, after: delay)
    }

    /// Runs attempt `attempt` after `delay`, unless something newer happened or a
    /// notification already ran it.
    private func arm(generation gen: Int, attempt: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, let p = self.pending, p.generation == gen, p.next == attempt else { return }
                self.evaluate(p.gesture, generation: gen, attempt: attempt, fromNotification: false)
            }
        }
    }

    // MARK: Decision

    /// Every reason not to show, checked before any text is read. Nil means go ahead.
    static func skipReason(paused: Bool, trusted: Bool, secureInput: Bool, isOwnApp: Bool,
                           rule: AppRule?, trigger: TriggerMode, modifierHeld: Bool) -> String? {
        if paused { return "paused" }
        if !trusted { return "no Accessibility access" }
        if secureInput { return "secure input is on" }
        if isOwnApp { return "own app" }
        if rule == .never { return "app rule: never" }
        if (rule == .modifierOnly || trigger == .modifier) && !modifierHeld { return "trigger key not held" }
        return nil
    }

    static func shouldConsider(paused: Bool, trusted: Bool, secureInput: Bool, isOwnApp: Bool,
                               rule: AppRule?, trigger: TriggerMode, modifierHeld: Bool) -> Bool {
        skipReason(paused: paused, trusted: trusted, secureInput: secureInput, isOwnApp: isOwnApp, rule: rule,
                   trigger: trigger, modifierHeld: modifierHeld) == nil
    }

    /// Reads the selection for one gesture and shows the bar, or waits for the app to publish
    /// it: a drag can end before the app has updated its selection, so an empty read after a
    /// mouse selection is retried a few times (and at once when Accessibility says the
    /// selection changed) instead of being taken as "nothing selected".
    private func evaluate(_ gesture: Gesture, generation gen: Int, attempt: Int = 0, fromNotification: Bool = false) {
        guard gen == generation else { return }
        guard let app = target(for: gesture) else { stopWaiting(gen, "no frontmost app"); return }
        let pid = app.pid
        let modifiers: NSEvent.ModifierFlags
        switch gesture {
        case .mouse(_, _, let m): modifiers = m
        case .keyboard(let m): modifiers = m
        }
        let skip = Self.skipReason(paused: settings.isPaused, trusted: isTrusted(), secureInput: secureInputOn(),
                                   isOwnApp: pid == ownPID, rule: settings.rule(for: app.bundleID),
                                   trigger: settings.trigger, modifierHeld: modifiers.contains(settings.triggerKey.flag))
        if let skip { stopWaiting(gen, skip); return }
        if pid != observedPID { attach(pid: pid) }

        let read = readSelection(pid)
        switch read {
        case .selection(let selection):
            stopWaiting(gen, "shown after \(attempt + 1) read(s)", shown: true)
            deliver(text: selection.text, pid: pid, bundleID: app.bundleID, element: selection.element,
                    editable: selection.editable, axBounds: selection.bounds, gesture: gesture)
        case .blocked:
            stopWaiting(gen, "password field")
        case .empty, .noFocus, .busy:
            // A notification-driven read that finds nothing leaves the timers to carry on.
            if fromNotification { return }
            guard case .mouse = gesture, attempt < Self.retryGaps.count else {
                if case .busy = read {
                    stopWaiting(gen, "app did not answer after \(attempt + 1) read(s)")
                } else {
                    stopWaiting(gen, "nothing selected after \(attempt + 1) read(s)")
                }
                return
            }
            pending?.next = attempt + 1
            arm(generation: gen, attempt: attempt + 1, after: Self.retryGaps[attempt])
        case .opaque:
            stopWaiting(gen, "app does not expose its selection")
            // No text from Accessibility. Only a real mouse selection may fall back to Cmd+C.
            guard settings.copyFallback, case .mouse(let down, _, _) = gesture,
                  app.bundleID != "com.apple.finder" else { return }
            // Cmd+C goes to the frontmost app: never send it while the selection is in another one.
            guard frontmost()?.pid == pid else {
                log.info("copy fallback skipped: the selection's app is not in front")
                return
            }
            let focused = AXText.focusedElement(pid: pid)
            let hit = Self.element(at: down)
            guard Self.fallbackAllowed(secureInput: IsSecureEventInputEnabled(),
                                       focus: focused.flatMap(AXText.roles), hit: hit.flatMap(AXText.roles),
                                       hitAncestors: hit.map { AXText.ancestorRoles(of: $0) } ?? []) else {
                log.info("copy fallback refused")
                return
            }
            let editable = focused.map(AXText.isEditable) ?? false
            CopyFallback.read { [weak self] text in
                guard let self, gen == self.generation, let text,
                      self.frontmost()?.pid == pid else { return }
                self.deliver(text: text, pid: pid, bundleID: app.bundleID, element: editable ? focused : nil,
                             editable: editable, axBounds: nil, gesture: gesture)
            }
        }
    }

    /// The app a gesture belongs to: for a mouse selection the app under the pointer where the
    /// drag began (the selection starts there), otherwise, or when that cannot be told, the
    /// frontmost app. Inkbar's own windows never count as the target.
    private func target(for gesture: Gesture) -> (pid: pid_t, bundleID: String?)? {
        if case .mouse(let down, _, _) = gesture, let hit = appUnderPoint(down), hit.pid != ownPID {
            return hit
        }
        return frontmost()
    }

    /// The regular or accessory app owning the element at a Cocoa point, via Accessibility.
    private static func appAt(_ point: CGPoint) -> (pid: pid_t, bundleID: String?)? {
        guard let hit = element(at: point) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited else { return nil }
        return (pid, app.bundleIdentifier)
    }

    /// Ends the wait for this gesture and says why, without any selected text.
    private func stopWaiting(_ gen: Int, _ reason: String, shown: Bool = false) {
        if pending?.generation == gen { pending = nil }
        log.info("selection ended: \(reason, privacy: .public)")
        releaseHeldBar(unless: shown)
    }

    /// The bar kept for a triple-click goes when the new selection will not replace it.
    private func releaseHeldBar(unless shown: Bool = false) {
        guard holdingBar, !shown else { return }
        holdingBar = false
        onDismiss?()
    }

    /// Shows the bar for whatever is selected in the frontmost app right now, as asked from
    /// Shortcuts, Siri or Spotlight. Same safety rules, no gesture or key needed.
    @discardableResult
    func presentCurrentSelection() -> Bool {
        guard !settings.paused, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID,
              settings.rule(for: app.bundleIdentifier) != .never,
              let selection = AXText.selection(pid: app.processIdentifier) else { return false }
        cancelPending()
        deliver(text: selection.text, pid: app.processIdentifier, bundleID: app.bundleIdentifier, element: selection.element,
                editable: selection.editable, axBounds: selection.bounds, gesture: .keyboard(modifiers: []))
        return true
    }

    /// Drags that start on controls, window chrome or file lists are not text selections.
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXScrollBar", "AXSlider",
        "AXSplitter", "AXToolbar", "AXWindow", "AXMenuBar", "AXMenuBarItem", "AXImage", "AXRow", "AXCell",
        "AXOutline", "AXList", "AXTable", "AXDockItem", "AXTabGroup", "AXDisclosureTriangle", "AXIncrementor",
        "AXColorWell", "AXValueIndicator", "AXHandle", "AXSecureTextField",
    ]

    /// Roles that positively identify text.
    static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea"]

    /// Containers a drag can start in without selecting text: lists, tables, outlines, toolbars
    /// and controls. A text label inside one is still not a text selection.
    static let listContainerRoles: Set<String> = [
        "AXRow", "AXCell", "AXTable", "AXOutline", "AXList", "AXBrowser", "AXToolbar", "AXTabGroup",
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuBar", "AXMenuItem", "AXSegmentedControl",
        "AXScrollBar", "AXSlider", "AXRadioGroup", "AXGrid", "AXSourceList", "?",
    ]

    /// True when walking up from the element under the drag (nearest parent first) reaches
    /// text content before any list or control. Web content and text views end the walk with a yes.
    static func insideTextContent(ancestors: [String]) -> Bool {
        for role in ancestors {
            if role == "AXWebArea" || role == "AXTextArea" || role == "AXTextField" { return true }
            if listContainerRoles.contains(role) { return false }
        }
        return true
    }

    /// The Cmd+C fallback fails closed. It runs only when secure input is off, both the focused
    /// element and the element under the drag start can be read, neither is a password field,
    /// the drag did not start on a control, and at least one of them is positively text.
    static func fallbackAllowed(secureInput: Bool, focus: (role: String, subrole: String)?,
                                hit: (role: String, subrole: String)?, hitAncestors: [String] = []) -> Bool {
        guard !secureInput, let focus, let hit, insideTextContent(ancestors: hitAncestors) else { return false }
        func secure(_ r: (role: String, subrole: String)) -> Bool {
            r.role == "AXSecureTextField" || r.subrole == kAXSecureTextFieldSubrole
        }
        guard !secure(focus), !secure(hit), !nonTextRoles.contains(hit.role) else { return false }
        return textRoles.contains(focus.role) || textRoles.contains(hit.role)
    }

    /// The element under a point, or nil when Accessibility reports nothing.
    private static func element(at cocoaPoint: CGPoint) -> AXUIElement? {
        guard let primary = NSScreen.screens.first else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, AXText.timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(cocoaPoint.x), Float(primary.frame.height - cocoaPoint.y), &hit) == .success else { return nil }
        return hit
    }

    private func deliver(text: String, pid: pid_t, bundleID: String?, element: AXUIElement?, editable: Bool,
                         axBounds: CGRect?, gesture: Gesture) {
        let analysis = TextAnalysis(text)
        let continues = holdingBar
        holdingBar = false
        guard !analysis.isBlank else {
            if continues { onDismiss?() }
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let anchor = Self.anchor(axBounds: axBounds, gesture: gesture, primaryHeight: primaryHeight,
                                 screens: NSScreen.screens.map(\.frame))
        log.debug("selection: \(analysis.characterCount, privacy: .public) chars in \(bundleID ?? "?", privacy: .public)")
        onSelection?(SelectionContext(text: text, analysis: analysis, pid: pid, bundleID: bundleID, element: element,
                                      editable: editable, anchor: anchor, continuesClick: continues))
    }

    /// The rect the bar points at: the selection bounds when the app reports sane ones,
    /// otherwise a small box at the pointer.
    static func anchor(axBounds: CGRect?, gesture: Gesture, primaryHeight: CGFloat, screens: [CGRect]) -> CGRect {
        if let axBounds {
            let rect = Placement.cocoaRect(fromAX: axBounds, primaryHeight: primaryHeight)
            let visible = screens.contains { $0.intersects(rect) }
            if visible, rect.height <= 240 {
                // A selection reported wider than the pointer can reach still anchors near the pointer.
                if case .mouse(_, let up, _) = gesture, rect.width > 900 {
                    return CGRect(x: up.x - 1, y: rect.minY, width: 2, height: rect.height)
                }
                return rect
            }
        }
        let point: CGPoint
        switch gesture {
        case .mouse(_, let up, _): point = up
        case .keyboard: point = NSEvent.mouseLocation
        }
        return CGRect(x: point.x - 1, y: point.y - 10, width: 2, height: 20)
    }
}
