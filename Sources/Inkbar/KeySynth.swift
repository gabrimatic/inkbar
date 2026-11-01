import AppKit
import Carbon

/// Synthetic Cmd+C and Cmd+V, sent only right after a user gesture.
@MainActor
enum KeySynth {
    /// The key code that types `character` in the current keyboard layout, so Cmd+C is
    /// still Cmd+C on Dvorak or AZERTY. Falls back to the ANSI position.
    static func keyCode(for character: Character, fallback: CGKeyCode) -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return data.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for code in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return code
                }
            }
            return fallback
        }
    }

    /// Posts Cmd+<key> to the frontmost app. Returns false when events cannot be created.
    @discardableResult
    static func command(_ character: Character, fallback: CGKeyCode) -> Bool {
        let code = keyCode(for: character, fallback: fallback)
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        // Only Command: a held Option or Shift from the gesture must not change the shortcut.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func copy() -> Bool { command("c", fallback: CGKeyCode(kVK_ANSI_C)) }
    static func paste() -> Bool { command("v", fallback: CGKeyCode(kVK_ANSI_V)) }
}

/// Reads a selection from apps that do not expose their text to Accessibility, by asking
/// the app to copy and then putting the clipboard back exactly as it was.
@MainActor
enum CopyFallback {
    /// Calls back with the copied text, or nil. The clipboard is restored in every case
    /// unless something else wrote to it meanwhile, in which case that newer content wins.
    static func read(completion: @escaping @MainActor (String?) -> Void) {
        guard !IsSecureEventInputEnabled() else { completion(nil); return }
        let pb = NSPasteboard.general
        let saved = Clipboard.snapshot(pb)
        guard KeySynth.copy() else { completion(nil); return }
        poll(pb: pb, saved: saved, attempt: 0, completion: completion)
    }

    /// A short, bounded wait for the app to answer Cmd+C (at most about 0.4 s, only
    /// right after a gesture). Inkbar never watches the clipboard otherwise.
    private static func poll(pb: NSPasteboard, saved: Clipboard.Snapshot, attempt: Int, completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            MainActor.assumeIsolated {
                if pb.changeCount == saved.changeCount {
                    if attempt < 10 { poll(pb: pb, saved: saved, attempt: attempt + 1, completion: completion) } else { completion(nil) }
                    return
                }
                let copiedCount = pb.changeCount
                let types = pb.types ?? []
                // A file or image copy (Finder, a photo app) is not a text selection.
                let text = types.contains(.fileURL) ? nil : pb.string(forType: .string)
                // Restore only if nothing else wrote after the app's copy.
                if pb.changeCount == copiedCount { Clipboard.restore(saved, to: pb) }
                completion(text)
            }
        }
    }
}
