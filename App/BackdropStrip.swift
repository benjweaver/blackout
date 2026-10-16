import AppKit
import OSLog

/// Blacks out the notch row where Blackout's ordinary bar can't reach, while leaving
/// Apple's own text and icons visible:
/// - On the lock screen, which no app can draw into.
/// - Over the menu bar when macOS draws its own background on top of Blackout's bar: an
///   opaque gray with Reduce Transparency on, or a blur with "Show menu bar background" on.
///
/// Both hold black layers and backdrop layers. WindowServer fills a backdrop with what's
/// beneath it, and a pair of color matrices turns the background into opaque black and
/// Apple's glyphs into transparency. Blackout only ever adds black, so the icons and text
/// on screen are macOS's own pixels.
///
/// On the lock screen, the strip sits in a private SkyLight space at the level macOS uses
/// for lock-screen notifications, one window per screen with a notch.
///
/// Over the menu bar, each desktop and full-screen Space gets its own strip window, just
/// above the menu bar and inside that Space, so it slides with the menu bar when Spaces
/// change. A strip hides when its Space's menu bar does (a full-screen app, say) and
/// follows it in and out, from a per-frame SkyLight notification.
///
/// This relies on private SkyLight and Core Animation interfaces, loaded at run time. If
/// any is missing it does nothing.
@MainActor
final class BackdropStripController: NSObject {
    private enum Mode { case hidden, lockScreen, menuBar }

    /// One window per screen with a notch, in the private space, for the lock screen.
    private struct Strip {
        let window: NSWindow
        let lockScreen: CALayer
        let keyLayers: [CALayer]
    }

    /// Where the menu bar strip goes on one screen.
    private struct MenuBarGeometry {
        let frame: CGRect
        let leftEnd: CGFloat
        let rightStart: CGFloat
        let index: Int
    }

    /// One window per Space, holding that Space's menu bar layout. A full-screen Space also
    /// gets a black bar at desktop level, under the app, the way Blackout's own bar sits on a
    /// desktop: the app covers it, but it fills the menu bar's strip while the app zooms out
    /// of full screen, where the wallpaper would otherwise show.
    private struct MenuBarStrip {
        let window: NSWindow
        let layout: CALayer
        let keyLayers: [CALayer]
        let backing: NSWindow?
        let backingLayer: CALayer?

