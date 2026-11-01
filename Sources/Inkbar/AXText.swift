import AppKit
import ApplicationServices

/// What the focused element of another app says about its selection.
struct AXSelection {
    let element: AXUIElement
    let text: String
    /// Selection bounds in Accessibility coordinates (top-left origin), when the app reports them.
    let bounds: CGRect?
    let editable: Bool
}

/// Thin, timeout-guarded wrappers over the Accessibility C API. Every call that reaches
/// into another app is bounded, so a hung app can never freeze Inkbar.
@MainActor
enum AXText {
    static let timeout: Float = 0.25

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // Type checked by CFGetTypeID above.
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue // Type checked by CFGetTypeID above.
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect.width > 0 || rect.height > 0 ? rect : nil
    }

    static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue // Type checked by CFGetTypeID above.
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = application(pid)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, timeout)
        return focused
    }

    /// Password fields, by role or subrole. Inkbar never reads or acts on them.
    static func isSecure(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        return subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField"
    }

    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    static func isEditable(_ element: AXUIElement) -> Bool {
        if isSettable(element, kAXSelectedTextAttribute) { return true }
        let role = string(element, kAXRoleAttribute) ?? ""
        return textRoles.contains(role) && isSettable(element, kAXValueAttribute)
    }

    /// The selection of the focused element of `pid`, or nil when there is none, it is a
    /// password field, or the app does not expose its text.
    static func selection(pid: pid_t) -> AXSelection? {
        guard let focused = focusedElement(pid: pid) else { return nil }
        return selection(of: focused)
    }

    /// Why a read has no selection, so the caller knows whether waiting can help.
    enum Read {
        case selection(AXSelection)
        /// The focused element reports its selection and it is empty: the app may simply not
        /// have published the new selection yet.
        case empty
        /// No focused element could be read (the app is busy or between windows).
        case noFocus
        /// The app did not answer in time (Accessibility timeout). Worth retrying.
        case busy
        /// A password field. Never read, never retried.
        case blocked
        /// The focused element does not expose a selection at all (apps that hide their text).
        case opaque
    }

    static func read(pid: pid_t) -> Read {
        guard let focused = focusedElement(pid: pid) else { return .noFocus }
        return read(of: focused)
    }

    static func read(of focused: AXUIElement) -> Read {
        if isSecure(focused) { return .blocked }
        if let found = selection(of: focused) { return .selection(found) }
        let text = probe(focused, kAXSelectedTextAttribute)
        let marker = probe(focused, "AXSelectedTextMarkerRange")
        if text.value != nil || marker.value != nil { return .empty }
        // A timeout or a vanished element is the app being busy, not the app hiding its text.
        if text.transient || marker.transient { return .busy }
        return .opaque
    }

    /// One attribute read that keeps why it failed: `transient` for errors that a retry can
    /// fix (the app did not answer in time, the element was replaced under us).
    static func probe(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, transient: Bool) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error == .success ? value : nil, isTransient(error))
    }

    static func isTransient(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .invalidUIElement
    }

    /// The selection inside one element, with the same rules.
    static func selection(of focused: AXUIElement) -> AXSelection? {
        guard !isSecure(focused) else { return nil }
        if let text = string(focused, kAXSelectedTextAttribute), !text.isEmpty {
            var bounds: CGRect?
            if let range = range(attribute(focused, kAXSelectedTextRangeAttribute)) {
                bounds = selectionBounds(focused, range: trimmedRange(range, in: text))
            }
            return AXSelection(element: focused, text: text, bounds: bounds, editable: isEditable(focused))
        }
        // WebKit and Chromium describe page selections with text markers.
        if let marker = attribute(focused, "AXSelectedTextMarkerRange"),
           let text = parameterized(focused, "AXStringForTextMarkerRange", marker) as? String, !text.isEmpty {
            let bounds = rect(parameterized(focused, "AXBoundsForTextMarkerRange", marker))
            return AXSelection(element: focused, text: text, bounds: bounds, editable: isEditable(focused))
        }
        return nil
    }

    /// Role and subrole of an element, nil when either cannot be read.
    static func roles(_ element: AXUIElement) -> (role: String, subrole: String)? {
        guard let role = string(element, kAXRoleAttribute) else { return nil }
        return (role, string(element, kAXSubroleAttribute) ?? "")
    }

    /// Roles of the parents of `element`, nearest first, up to `limit` levels. A parent whose
    /// role cannot be read appears as "?", so callers can fail closed. The chain simply ends
    /// at the top of the tree.
    static func ancestorRoles(of element: AXUIElement, limit: Int = 12) -> [String] {
        var roles: [String] = []
        var current = element
        while roles.count < limit, let parent = Self.element(current, kAXParentAttribute) {
            AXUIElementSetMessagingTimeout(parent, timeout)
            roles.append(string(parent, kAXRoleAttribute) ?? "?")
            current = parent
        }
        return roles
    }

    /// Fails closed: true when the focused element is a password field or cannot be read at all.
    static func focusIsSecure(pid: pid_t) -> Bool {
        guard let focused = focusedElement(pid: pid), roles(focused) != nil else { return true }
        return isSecure(focused)
    }

    /// The range without the whitespace and line breaks at its ends. A triple-click selects the
    /// line break too, and an app reports the highlight of that break as running to the edge of
    /// the page, which would drag the bar away from the text. Returned unchanged when the range
    /// is not in UTF-16 units of `text` (an app counting differently) or holds only whitespace.
    nonisolated static func trimmedRange(_ range: CFRange, in text: String) -> CFRange {
        let ns = text as NSString
        guard range.length == ns.length, range.length > 0 else { return range }
        func isSpace(_ unit: unichar) -> Bool {
            Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var start = 0
        var end = ns.length
        while start < end, isSpace(ns.character(at: start)) { start += 1 }
        while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
        guard end > start else { return range }
        return CFRange(location: range.location + start, length: end - start)
    }

    /// Bounds of a selection. A very long selection uses its first character, so the
    /// bar lands near where the selection starts instead of the middle of nowhere.
    static func selectionBounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        guard range.length > 0 else { return nil }
        var r = range
        if let value = AXValueCreate(.cfRange, &r), let full = rect(parameterized(element, kAXBoundsForRangeParameterizedAttribute, value)),
           full.height <= 240 {
            return full
        }
        var first = CFRange(location: range.location, length: 1)
        guard let value = AXValueCreate(.cfRange, &first) else { return nil }
        return rect(parameterized(element, kAXBoundsForRangeParameterizedAttribute, value))
    }

    /// Replaces the selection through Accessibility. Returns false when the app refuses.
    static func replaceSelection(_ element: AXUIElement, with text: String) -> Bool {
        guard isSettable(element, kAXSelectedTextAttribute) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Electron apps build their accessibility tree only when asked; this is the documented
    /// switch for assistive apps. Harmless on anything else.
    static func enableManualAccessibility(pid: pid_t) {
        let app = application(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
