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


    init() {
        isEnabled = defaults.object(forKey: "enabled") as? Bool ?? true
        scope = DisplayScope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .allDisplays
        roundCorners = defaults.object(forKey: "roundCorners") as? Bool ?? false
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }
}