        var windows: [NSWindow] { [window] + (backing.map { [$0] } ?? []) }
    }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "BackdropStrip")
    private let skyLight = SkyLight()
    private var space: UInt64 = 0
    private var strips: [Strip] = []
    /// By display UUID, as SkyLight names displays.
    private var menuBarGeometry: [String: MenuBarGeometry] = [:]
    /// By Space ID.
    private var menuBarStrips: [UInt64: MenuBarStrip] = [:]
    private var lockScreenWanted = false
    private var menuBarWanted = false
    private var allDisplays = true
    /// How far each Space's menu bar is revealed, 0 (hidden) to 1, by Space ID.
    private var menuBarReveal: [UInt64: Double] = [:]
    private var isLocked = false
    private var mode = Mode.hidden
    /// Keeps the lock-screen strip up briefly after unlock, then fades it out.
    private var unlockFade: Task<Void, Never>?
    private var revealObserver: NSObjectProtocol?
    /// What the strips were last built for, so screen changes that leave it alone (the
    /// Dock showing or hiding, say) don't rebuild every window.
    private var builtFor: [ScreenLayout] = []
    /// Each display's menu bar height from its visible frame, by display UUID, for when a
    /// full-screen app has hidden the menu bar and the visible frame reaches the top.
    private var menuBarHeights: [String: CGFloat] = [:]

    /// What one screen's strips depend on.
    private struct ScreenLayout: Equatable {
        let display: String
        let frame: CGRect
        let inset: CGFloat
        let menuBarHeight: CGFloat
        let leftEnd: CGFloat
        let rightStart: CGFloat
    }

    // Lock-screen tuning, measured on a 16-inch MacBook Pro. loginwindow right-aligns its
    // icons 20 pt from the screen edge and centers their glyphs about 12.5–24 pt from the top.
    // The glyphs sit below full white and wallpaper highlights reach the same brightness,
    // so the key covers only a zone around the icons, and only the band the glyphs fill.
    private var keyZoneWidth: CGFloat { Self.setting("LockScreenKeyZoneWidth", 150) }
    private var keyBandTop: CGFloat { Self.setting("LockScreenKeyBandTop", 11) }
    private var keyBandBottom: CGFloat { Self.setting("LockScreenKeyBandBottom", 26) }
    private var lockKey: BackdropKey { BackdropKey(gain: Self.setting("LockScreenKeyGain", 30),
                                   threshold: Self.setting("LockScreenKeyThreshold", 0.25), anyChannel: false) }
    /// Measured on a 16-inch MacBook Pro: the desktop takes about 0.3 s to settle after unlock.
    private var unlockHold: Double { Self.setting("LockScreenUnlockHold", 0.5) }
    private static let unlockFadeDuration = 0.25
    // Reduce Transparency gives a flat (42, 42, 42) gray menu bar. "Show menu bar background"
    // gives a blur in the wallpaper's own color, as bright as 0.72 gray or 0.86 saturated red,
    // with white glyphs in both appearances. So the key passes only pixels above 0.7 in all
    // three channels: the white glyphs. Colored icons go black, apart from the privacy
    // indicators, which sit above the strip's space. On a near-white wallpaper macOS draws a
    // light bar with dark glyphs; the bar is above the threshold, so the key passes it and
    // leaves the menu bar as macOS draws it.
    private var menuBarKey: BackdropKey { BackdropKey(gain: Self.setting("MenuBarKeyGain", 40),
                                      threshold: Self.setting("MenuBarKeyThreshold", 0.7), anyChannel: false) }
    override init() {
        super.init()
        isLocked = ScreenLock.shared.isLocked
        ScreenLock.shared.observe { [weak self] locked in
            self?.isLocked = locked
            self?.reconcile()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(nudge),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // "Show menu bar background" in System Settings ▸ Menu Bar. It's a global default that
        // System Settings writes from another process, which key-value observing still sees.
        UserDefaults.standard.addObserver(self, forKeyPath: Self.menuBarBackgroundKey, options: [], context: nil)
        workspace.addObserver(self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Posted every frame while a menu bar slides in or out, with its space and reveal.
        // Delivered on the main queue, whichever thread SkyLight posts it from.
        if let center = skyLight.coordinatedNotificationCenter, let name = skyLight.menuBarRevealNotification {
            revealObserver = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let info = notification.userInfo,
                      let menuSpace = (info["space"] as? NSNumber)?.uint64Value,
                      let reveal = (info["reveal"] as? NSNumber)?.doubleValue else { return }
                MainActor.assumeIsolated { self?.menuBarRevealChanged(menuSpace: menuSpace, reveal: reveal) }
            }
        }
    }

    /// `lockScreen`: black behind the icons while locked. `menuBar`: cover the menu bar's
    /// own background when macOS draws one, on every display or (`allDisplays` false) only
    /// the built-in one. The space and windows exist while either is on.
    func update(lockScreen: Bool, menuBar: Bool, allDisplays: Bool) {
        let wasOn = lockScreenWanted || menuBarWanted
        let scopeChanged = allDisplays != self.allDisplays
        lockScreenWanted = lockScreen
        menuBarWanted = menuBar
        self.allDisplays = allDisplays
        let isOn = lockScreen || menuBar
        if isOn && !wasOn {
            setUp()
        } else if !isOn && wasOn {
            tearDown()
        } else if scopeChanged && !isLocked && space != 0 {
            mode = .hidden
            buildStrips()
            reconcile()
        } else {
            reconcile()
        }
    }

    private func setUp() {
        guard skyLight.isAvailable, NSClassFromString("CABackdropLayer") != nil,
              NSClassFromString("CAFilter") != nil else {
            log.error("Private interfaces missing; backdrop strip is off")
            return
        }
        // The space is shown for as long as the strip is on, and its layouts are hidden
        // inside it instead. A backdrop that first appears on the lock screen never starts
        // drawing on real hardware, though one already on screen keeps going.
        space = skyLight.createSpace(level: skyLight.lockScreenNotificationLevel)
        buildStrips()
        skyLight.show(space)
        reconcile()
        log.info("Backdrop strip on (space \(self.space))")
    }

    private func tearDown() {
        strips.forEach { $0.window.close() }
        strips = []
        menuBarStrips.values.flatMap(\.windows).forEach { $0.close() }
        menuBarStrips = [:]
        menuBarGeometry = [:]
        menuBarReveal = [:]
        if space != 0 {
            skyLight.hide(space)
            skyLight.destroy(space)
            space = 0
        }
        mode = .hidden
        unlockFade?.cancel()
        unlockFade = nil
        log.info("Backdrop strip off")
    }

    @objc private func accessibilityChanged() {
        reconcile()
    }

    /// Spaces come and go (a window entering full screen gets one), and Space switches don't
    /// post the reveal notification, so add strips for new Spaces and reread every reveal.
    @objc private func spaceChanged() {
        syncMenuBarStrips(settling: true)
    }

    /// The notification names the Space macOS keeps the menu bar in, whose parent is the
    /// desktop or full-screen Space it belongs to. Spaces on displays without a strip
    /// (another display, with the bar on the built-in one only) are skipped.
    private func menuBarRevealChanged(menuSpace: UInt64, reveal: Double) {
        let space = skyLight.parentSpace(of: menuSpace) ?? menuSpace
        if menuBarStrips[space] != nil {
            menuBarReveal[space] = reveal
            applyMenuBarReveal()
        } else if let display = skyLight.display(of: space), menuBarGeometry[display] != nil {
            menuBarReveal[space] = reveal
            syncMenuBarStrips()
        }
    }

    private static let menuBarBackgroundKey = "SLSMenuBarUseBlurredAppearance"

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.reconcile() }
    }

    /// Whether macOS draws a background of its own over Blackout's bar.
    private var menuBarHasBackground: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || UserDefaults.standard.bool(forKey: Self.menuBarBackgroundKey)
    }

    /// Geometry is read only while unlocked. While locked, something else (the no-notch
    /// display mode, say) may have removed the notch row, so the strips hide until it's back.
    @objc private func screensChanged() {
        guard space != 0 else { return }
        if !isLocked && screenLayouts() != builtFor {
            mode = .hidden
            buildStrips()
        }
        reconcile()
    }

    private var notchRowPresent: Bool {
        !strips.isEmpty
            && (NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
                || UserDefaults.standard.double(forKey: ScreenLock.testInsetKey) > 0)
    }

    private var wantedMode: Mode {
        guard space != 0 else { return .hidden }
        if isLocked { return lockScreenWanted && notchRowPresent ? .lockScreen : .hidden }
        return menuBarWanted && menuBarHasBackground && !menuBarGeometry.isEmpty ? .menuBar : .hidden
    }

    /// Both lock notifications can arrive twice, so this only acts on a change.
    private func reconcile() {
        let wanted = wantedMode
        guard wanted != mode else { return }
        let previous = mode
        mode = wanted
        unlockFade?.cancel()
        unlockFade = nil
        if previous == .lockScreen && !isLocked {
            // The unlock notifications arrive as the desktop starts sliding back in, and for a
            // moment the menu bar strip shows wallpaper. Hold the black until it settles, then
            // fade it, with the menu bar layout (if any) already in place beneath.
            show(lockScreen: true, menuBar: wanted == .menuBar)
            unlockFade = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.unlockHold ?? 0))
                guard let self, !Task.isCancelled else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(Self.unlockFadeDuration)
                self.strips.forEach { $0.lockScreen.opacity = 0 }
                CATransaction.commit()
                try? await Task.sleep(for: .seconds(Self.unlockFadeDuration))
                guard !Task.isCancelled else { return }
                self.show(lockScreen: false, menuBar: self.mode == .menuBar)
            }
            return
        }
        show(lockScreen: wanted == .lockScreen, menuBar: wanted == .menuBar)
        guard wanted != .hidden else { return }
        // Commit again once things have settled, in case WindowServer missed the first.
        Task { @MainActor [weak self] in
            for delay in [0.3, 1.2] {
                try? await Task.sleep(for: .seconds(delay))
                self?.nudge()
            }
        }
    }

    private func show(lockScreen: Bool, menuBar: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for strip in strips {
            strip.lockScreen.isHidden = !lockScreen
            strip.lockScreen.opacity = 1
        }
        menuBarLayoutsShown = menuBar
        CATransaction.commit()
        applyMenuBarReveal()
    }

    private var menuBarLayoutsShown = false

    /// Shows each Space's menu bar layout only while its menu bar is out, offset to follow
    /// the slide.
    private func applyMenuBarReveal() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (space, strip) in menuBarStrips {
            let reveal = menuBarReveal[space] ?? 0
            strip.layout.isHidden = !menuBarLayoutsShown || reveal <= 0
            strip.layout.transform = CATransform3DMakeTranslation(0, (1 - reveal) * strip.layout.bounds.height, 0)
            strip.backingLayer?.isHidden = !menuBarLayoutsShown
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Recommits the key layers so WindowServer refreshes their backdrops, which it may
    /// not do on its own after the display wakes.
    @objc private func nudge() {
        guard mode != .hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in strips.flatMap(\.keyLayers) + menuBarStrips.values.flatMap(\.keyLayers) {
            layer.filters = layer.filters
            layer.setNeedsDisplay()
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    // MARK: Windows

    /// Builds the lock-screen strips and records where each screen's menu bar strips go,
    /// then rebuilds the menu bar strips for every Space.
    /// Each covered screen's geometry. The menu bar can be a point taller than the notch
    /// row. While a full-screen app has hidden it, the visible frame reaches the top, so
    /// the height last seen on that display stands in, or failing that the app's own.
    private func screenLayouts() -> [ScreenLayout] {
        let testInset = UserDefaults.standard.double(forKey: ScreenLock.testInsetKey)
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID, let display = SkyLight.uuid(of: id) else { return nil }
            if !allDisplays && CGDisplayIsBuiltin(id) == 0 { return nil }
            let frame = screen.frame
            let inset = testInset > 0 ? testInset : screen.safeAreaInsets.top
            let hasNotch = inset > 0
            let visibleHeight = frame.maxY - screen.visibleFrame.maxY
            if visibleHeight > 0 { menuBarHeights[display] = visibleHeight }
            let menuBarHeight = max(inset, menuBarHeights[display] ?? NSApp.mainMenu?.menuBarHeight ?? 0)
            // The strips beside the notch; on a test display, either side of a 200 pt
            // fake notch in the middle; without a notch, the whole width.
            let leftEnd = hasNotch ? (screen.auxiliaryTopLeftArea?.maxX ?? frame.midX - 100) - frame.minX : frame.width / 2
            let rightStart = hasNotch ? (screen.auxiliaryTopRightArea?.minX ?? frame.midX + 100) - frame.minX : frame.width / 2
            return ScreenLayout(display: display, frame: frame, inset: inset, menuBarHeight: menuBarHeight,
                                leftEnd: leftEnd, rightStart: rightStart)
        }
    }

    private func buildStrips() {
        strips.forEach { $0.window.close() }
        strips = []
        menuBarGeometry = [:]
        builtFor = screenLayouts()
        for (index, screen) in builtFor.enumerated() {
            let frame = screen.frame, inset = screen.inset, rightStart = screen.rightStart
            if inset > 0 {
                let rect = CGRect(x: frame.minX, y: frame.maxY - inset, width: frame.width, height: inset)
                var keys: [CALayer] = []
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let layout = makeLockScreenLayout(width: rect.width, inset: inset, top: inset, rightStart: rightStart,
                                                  name: "BlackoutStrip-\(index)", keys: &keys)
                layout.isHidden = true
                CATransaction.commit()
                let window = Self.makeStripWindow(rect, layout: layout)
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.orderFrontRegardless()
                window.setFrame(rect, display: true)
                skyLight.add(window, to: space)
                strips.append(Strip(window: window, lockScreen: layout, keyLayers: keys))
            }

            let menuBarHeight = screen.menuBarHeight
            if menuBarWanted && menuBarHeight > 0 {
                menuBarGeometry[screen.display] = MenuBarGeometry(
                    frame: CGRect(x: frame.minX, y: frame.maxY - menuBarHeight, width: frame.width, height: menuBarHeight),
                    leftEnd: screen.leftEnd, rightStart: rightStart, index: index)
            }
            log.info("Screen \(index): lock strip \(inset > 0), menu bar height \(menuBarHeight)")
        }
        menuBarStrips.values.flatMap(\.windows).forEach { $0.close() }
        menuBarStrips = [:]
        syncMenuBarStrips()
    }

    /// Gives every desktop and full-screen Space on a covered display its own menu bar
    /// strip, drops the strips of Spaces that are gone, and rereads every reveal.
    ///
    /// A new window lands in the current Space when AppKit finishes ordering it in, after
    /// it has been moved to its own, so each sync also puts any strip that's in the wrong
    /// Space back, and a sync that made strips (or follows a Space change) runs again
    /// once things have settled.
    private func syncMenuBarStrips(settling: Bool = false) {
        guard space != 0 else { return }
        var live = Set<UInt64>()
        var created = false
        for (display, userSpace, fullScreen) in skyLight.userSpaces() {
            guard let geometry = menuBarGeometry[display] else { continue }
            live.insert(userSpace)
            menuBarReveal[userSpace] = skyLight.menuBarReveal(of: userSpace)
            if let strip = menuBarStrips[userSpace] {
                for window in strip.windows where skyLight.spaces(of: window) != [userSpace] {
                    skyLight.add(window, to: userSpace)
                }
            } else {
                menuBarStrips[userSpace] = makeMenuBarStrip(geometry, in: userSpace, fullScreen: fullScreen)
                created = true
            }
        }
        for (gone, strip) in menuBarStrips where !live.contains(gone) {
            strip.windows.forEach { $0.close() }
            menuBarStrips[gone] = nil
            menuBarReveal[gone] = nil
        }
        applyMenuBarReveal()
        guard created || settling else { return }
        Task { @MainActor [weak self] in
            for delay in [0.1, 0.5] {
                try? await Task.sleep(for: .seconds(delay))
                self?.syncMenuBarStrips()
            }
        }
    }

    /// Just above the menu bar window (main menu level) and inside the Space, so it
    /// slides with that Space's menu bar. Stationary, so it stays on screen while Mission
    /// Control opens and closes: the menu bar fades out and back in during those
    /// animations, and a strip that Mission Control hid at once would leave it uncovered.
    private func makeMenuBarStrip(_ geometry: MenuBarGeometry, in userSpace: UInt64, fullScreen: Bool) -> MenuBarStrip {
        var keys: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layout = makeMenuBarLayout(size: geometry.frame.size, leftEnd: geometry.leftEnd,
                                       rightStart: geometry.rightStart,
                                       name: "BlackoutMenuBar-\(geometry.index)-\(userSpace)", keys: &keys)
        layout.isHidden = true
        CATransaction.commit()
        let window = Self.makeStripWindow(geometry.frame, layout: layout)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.orderFrontRegardless()
        window.setFrame(geometry.frame, display: true)
        skyLight.add(window, to: userSpace)
        guard fullScreen else {
            return MenuBarStrip(window: window, layout: layout, keyLayers: keys, backing: nil, backingLayer: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let black = Self.blackLayer(CGRect(origin: .zero, size: geometry.frame.size))
        black.isHidden = true
        CATransaction.commit()
        let backing = Self.makeStripWindow(geometry.frame, layout: black)
        backing.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        backing.collectionBehavior = [.ignoresCycle, .transient]
        backing.orderFrontRegardless()
        backing.setFrame(geometry.frame, display: true)
        skyLight.add(backing, to: userSpace)
        return MenuBarStrip(window: window, layout: layout, keyLayers: keys, backing: backing, backingLayer: black)
    }

    private static func makeStripWindow(_ rect: CGRect, layout: CALayer) -> NSWindow {
        let window = StripWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true // the menu bar and lock-screen icons stay clickable
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer?.addSublayer(layout)
        window.contentView = view
        return window
    }

    /// Black from the left edge through the notch, so screenshots show no gap under the
    /// camera; then the key zone at the right edge, keyed only across the glyphs' band.
    private func makeLockScreenLayout(width: CGFloat, inset: CGFloat, top: CGFloat, rightStart: CGFloat,
                                      name: String, keys: inout [CALayer]) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(x: 0, y: top - inset, width: width, height: inset)
        let zone = min(keyZoneWidth, width - rightStart)
        let keyStart = width - zone
        let bandTop = min(keyBandTop, inset), bandBottom = min(keyBandBottom, inset)
        // Nothing black goes under a key layer, since its backdrop would sample it.
        for rect in [CGRect(x: 0, y: 0, width: keyStart, height: inset),
                     CGRect(x: keyStart, y: 0, width: zone, height: inset - bandBottom),
                     CGRect(x: keyStart, y: inset - bandTop, width: zone, height: bandTop)] {
            container.addSublayer(Self.blackLayer(rect))
        }
        if let key = lockKey.makeLayer(frame: CGRect(x: keyStart, y: inset - bandBottom, width: zone,
                                                     height: bandBottom - bandTop), name: "\(name)-lock") {
            container.addSublayer(key)
            keys.append(key)
        }
        return container
    }

    /// The whole menu bar keyed on both sides of the notch, and black over the notch. With
    /// no notch, `leftEnd` and `rightStart` meet and the black part is empty.
    private func makeMenuBarLayout(size: CGSize, leftEnd: CGFloat, rightStart: CGFloat,
                                   name: String, keys: inout [CALayer]) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)
        if rightStart > leftEnd {
            container.addSublayer(Self.blackLayer(CGRect(x: leftEnd, y: 0, width: rightStart - leftEnd, height: size.height)))
        }
        for (side, rect) in [CGRect(x: 0, y: 0, width: leftEnd, height: size.height),
                             CGRect(x: rightStart, y: 0, width: size.width - rightStart, height: size.height)].enumerated() {
            guard let key = menuBarKey.makeLayer(frame: rect, name: "\(name)-menu-\(side)") else { continue }
            container.addSublayer(key)
            keys.append(key)
        }
        return container
    }

    private static func blackLayer(_ frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    private static func setting(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.double(forKey: key) : fallback
    }
}

/// How a backdrop is keyed: each channel above `threshold` counts as glyph. With
/// `anyChannel`, one such channel makes a pixel glyph; otherwise all three must be.
struct BackdropKey {
    let gain: Double
    let threshold: Double
    let anyChannel: Bool

    /// A backdrop layer whose filters give opaque black for background and transparency
    /// for glyphs, so whatever is beneath shows through only where it's bright. The first
    /// matrix thresholds each channel; the second sets alpha from their sum. Nil if the
    /// private Core Animation classes are missing.
    @MainActor
    func makeLayer(frame: CGRect, name: String) -> CALayer? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let threshold = Self.colorMatrix(perChannelGain: Float(gain), threshold: Float(threshold)),
              let alpha = Self.colorMatrix([0, 0, 0, 0, 0,
                                            0, 0, 0, 0, 0,
                                            0, 0, 0, 0, 0,
                                            // All three above: sum 3 → alpha 0. Any above: sum ≥ 1 → alpha 0.
                                            -1, -1, -1, 0, anyChannel ? 1 : 3]) else { return nil }
        let layer = backdropClass.init()
        layer.frame = frame
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(true, forKey: "enabled")
        layer.setValue(1.0, forKey: "scale")
        layer.setValue(name, forKey: "groupName")
        layer.filters = [threshold, alpha]
        return layer
    }

    private static func colorMatrix(perChannelGain k: Float, threshold t: Float) -> NSObject? {
        colorMatrix([k, 0, 0, 0, -k * t,
                     0, k, 0, 0, -k * t,
                     0, 0, k, 0, -k * t,
                     0, 0, 0, 1, 0])
    }

    /// A Core Animation color-matrix filter: 20 values in row order R, G, B, A, with the
    /// fifth column the bias.
    private static func colorMatrix(_ values: [Float]) -> NSObject? {
        var values = values
        let matrix = NSValue(bytes: &values, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "colorMatrix")?
                .takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue(matrix, forKey: "inputColorMatrix")
        return filter
    }
}

