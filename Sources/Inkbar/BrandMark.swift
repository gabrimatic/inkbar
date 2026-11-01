import AppKit

/// Inkbar's mark: one heavy drop of ink landing on the bar.
/// One drawing on a 24-unit grid, y down: solid ice, one accent part, detail cut out of it.
/// `scripts/make-icon.swift` paints it on the app icon's tile and `menuBarImage` draws it as a
/// template, so the two can never differ.
enum BrandMark {
    static let grid: CGFloat = 24

    /// The ice part: the bar.
    static func icePaths() -> [CGPath] {
        [CGPath(roundedRect: CGRect(x: 0.8, y: 19.8, width: 22.4, height: 3.4), cornerWidth: 1.7, cornerHeight: 1.7, transform: nil)]
    }

    /// The one accent part: the drop.
    static func accentPaths() -> [CGPath] {
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 12, y: 1))
        drop.addCurve(to: CGPoint(x: 19.4, y: 11.6), control1: CGPoint(x: 14.2, y: 4.2), control2: CGPoint(x: 19.4, y: 6.8))
        drop.addCurve(to: CGPoint(x: 12, y: 18.6), control1: CGPoint(x: 19.4, y: 15.6), control2: CGPoint(x: 16.1, y: 18.6))
        drop.addCurve(to: CGPoint(x: 4.6, y: 11.6), control1: CGPoint(x: 7.9, y: 18.6), control2: CGPoint(x: 4.6, y: 15.6))
        drop.addCurve(to: CGPoint(x: 12, y: 1), control1: CGPoint(x: 4.6, y: 6.8), control2: CGPoint(x: 9.8, y: 4.2))
        return [drop]
    }

    /// Paints the mark on a context whose unit is one grid unit, y down. Without an accent colour the
    /// accent part stays cut out.
    static func draw(in context: CGContext, ice: CGColor, accent: CGColor?) {
        context.setFillColor(ice)
        for path in icePaths() {
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
        guard let accent else { return }
        context.setFillColor(accent)
        for path in accentPaths() {
            context.addPath(path)
            context.fillPath()
        }
    }

    /// The menu bar image: the same drawing in one colour, as a template so macOS tints it.
    static func menuBarImage(description: String) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: side / grid, y: -side / grid)
            draw(in: context, ice: NSColor.black.cgColor, accent: NSColor.black.cgColor)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
