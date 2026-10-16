import AppKit

/// Whether the screen is locked, from loginwindow's distributed notifications, for every
/// controller that changes the lock screen. Each notification can arrive twice, so
/// observers should act only on a change.
@MainActor
final class ScreenLock: NSObject {
    static let shared = ScreenLock()

    // Testing aid for displays without a notch (a VM, say): `defaults write
    // dev.benjweaver.Blackout LockScreenTestInset -float 32` treats every screen as having that inset.
    static let testInsetKey = "LockScreenTestInset"

    private(set) var isLocked: Bool
    private var observers: [(Bool) -> Void] = []

    private override init() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        isLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(screenLocked),
                           name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(screenUnlocked),
                           name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    /// Calls `observer` with the new state on every lock and unlock notification, in the
    /// order observers were added.
    func observe(_ observer: @escaping (Bool) -> Void) {
        observers.append(observer)
    }

    @objc private func screenLocked() {
        isLocked = true
        observers.forEach { $0(true) }
    }

    @objc private func screenUnlocked() {
        isLocked = false
        observers.forEach { $0(false) }
    }
}
