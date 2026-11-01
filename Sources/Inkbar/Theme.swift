import AppKit
import SwiftUI

/// The three colours of the design language (docs/DESIGN.md) and nothing else. Every other tone the
/// app draws is one of these at some alpha, or `paper`, which is ice blended towards white.
enum Palette {
    static let ink = NSColor(srgbRed: 0x1B / 255.0, green: 0x26 / 255.0, blue: 0x2C / 255.0, alpha: 1)
    static let ice = NSColor(srgbRed: 0xBB / 255.0, green: 0xE1 / 255.0, blue: 0xFA / 255.0, alpha: 1)
    static let accent = NSColor(srgbRed: 0x32 / 255.0, green: 0x82 / 255.0, blue: 0xB8 / 255.0, alpha: 1)
    /// Ice blended 80% towards white: the ground of the light appearance.
    static let paper = NSColor(srgbRed: 0xF1 / 255.0, green: 0xF9 / 255.0, blue: 0xFE / 255.0, alpha: 1)

    /// A colour that is `dark` in the dark appearance and `light` in the light one.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// The colours surfaces use, by role. Dark appearance: ink ground, ice text. Light appearance:
/// paper ground, ink text. The accent is the same in both.
enum Theme {
    static let groundNS = Palette.dynamic(dark: Palette.ink, light: Palette.paper)
    static let textNS = Palette.dynamic(dark: Palette.ice, light: Palette.ink)
    static let secondaryNS = Palette.dynamic(dark: Palette.ice.withAlphaComponent(0.68), light: Palette.ink.withAlphaComponent(0.68))
    static let tertiaryNS = Palette.dynamic(dark: Palette.ice.withAlphaComponent(0.44), light: Palette.ink.withAlphaComponent(0.44))
    /// Hairlines: ice at 0.25 on ink, the same weight of ink on paper.
    static let hairlineNS = Palette.dynamic(dark: Palette.ice.withAlphaComponent(0.25), light: Palette.ink.withAlphaComponent(0.2))
    static let dividerNS = Palette.dynamic(dark: Palette.ice.withAlphaComponent(0.08), light: Palette.ink.withAlphaComponent(0.08))
    /// A quiet fill for a hovered row or a resting control.
    static let fillNS = Palette.dynamic(dark: Palette.ice.withAlphaComponent(0.1), light: Palette.ink.withAlphaComponent(0.07))
    /// A grouped surface on the ground: a form group, a card's row, the permission row.
    static let surfaceNS = Palette.dynamic(dark: Palette.ice.withAlphaComponent(0.06), light: Palette.ink.withAlphaComponent(0.045))
    static let accentNS = Palette.accent
    /// Text on an accent fill.
    static let onAccentNS = Palette.paper

    static let ground = Color(nsColor: groundNS)
    static let text = Color(nsColor: textNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let tertiary = Color(nsColor: tertiaryNS)
    static let hairline = Color(nsColor: hairlineNS)
    static let divider = Color(nsColor: dividerNS)
    static let fill = Color(nsColor: fillNS)
    static let surface = Color(nsColor: surfaceNS)
    static let accent = Color(nsColor: accentNS)
    static let onAccent = Color(nsColor: onAccentNS)
    /// A real error, sparingly: the only colour outside the palette.
    static let error = Color(nsColor: .systemRed)

    /// Corner radii share one scale: a card, the bar's buttons and the rows inside a card nest.
    static let cardRadius: CGFloat = 20
    static let rowRadius: CGFloat = 8
}

/// IBM Plex Sans, the face of every surface the app draws itself (docs/DESIGN.md). It ships in
/// Resources/Fonts under the SIL Open Font License (Resources/Fonts/OFL.txt) and is registered for
/// this process only. Native controls keep the system font. If the file cannot be registered the
/// app falls back to the system font instead of failing.
enum Typeface {
    static let family = "IBM Plex Sans"

    enum Weight {
        case light, regular, medium

        fileprivate var face: String {
            switch self {
            case .light: return "IBMPlexSans-Light"
            case .regular: return "IBMPlexSans-Regular"
            case .medium: return "IBMPlexSans-Medium"
            }
        }

        fileprivate var system: NSFont.Weight {
            switch self {
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            }
        }
    }

    /// Where the font file lives: the app bundle, or the repo's Resources folder outside a bundle.
    static func fontURLs() -> [URL] {
        if let url = Bundle.main.url(forResource: "IBMPlexSans", withExtension: "ttf", subdirectory: "Fonts") {
            return [url]
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts/IBMPlexSans.ttf")
        return FileManager.default.fileExists(atPath: local.path) ? [local] : []
    }

    /// Registers the font once. Returns whether Plex is usable afterwards.
    @MainActor @discardableResult
    static func register() -> Bool {
        if registered { return available }
        registered = true
        for url in fontURLs() {
            var error: Unmanaged<CFError>?
            // Already registered (a second run in the same process) counts as registered.
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
        return available
    }

    @MainActor private static var registered = false

    /// Whether the face resolves, whoever registered it.
    static var available: Bool { NSFont(name: Weight.regular.face, size: 12) != nil }

    static func ns(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        NSFont(name: weight.face, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight.system)
    }

    /// Plex at a size and weight. Plex's figures are tabular, so numbers line up as they are.
    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        Font(ns(size, weight) as CTFont)
    }
}