/// Borderless windows still get pushed below the menu bar; the strip has to cover it.
private final class StripWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The private SkyLight calls for the strips' spaces and the menu bar's state, loaded at run time.
@MainActor
private struct SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    private typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void
    private typealias CoordinatedCenter = @convention(c) () -> Unmanaged<AnyObject>?
    private typealias SpaceMenuBarReveal = @convention(c) (UInt64) -> Double
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceCopyValues = @convention(c) (Int32, UInt64) -> Unmanaged<CFDictionary>?
    private typealias ManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias DisplayForSpace = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?

    private let connection: Int32
    private let spaceCreate: SpaceCreate?
    private let setLevel: SpaceSetAbsoluteLevel?
    private let showSpaces: Spaces?
    private let hideSpaces: Spaces?
    private let addWindows: SpaceAddWindows?
    private let spaceDestroy: SpaceDestroy?
    private let menuBarRevealOfSpace: SpaceMenuBarReveal?
    private let spacesForWindows: SpacesForWindows?
    private let spaceCopyValues: SpaceCopyValues?
    private let managedDisplaySpaces: ManagedDisplaySpaces?
    private let displayForSpace: DisplayForSpace?
    /// A process-local center on which SkyLight posts menu bar reveal changes.
    let coordinatedNotificationCenter: NotificationCenter?
    let menuBarRevealNotification: Notification.Name?
    /// The absolute level macOS gives lock-screen notifications: above the lock screen
    /// (300) and the menu bar, below the camera and microphone indicator (800).
    let lockScreenNotificationLevel: Int32

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        connection = load("SLSMainConnectionID", as: MainConnectionID.self)?() ?? 0
        spaceCreate = load("SLSSpaceCreate", as: SpaceCreate.self)
        setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self)
        showSpaces = load("SLSShowSpaces", as: Spaces.self)
        hideSpaces = load("SLSHideSpaces", as: Spaces.self)
        addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindows.self)
        spaceDestroy = load("SLSSpaceDestroy", as: SpaceDestroy.self)
        lockScreenNotificationLevel = dlsym(handle, "kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock")?
            .assumingMemoryBound(to: Int32.self).pointee ?? 400
        menuBarRevealOfSpace = load("SLSGetSpaceMenuBarReveal", as: SpaceMenuBarReveal.self)
        spacesForWindows = load("SLSCopySpacesForWindows", as: SpacesForWindows.self)
        spaceCopyValues = load("SLSSpaceCopyValues", as: SpaceCopyValues.self)
        managedDisplaySpaces = load("SLSCopyManagedDisplaySpaces", as: ManagedDisplaySpaces.self)
        displayForSpace = load("SLSCopyManagedDisplayForSpace", as: DisplayForSpace.self)
        coordinatedNotificationCenter = load("SLSCoordinatedLocalNotificationCenter", as: CoordinatedCenter.self)?()?
            .takeUnretainedValue() as? NotificationCenter
        menuBarRevealNotification = dlsym(handle, "kSLSCoordinatedSpaceMenuBarRevealChangedNotificationName")
            .map { Notification.Name($0.assumingMemoryBound(to: Unmanaged<CFString>.self).pointee.takeUnretainedValue() as String) }
    }

    /// The UUID SkyLight uses for a display.
    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The UUID of the display a Space is on. With "Displays have separate Spaces" off,
    /// SkyLight names the one display "Main".
    func display(of space: UInt64) -> String? {
        guard let display = displayForSpace?(connection, space)?.takeRetainedValue() as String? else { return nil }
        return display == "Main" ? Self.uuid(of: CGMainDisplayID()) : display
    }

    /// The desktop or full-screen Space a menu bar's own Space belongs to.
    func parentSpace(of space: UInt64) -> UInt64? {
        let values = spaceCopyValues?(connection, space)?.takeRetainedValue() as? [String: Any]
        return (values?["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    /// How far a Space's menu bar is out, 0 (hidden) to 1. This holds for Spaces that aren't
    /// showing too (a desktop behind a full-screen app reads 1), unlike
    /// `SLSIsMenuBarVisibleOnSpace`, which is false for every Space but the current one.
    func menuBarReveal(of space: UInt64) -> Double {
        menuBarRevealOfSpace?(space) ?? 1
    }

    /// The Spaces a window is in.
    func spaces(of window: NSWindow) -> [UInt64] {
        let list = [NSNumber(value: window.windowNumber)] as CFArray
        return (spacesForWindows?(connection, 7, list)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    /// Every desktop and full-screen Space, with its display's UUID.
    func userSpaces() -> [(display: String, space: UInt64, fullScreen: Bool)] {
        guard let displays = managedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result: [(display: String, space: UInt64, fullScreen: Bool)] = []
        for entry in displays {
            guard var display = entry["Display Identifier"] as? String else { continue }
            // With "Displays have separate Spaces" off, the one entry is named "Main".
            if display == "Main", let main = Self.uuid(of: CGMainDisplayID()) { display = main }
            for space in entry["Spaces"] as? [[String: Any]] ?? [] {
                // 0 is a desktop, 4 a full-screen Space.
                guard let type = (space["type"] as? NSNumber)?.intValue, type == 0 || type == 4,
                      let id = ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value else { continue }
                result.append((display, id, type == 4))
            }
        }
        return result
    }

    var isAvailable: Bool {
        connection != 0 && spaceCreate != nil && setLevel != nil && showSpaces != nil
            && hideSpaces != nil && addWindows != nil && spaceDestroy != nil
    }

    func createSpace(level: Int32) -> UInt64 {
        guard let spaceCreate, let setLevel else { return 0 }
        let space = spaceCreate(connection, 1, nil)
        setLevel(connection, space, level)
        return space
    }

    func show(_ space: UInt64) { showSpaces?(connection, [NSNumber(value: space)] as CFArray) }
    func hide(_ space: UInt64) { hideSpaces?(connection, [NSNumber(value: space)] as CFArray) }
    func destroy(_ space: UInt64) { spaceDestroy?(connection, space) }

    /// Flag 7 moves the window out of every other space.
    func add(_ window: NSWindow, to space: UInt64) {
        addWindows?(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }
}
