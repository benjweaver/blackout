import AppKit
import OSLog

/// Switches each notched display to its "no-notch" mode while the screen is locked.
///
/// Nothing can be drawn over the lock screen usefully, but macOS offers a mode on
/// notched MacBooks that ends below the camera. The strip beside the notch is then
/// unused hardware, true black, and loginwindow lays out its wallpaper and icons below
/// it. The original mode comes back on unlock.
///
/// Modes are set for this app only, so macOS puts them back if Blackout quits or
/// crashes. This doesn't reach the login window at boot or the FileVault unlock screen,
/// since Blackout isn't running then.
@MainActor
final class LockScreenController: NSObject {
    /// Called after the original modes are back, so the overlay can rebuild for them.
    var onRestore: (() -> Void)?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LockScreen")
    private var isLocked = false
    private var isWanted = false
    private var savedModes: [CGDirectDisplayID: CGDisplayMode] = [:]

    override init() {
        super.init()
        isLocked = ScreenLock.shared.isLocked
        if isLocked { log.info("Already locked at launch") }
        ScreenLock.shared.observe { [weak self] locked in
            self?.log.info("\(locked ? "Lock" : "Unlock") notification received")
            self?.isLocked = locked
            self?.reconcile()
        }
    }

    /// Whether the feature is on: Blackout enabled and the setting set. Turning it off
    /// while locked puts the modes back.
    func update(wanted: Bool) {
        isWanted = wanted
        reconcile()
    }

    /// Both notifications can arrive twice, so this only acts when the state differs
    /// from what's applied.
    private func reconcile() {
        let applied = !savedModes.isEmpty
        if isLocked && isWanted && !applied {
            applyNoNotchModes()
        } else if !(isLocked && isWanted) && applied {
            restoreModes()
        }
    }

    private func applyNoNotchModes() {
        let start = ContinuousClock.now
        let override = UserDefaults.standard.double(forKey: ScreenLock.testInsetKey)
        var saved: [CGDirectDisplayID: CGDisplayMode] = [:]
        var targets: [(CGDirectDisplayID, CGDisplayMode)] = []
        for screen in NSScreen.screens {
            // Read before switching, since the inset is zero in the no-notch mode.
            let inset = override > 0 ? override : screen.safeAreaInsets.top
            guard inset > 0, let id = screen.displayID,
                  let current = CGDisplayCopyDisplayMode(id) else { continue }
            guard let target = Self.noNotchMode(for: id, current: current, inset: inset) else {
                log.error("No no-notch mode for display \(id) (inset \(inset), now \(Self.describe(current)))")
                continue
            }
            log.info("Display \(id): \(Self.describe(current)) -> \(Self.describe(target))")
            saved[id] = current
            targets.append((id, target))
        }
        guard !targets.isEmpty else { return }
        let error = configure(targets)
        let elapsed = ContinuousClock.now - start
        if error == .success {
            savedModes = saved
            log.info("Switched \(targets.count) display(s) in \(elapsed)")
        } else {
            log.error("Switching failed with CGError \(error.rawValue) after \(elapsed)")
        }
    }

    private func restoreModes() {
        let start = ContinuousClock.now
        let error = configure(savedModes.map { ($0.key, $0.value) })
        log.info("Restored \(self.savedModes.count) display(s), CGError \(error.rawValue), in \(ContinuousClock.now - start)")
        // Even on failure, forget the modes: retrying on every notification could loop,
        // and macOS restores them itself when Blackout quits.
        savedModes = [:]
        onRestore?()
    }

    /// The tallest mode shorter than `current` with the same width and pixel width,
    /// usable on the desktop, at the closest refresh rate. Notched panels list each size
    /// twice, with and without the strip beside the camera, and the strip isn't exactly
    /// `inset` tall, so the difference only has to be within half to twice the inset.
    private static func noNotchMode(for id: CGDirectDisplayID, current: CGDisplayMode,
                                    inset: CGFloat) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let range = Int((inset / 2).rounded(.down))...Int((inset * 2).rounded(.up))
        let candidates = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).filter {
            $0.width == current.width && $0.pixelWidth == current.pixelWidth
                && $0.isUsableForDesktopGUI() && range.contains(current.height - $0.height)
        }
        return candidates.min {
            let a = (current.height - $0.height, abs($0.refreshRate - current.refreshRate))
            let b = (current.height - $1.height, abs($1.refreshRate - current.refreshRate))
            return a < b
        }
    }

    /// For this app only, so the system reverts if Blackout quits or crashes.
    private func configure(_ modes: [(CGDirectDisplayID, CGDisplayMode)]) -> CGError {
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success else { return error }
        for (id, mode) in modes {
            error = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
            if error != .success {
                CGCancelDisplayConfiguration(config)
                return error
            }
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly)
    }

    private static func describe(_ mode: CGDisplayMode) -> String {
        "\(mode.width)x\(mode.height) (\(mode.pixelWidth)x\(mode.pixelHeight) px, \(mode.refreshRate) Hz)"
    }
}
