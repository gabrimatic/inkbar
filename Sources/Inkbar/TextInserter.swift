import AppKit
import Carbon

/// Puts text into the field the selection came from: through Accessibility when the
/// app allows it, otherwise as a paste with the clipboard restored afterwards.
@MainActor
enum TextInserter {
    static func insert(_ text: String, into element: AXUIElement?) {
        if let element, AXText.replaceSelection(element, with: text) { return }
        paste(text)
    }

    private static func paste(_ text: String) {
        guard !IsSecureEventInputEnabled() else { return }
        let pb = NSPasteboard.general
        let saved = Clipboard.snapshot(pb)
        let staged = Clipboard.stage(text, on: pb)
        guard KeySynth.paste() else {
            Clipboard.restore(saved, to: pb)
            return
        }
        // The app reads the clipboard while handling the key; give it time, then restore
        // unless the user or another app has copied something new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                if pb.changeCount == staged { Clipboard.restore(saved, to: pb) }
            }
        }
    }
}
