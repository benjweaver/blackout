import AppKit

/// Draws the black that hides the notch, as click-through windows on each targeted screen.
///
/// - The bar covers the menu bar. It sits just below the menu bar's own level, so
///   menu bar items, the clock, and menus draw on top while the notch disappears.
/// - The optional rounded corners sit at desktop level, just above the wallpaper
///   and below every app window, so a window keeps its own corners and only the
///   exposed desktop is rounded, as if the wallpaper itself had been edited.
///
/// Neither joins full-screen Spaces, where the menu bar is hidden anyway.
@MainActor
final class OverlayController {
    private enum Kind: CaseIterable {
        case bar, topCorners, bottomCorners
    }

    private struct Key: Hashable {
        let display: CGDirectDisplayID
        let kind: Kind
    }

    private var windows: [Key: NSWindow] = [:]

    func update(enabled: Bool, scope: DisplayScope, roundCorners: Bool) {
        var wanted: [Key: (frame: NSRect, view: NSView)] = [:]
        if enabled {
            let r = Self.cornerRadius
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                if scope == .builtInOnly, CGDisplayIsBuiltin(id) == 0 { continue }
                let height = Self.barHeight(for: screen)
                guard height > 0 else { continue }
                let f = screen.frame
                wanted[Key(display: id, kind: .bar)] = (
                    NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), BarView())
                if roundCorners {
                    wanted[Key(display: id, kind: .topCorners)] = (
                        NSRect(x: f.minX, y: f.maxY - height - r, width: f.width, height: r),
                        CornersView(edge: .top, radius: r))
                    wanted[Key(display: id, kind: .bottomCorners)] = (
                        NSRect(x: f.minX, y: f.minY, width: f.width, height: r),
                        CornersView(edge: .bottom, radius: r))
                }
            }
        }

        for key in windows.keys where wanted[key] == nil {
            windows.removeValue(forKey: key)?.orderOut(nil)
        }
        for (key, item) in wanted {
            let window = windows[key] ?? Self.makeWindow(frame: item.frame, kind: key.kind)
            windows[key] = window
            window.setFrame(item.frame, display: true)
            window.contentView = item.view
        }
    }

    /// The full menu bar height (which can exceed the notch's by a point), or
    /// zero when the menu bar is set to auto-hide on a screen without a notch.
    private static func barHeight(for screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Slightly larger than the corner radius of current macOS windows (about 14), so a window at the screen
    /// edge leaves no sliver of wallpaper between its curve and the black.
    private static let cornerRadius: CGFloat = 15

    private static func makeWindow(frame: NSRect, kind: Kind) -> NSWindow {
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        switch kind {
        case .bar:
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        case .topCorners, .bottomCorners:
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        }
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        return window
    }
}

private final class BarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
    }
}

/// The two inverted corners at the top or bottom edge of the screen.
private final class CornersView: NSView {
    enum Edge { case top, bottom }

    let edge: Edge
    let radius: CGFloat

    init(edge: Edge, radius: CGFloat) {
        self.edge = edge
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let r = radius
        // Each wedge is the square corner minus a quarter circle centred `r` inside it.
        let y = edge == .top ? bounds.maxY : 0
        let dy: CGFloat = edge == .top ? -r : r
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 0, y: y))
        left.line(to: NSPoint(x: r, y: y))
        left.appendArc(withCenter: NSPoint(x: r, y: y + dy), radius: r,
                       startAngle: edge == .top ? 90 : 270, endAngle: 180, clockwise: edge == .bottom)
        left.close()
        left.fill()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: bounds.maxX, y: y))
        right.line(to: NSPoint(x: bounds.maxX - r, y: y))
        right.appendArc(withCenter: NSPoint(x: bounds.maxX - r, y: y + dy), radius: r,
                        startAngle: edge == .top ? 90 : 270, endAngle: edge == .top ? 0 : 360,
                        clockwise: edge == .top)
        right.close()
        right.fill()
    }
}

/// AppKit normally pushes windows out from under the menu bar; this one belongs there.
private final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
