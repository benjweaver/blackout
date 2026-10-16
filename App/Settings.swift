import Combine
import Foundation

/// Which displays get the black bar.
enum DisplayScope: String, CaseIterable, Identifiable {
    case builtInOnly
    case allDisplays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtInOnly: "MacBook display only"
        case .allDisplays: "All displays"
        }
    }
}

/// What Blackout does on the lock screen of a notched display.
enum LockScreenStyle: String, CaseIterable, Identifiable {
    /// Black across the notch row, with Apple's status icons left showing.
    case blackBehindIcons
    /// Switch to the display mode that ends below the camera.
    case shrinkBelowCamera
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blackBehindIcons: "Black behind the icons"
        case .shrinkBelowCamera: "Shrink below the camera"
        case .off: "Leave as is"
        }
    }
}

/// User preferences, stored locally in UserDefaults. Nothing leaves the machine.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "enabled") }
    }
    @Published var scope: DisplayScope {
        didSet { defaults.set(scope.rawValue, forKey: "scope") }
    }
    @Published var roundCorners: Bool {
        didSet { defaults.set(roundCorners, forKey: "roundCorners") }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    @Published var lockScreenStyle: LockScreenStyle {
        didSet { defaults.set(lockScreenStyle.rawValue, forKey: "lockScreenStyle") }
    }

    init() {
        isEnabled = defaults.object(forKey: "enabled") as? Bool ?? true
        scope = DisplayScope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .allDisplays
        roundCorners = defaults.object(forKey: "roundCorners") as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        // Version 1.1's toggle: someone who turned it off keeps the lock screen as is.
        let legacyOff = defaults.object(forKey: "hideNotchOnLockScreen") as? Bool == false
        lockScreenStyle = LockScreenStyle(rawValue: defaults.string(forKey: "lockScreenStyle") ?? "")
            ?? (legacyOff ? .off : .blackBehindIcons)
    }
}
