import AppKit
import OSLog

/// Blacks out the notch row on the lock screen while leaving Apple's status icons visible.
///
/// No app can draw into loginwindow's lock screen, but a private SkyLight space at the
/// level macOS uses for lock-screen notifications sits above it. Blackout puts one strip
/// window per notched screen there. Most of the strip is plain black. Over the status
/// icons at the right edge it holds a backdrop layer, which WindowServer fills with what's
/// beneath it, run through a color matrix that turns anything darker than the glyphs into
/// opaque black and the glyphs themselves transparent. Blackout only ever adds black, so
/// the icons on screen are loginwindow's own pixels.
///
/// This relies on private SkyLight and Core Animation interfaces, loaded at run time. If
/// any is missing it does nothing.
@MainActor
final class LockScreenBackdropController: NSObject {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LockScreenBackdrop")
    private let skyLight = SkyLight()
    private var space: UInt64 = 0
    private var windows: [NSWindow] = []
    /// One per window, holding its black and key layers. Hidden while unlocked.
    private var containers: [CALayer] = []
    private var keyLayers: [CALayer] = []
    private var isWanted = false
    private var isLocked = false
    private var isShown = false
    /// Keeps the strip up briefly after unlock, then fades it out.
    private var unlockFade: Task<Void, Never>?

    // Tuning, measured on a 16-inch MacBook Pro's lock screen. loginwindow right-aligns its
    // icons 20 pt from the screen edge and centers their glyphs about 12.5–24 pt from the top.
    private var keyZoneWidth: CGFloat { Self.setting("LockScreenKeyZoneWidth", 150) }
    private var keyBandTop: CGFloat { Self.setting("LockScreenKeyBandTop", 11) }
    private var keyBandBottom: CGFloat { Self.setting("LockScreenKeyBandBottom", 26) }
    private var keyThreshold: Float { Float(Self.setting("LockScreenKeyThreshold", 0.25)) }
    private var keyGain: Float { Float(Self.setting("LockScreenKeyGain", 30)) }
    /// Measured on a 16-inch MacBook Pro: the desktop takes about 0.3 s to settle after unlock.
    private var unlockHold: Double { Self.setting("LockScreenUnlockHold", 0.5) }
    private static let unlockFadeDuration = 0.25
    // Testing aid for displays without a notch, shared with LockScreenController.
    private static let testInsetKey = "LockScreenTestInset"

    override init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(screenLocked),
                           name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(screenUnlocked),
                           name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(nudge),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        isLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Whether the feature is on. The space and windows exist only while it is.
    func update(wanted: Bool) {
        guard wanted != isWanted else { return }
        isWanted = wanted
        if wanted { setUp() } else { tearDown() }
    }

    private func setUp() {
        guard skyLight.isAvailable, NSClassFromString("CABackdropLayer") != nil,
              NSClassFromString("CAFilter") != nil else {
            log.error("Private interfaces missing; lock-screen backdrop is off")
            return
        }
        // The space is shown for as long as the feature is on, and the strips are hidden
        // inside it instead. A backdrop that first appears on the lock screen never starts
        // drawing on real hardware, though one already on screen keeps going.
        space = skyLight.createSpace(level: skyLight.lockScreenNotificationLevel)
        buildWindows()
        skyLight.show(space)
        reconcile()
        log.info("Lock-screen backdrop on (space \(self.space))")
    }

