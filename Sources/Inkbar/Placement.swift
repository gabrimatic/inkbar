import CoreGraphics

/// Where the bar goes. Pure geometry in Cocoa coordinates (origin bottom-left of the
/// primary screen).
enum Placement {
    struct Screen: Sendable {
        /// The full screen frame.
        var frame: CGRect
        /// The frame minus menu bar and Dock.
        var visibleFrame: CGRect
        /// Height of the area at the top that the camera housing covers (0 without a notch).
        var safeTop: CGFloat
    }

    static let gap: CGFloat = 8
    static let margin: CGFloat = 6

    /// Turns an Accessibility rect (origin top-left of the primary screen, y down) into Cocoa.
    static func cocoaRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The usable part of a screen: never under the menu bar, the Dock or the notch.
    static func usable(_ s: Screen) -> CGRect {
        var area = s.visibleFrame
        let notchFloor = s.frame.maxY - s.safeTop
        if area.maxY > notchFloor { area.size.height = max(0, notchFloor - area.minY) }
        return area.insetBy(dx: margin, dy: margin)
    }

    /// The screen that shows the anchor: the one containing its centre, else the closest.
    static func screen(for anchor: CGRect, in screens: [Screen]) -> Screen? {
        let mid = CGPoint(x: anchor.midX, y: anchor.midY)
        if let hit = screens.first(where: { $0.frame.contains(mid) }) { return hit }
        return screens.min { distance($0.frame, mid) < distance($1.frame, mid) }
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// The bar's frame: centred above the anchor, below it when there is no room above,
    /// and always fully inside the usable area of one screen.
    static func frame(size: CGSize, anchor: CGRect, screens: [Screen]) -> CGRect {
        guard let screen = screen(for: anchor, in: screens) else {
            return CGRect(origin: CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap), size: size)
        }
        let area = usable(screen)
        var x = anchor.midX - size.width / 2
        var y: CGFloat
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - size.height
        if above + size.height <= area.maxY {
            y = above
        } else if below >= area.minY {
            y = below
        } else {
            // The selection fills the screen height: sit inside it, near the top.
            y = area.maxY - size.height
        }
        x = min(max(x, area.minX), max(area.minX, area.maxX - size.width))
        y = min(max(y, area.minY), max(area.minY, area.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
