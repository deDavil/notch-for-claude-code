import AppKit

/// Where and how big the notch is. Detects a real notch via safe-area insets +
/// auxiliary top areas; falls back to a virtual pill (top-center) on displays
/// without one, so the app is testable on a no-notch Mac.
struct NotchGeometry {
    enum Mode { case real, virtual }

    let screen: NSScreen
    let notchRect: NSRect   // global (bottom-left origin) screen coordinates
    let mode: Mode

    /// Compute geometry for the current display arrangement. `forceVirtual`
    /// draws the pill even when a real notch exists (dev override).
    static func current(forceVirtual: Bool) -> NotchGeometry {
        if !forceVirtual, let g = realNotch() {
            return g
        }
        return virtualNotch()
    }

    private static func realNotch() -> NotchGeometry? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0 else { continue }
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { continue }
            let height = screen.safeAreaInsets.top
            let width = max(0, screen.frame.width - left.width - right.width)
            let x = screen.frame.minX + left.width
            let y = screen.frame.maxY - height
            let rect = NSRect(x: x, y: y, width: width, height: height)
            return NotchGeometry(screen: screen, notchRect: rect, mode: .real)
        }
        return nil
    }

    private static func virtualNotch() -> NotchGeometry {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let width: CGFloat = 200
        let height: CGFloat = 32
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        let rect = NSRect(x: x, y: y, width: width, height: height)
        return NotchGeometry(screen: screen, notchRect: rect, mode: .virtual)
    }

    /// Frame for the collapsed panel: the notch rect itself (a tight frame keeps
    /// menu-bar clicks passing through everywhere else).
    var collapsedFrame: NSRect { notchRect }

    /// Frame for the expanded card: centered under the notch, growing downward.
    func expandedFrame(cardSize: NSSize) -> NSRect {
        let x = notchRect.midX - cardSize.width / 2
        let y = notchRect.minY - cardSize.height
        // Keep it on-screen horizontally.
        let clampedX = min(max(x, screen.frame.minX + 8),
                           screen.frame.maxX - cardSize.width - 8)
        return NSRect(x: clampedX, y: y, width: cardSize.width, height: cardSize.height)
    }
}
