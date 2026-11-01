@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation
import os

/// What the key tap must know to decide on a key without touching the main actor. The controller
/// copies it here whenever the bar, its card or its settings change; the tap reads the latest copy.
struct KeyGate: Equatable, Sendable {
    var visible = false
    var cardOpen = false
    var feedbackOpen = false
    var numberKeys = false
    var actionCount = 0
    var cardOptionCount = 0
}

/// What a key means to the bar. Decided on the tap's thread, carried out on the main thread.
enum KeyDecision: Equatable, Sendable {
    /// The bar is not showing: not ours.
    case pass
    /// Typing: let it through to the app and close the bar.
    case dismissAndPass
    /// Escape: swallowed, closes the bar and any card.
    case close
    /// A number key for the bar's action at this zero-based index: swallowed.
    case action(Int)
    /// A number key for the open card's choice at this zero-based index: swallowed.
    case cardOption(Int)
    /// A number key with nothing behind it while number keys are live: swallowed, nothing happens.
    case ignore

    var swallows: Bool {
        switch self {
        case .pass, .dismissAndPass: false
        case .close, .action, .cardOption, .ignore: true
        }
    }
}

enum KeyRouting {
    static let escape: Int64 = 53

    /// Pure: the same answer for the same key and gate, on any thread. While the bar is visible, a
    /// digit that maps to an action or a card choice is always swallowed, so it can never be typed
    /// into the document and replace the selection.
    static func decide(keyCode: Int64, modifiers: CGEventFlags, gate: KeyGate) -> KeyDecision {
        guard gate.visible else { return .pass }
        if keyCode == escape { return .close }
        let plain = modifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        if gate.numberKeys, plain, let digit = digit(forKeyCode: keyCode) {
            if !gate.cardOpen, !gate.feedbackOpen, digit <= min(9, gate.actionCount) { return .action(digit - 1) }
            // In a card with choices, number keys pick a choice.
            if gate.cardOpen, digit <= gate.cardOptionCount { return .cardOption(digit - 1) }
            // A digit with no action or choice behind it is swallowed too: while number keys are live
            // it must never be typed over the selection.
            return .ignore
        }
        // Anything else is typing: let it through and get out of the way.
        return .dismissAndPass
    }

    /// Top-row and keypad digits by physical key, independent of layout.
    static func digit(forKeyCode code: Int64) -> Int? {
        let map: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        return map[code]
    }
}

/// The tap itself: the Mach port, its run loop thread and everything the callback touches. It never
/// reads main-actor state, so a busy main thread cannot make the system switch the tap off, and a
/// key is swallowed or passed on the tap's own thread from the gate snapshot alone.
///
/// The thread holds the core until `shutdown()` stops its run loop. The callback's pointer to the
/// core is unretained, which is safe because the thread outlives every callback.
final class KeyTapCore: @unchecked Sendable {
    private struct State {
        var gate = KeyGate()
        var wanted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private(set) var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?

    /// Set once, before `start()`. Each is called on the tap's thread.
    var onDecision: (@Sendable (KeyDecision) -> Void)?
    var onRecovered: (@Sendable () -> Void)?
    var onFailed: (@Sendable () -> Void)?

    var isOn: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var isWanted: Bool { state.withLock { $0.wanted } }
    /// The tap's run loop is not the main run loop.
    var runsOffMainThread: Bool { loop.map { $0 !== CFRunLoopGetMain() } ?? false }

    func setGate(_ gate: KeyGate) { state.withLock { $0.gate = gate } }
    func setWanted(_ wanted: Bool) { state.withLock { $0.wanted = wanted } }

    /// Creates the port, switched off, and the thread whose run loop serves it. False when the
    /// system refuses the tap.
    func start() -> Bool {
        if port != nil { return true }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let core = Unmanaged<KeyTapCore>.fromOpaque(refcon).takeUnretainedValue()
            return core.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CGEvent.tapEnable(tap: port, enable: false)
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        self.port = port
        self.source = source
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let current = CFRunLoopGetCurrent()
            loop = current
            CFRunLoopAddSource(current, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(current, source, .commonModes)
        }
        thread.name = "info.gabrimatic.inkbar.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func setEnabled(_ on: Bool) {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: on)
    }

    /// Switches the tap off for good and lets its thread end.
    func shutdown() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
    }

    /// Runs on the tap's thread. True to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turned the tap off. Turn it on again at once, before anything else.
            guard let port, isWanted else { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            if CGEvent.tapIsEnabled(tap: port) { onRecovered?() } else { onFailed?() }
            return false
        case .keyDown:
            let gate = state.withLock { $0.gate }
            let decision = KeyRouting.decide(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                             modifiers: event.flags, gate: gate)
            if decision != .pass { onDecision?(decision) }
            return decision.swallows
        default:
            return false
        }
    }
}

/// A keyboard event tap that exists only while the bar is visible, so number keys and
/// Escape reach the bar instead of the app, and any other key dismisses it. Disabled the
/// rest of the time: no keyboard event passes through Inkbar while the bar is hidden.
///
/// The tap runs on its own thread. Whether a key is swallowed is decided there from the gate
/// the controller last published with `update(_:)`; only the resulting decision hops to the
/// main thread, so a busy main thread delays the action and never lets a key leak.
@MainActor
final class KeyTap {
    /// Carries out a decision on the main thread.
    var handler: ((KeyDecision) -> Void)?
    /// The tap had been switched off by the system and is on again.
    var onRecovered: (() -> Void)?
    /// The tap was switched off and could not be turned back on.
    var onFailed: (() -> Void)?
    private let core = KeyTapCore()

    /// The tap's port.
    var port: CFMachPort? { core.port }
    /// The tap exists and is switched on.
    var isOn: Bool { core.isOn }
    /// The tap is served by a thread other than the main one.
    var runsOffMainThread: Bool { core.runsOffMainThread }

    init() {
        core.onDecision = { [weak self] decision in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handler?(decision) } }
        }
        core.onRecovered = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onRecovered?() } }
        }
        core.onFailed = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFailed?() } }
        }
    }

    deinit { core.shutdown() }

    /// Publishes what the tap needs to decide on keys. Cheap; call it after every change.
    func update(_ gate: KeyGate) { core.setGate(gate) }

    /// Enables the tap, creating it on first use. Returns false when the system refuses it or it
    /// does not come on.
    func enable() -> Bool {
        guard core.start() else { return false }
        core.setWanted(true)
        core.setEnabled(true)
        return core.isOn
    }

    /// Turns the tap back on if the system switched it off (the callback answers from its own
    /// thread, so this is a backstop for a switch-off that came with no key event to tell us).
    /// Cheap: one flag read.
    func ensureEnabled() {
        guard core.isWanted, core.port != nil, !core.isOn else { return }
        core.setEnabled(true)
        if core.isOn { onRecovered?() } else { onFailed?() }
    }

    func disable() {
        core.setWanted(false)
        core.setEnabled(false)
    }
}