    private func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        containers = []
        keyLayers = []
        if space != 0 {
            skyLight.hide(space)
            skyLight.destroy(space)
            space = 0
        }
        isShown = false
        unlockFade?.cancel()
        unlockFade = nil
        log.info("Lock-screen backdrop off")
    }

    @objc private func screenLocked() {
        isLocked = true
        reconcile()
    }

    @objc private func screenUnlocked() {
        isLocked = false
        reconcile()
    }

    /// Geometry is read only while unlocked. While locked, something else (the no-notch
    /// display mode, say) may have removed the notch row, so the strips hide until it's back.
    @objc private func screensChanged() {
        guard isWanted, space != 0 else { return }
        if !isLocked { buildWindows() }
        reconcile()
    }

    private var notchRowPresent: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
            || UserDefaults.standard.double(forKey: Self.testInsetKey) > 0
    }

    /// Both lock notifications can arrive twice, so this only acts on a change.
    private func reconcile() {
        let wanted = isWanted && isLocked && notchRowPresent && !windows.isEmpty
        guard wanted != isShown else { return }
        isShown = wanted
        unlockFade?.cancel()
        unlockFade = nil
        if wanted {
            setContainers(hidden: false)
            // Commit again once the lock screen has settled, in case WindowServer missed the first.
            Task { @MainActor [weak self] in
                for delay in [0.3, 1.2] {
                    try? await Task.sleep(for: .seconds(delay))
                    self?.nudge()
                }
            }
        } else if isWanted && !isLocked {
            // The unlock notifications arrive as the desktop starts sliding back in, and for a
            // moment the menu bar strip shows wallpaper. Hold the black until it settles, then fade.
            unlockFade = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.unlockHold ?? 0))
                guard let self, !Task.isCancelled else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(Self.unlockFadeDuration)
                self.containers.forEach { $0.opacity = 0 }
                CATransaction.commit()
                try? await Task.sleep(for: .seconds(Self.unlockFadeDuration))
                guard !Task.isCancelled else { return }
                self.setContainers(hidden: true)
            }
        } else {
            setContainers(hidden: true)
        }
    }

    private func setContainers(hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containers.forEach {
            $0.isHidden = hidden
            $0.opacity = 1
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Recommits the key layers so WindowServer refreshes their backdrops, which it may
    /// not do on its own after the display wakes.
    @objc private func nudge() {
        guard isShown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in keyLayers {
            layer.filters = layer.filters
            layer.setNeedsDisplay()
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    // MARK: Windows

    private func buildWindows() {
        windows.forEach { $0.close() }
        windows = []
        containers = []
        keyLayers = []
        let testInset = UserDefaults.standard.double(forKey: Self.testInsetKey)
        for (index, screen) in NSScreen.screens.enumerated() {
            let frame = screen.frame
            let inset = testInset > 0 ? testInset : screen.safeAreaInsets.top
            guard inset > 0 else { continue }
            // The strip right of the notch; on a test display, everything right of a 200 pt
            // fake notch in the middle.
            let rightStart = screen.auxiliaryTopRightArea?.minX ?? (frame.midX + 100)
            let rect = CGRect(x: frame.minX, y: frame.maxY - inset, width: frame.width, height: inset)
            let zone = min(keyZoneWidth, frame.maxX - rightStart)
            let window = StripWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true // the Wi-Fi and input-source icons stay clickable
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = makeContent(size: rect.size, zone: zone, index: index)
            window.orderFrontRegardless()
            window.setFrame(rect, display: true)
            skyLight.add(window, to: space)
            windows.append(window)
            log.info("Screen \(index): strip \(rect.debugDescription, privacy: .public), key zone \(zone)")
        }
    }

    /// Black from the left edge through the notch, so screenshots show no gap under the
    /// camera; then the key zone, keyed only across the band the glyphs occupy.
    private func makeContent(size: CGSize, zone: CGFloat, index: Int) -> NSView {
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        let height = size.height
        let keyStart = size.width - zone
        let top = min(keyBandTop, height), bottom = min(keyBandBottom, height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let container = CALayer()
        container.frame = view.bounds
        container.isHidden = !isShown
        // Layer coordinates run from the bottom. Nothing black goes under the key layer,
        // since its backdrop would sample it.
        for rect in [CGRect(x: 0, y: 0, width: keyStart, height: height),
                     CGRect(x: keyStart, y: 0, width: zone, height: height - bottom),
                     CGRect(x: keyStart, y: height - top, width: zone, height: top)] {
            let black = CALayer()
            black.frame = rect
            black.backgroundColor = NSColor.black.cgColor
            container.addSublayer(black)
        }
        let key = makeKeyLayer(frame: CGRect(x: keyStart, y: height - bottom, width: zone, height: bottom - top),
                               name: "BlackoutLockScreen-\(index)")
        container.addSublayer(key)
        view.layer?.addSublayer(container)
        CATransaction.commit()
        containers.append(container)
        keyLayers.append(key)
        return view
    }

    /// A backdrop whose filters give opaque black wherever any channel of what's beneath
    /// is below the threshold, and transparency where all three are above it. Two matrices:
    /// the first thresholds each channel, the second sets alpha from their sum.
    private func makeKeyLayer(frame: CGRect, name: String) -> CALayer {
        let k = keyGain, t = keyThreshold
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return CALayer() }
        let layer = backdropClass.init()
        layer.frame = frame
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(true, forKey: "enabled")
        layer.setValue(1.0, forKey: "scale")
        layer.setValue(name, forKey: "groupName")
        layer.filters = [
            Self.colorMatrix([k, 0, 0, 0, -k * t,
                              0, k, 0, 0, -k * t,
                              0, 0, k, 0, -k * t,
                              0, 0, 0, 1, 0]),
            Self.colorMatrix([0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0,
                              -1, -1, -1, 0, 3]),
        ].compactMap { $0 }
        return layer
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

    private static func setting(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.double(forKey: key) : fallback
    }
}

/// Borderless windows still get pushed below the menu bar; the strip has to cover it.
private final class StripWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The private SkyLight calls for a space above the lock screen, loaded at run time.
@MainActor
private struct SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    private typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void

    private let connection: Int32
    private let spaceCreate: SpaceCreate?
    private let setLevel: SpaceSetAbsoluteLevel?
    private let showSpaces: Spaces?
    private let hideSpaces: Spaces?
    private let addWindows: SpaceAddWindows?
    private let spaceDestroy: SpaceDestroy?
    /// The absolute level macOS gives lock-screen notifications: above the lock screen
    /// (300), below the camera and microphone indicator (800).
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
