import AppKit

/// Draws the black that hides the notch, as click-through windows on each targeted screen.
///
/// Every window sits at desktop level, just above the wallpaper and below every app
/// window, as if the wallpaper itself had been edited:
/// - The bar fills the menu bar's strip. On a normal desktop no app window goes there,
///   so it shows behind the menu bar and the notch disappears. A full-screen app's
///   window covers it, so the app's own top edge (a VM's menu bar, say) stays visible.
/// - The optional rounded corners show only where the desktop is exposed, so a
///   window keeps its own corners.
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
        var wanted: [Key: NSRect] = [:]
        if enabled {
            let r = Self.cornerRadius
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                if scope == .builtInOnly, CGDisplayIsBuiltin(id) == 0 { continue }
                let height = Self.barHeight(for: screen)
                let f = screen.frame
                if height > 0 {
                    wanted[Key(display: id, kind: .bar)] =
                        NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height)
                }
                // A display without a menu bar still gets corners, at its top edge.
                if roundCorners {
                    wanted[Key(display: id, kind: .topCorners)] =
                        NSRect(x: f.minX, y: f.maxY - height - r, width: f.width, height: r)
                    wanted[Key(display: id, kind: .bottomCorners)] =
                        NSRect(x: f.minX, y: f.minY, width: f.width, height: r)
                }
            }
        }

        for key in windows.keys where wanted[key] == nil {
            windows.removeValue(forKey: key)?.orderOut(nil)
        }
        // Every Space switch lands here, so leave windows alone unless their frame changed.
        for (key, frame) in wanted {
            if let window = windows[key] {
                if window.frame != frame { window.setFrame(frame, display: true) }
            } else {
                windows[key] = Self.makeWindow(frame: frame, kind: key.kind)
            }
        }
    }

    /// The full menu bar height (which can exceed the notch's by a point), or
    /// zero when the menu bar is set to auto-hide on a screen without a notch.
    private static func barHeight(for screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Slightly larger than the corner radius of current macOS windows (16 for AppKit
    /// windows, about 14 for Electron ones), so a window at the screen edge leaves no
    /// sliver of wallpaper between its curve and the black.
    private static let cornerRadius: CGFloat = 17

    private static func makeWindow(frame: NSRect, kind: Kind) -> NSWindow {
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Windows that join all Spaces show in full-screen ones too, so anything above
        // desktop level would cover the top of a full-screen app.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        switch kind {
        case .bar:
            window.contentView = BarView()
        case .topCorners, .bottomCorners:
            window.contentView = CornersView(edge: kind == .topCorners ? .top : .bottom, radius: cornerRadius)
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
