import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "menubar.rectangle",
                                     accessibilityDescription: "Blackout")
        item.menu = buildMenu()
        statusItem = item

        // Values arrive from the publishers before the properties change, so pass them through.
        settings.$isEnabled.combineLatest(settings.$scope, settings.$roundCorners)
            .sink { [weak self] enabled, scope, round in
                self?.overlay.update(enabled: enabled, scope: scope, roundCorners: round)
            }
            .store(in: &subscriptions)
        settings.$showMenuBarIcon
            .sink { [weak self] show in self?.statusItem?.isVisible = show }
            .store(in: &subscriptions)

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        if !Self.launchedAtLogin { showSettings() }
    }

    /// The settings window appears when a person opens Blackout, never when macOS
    /// starts it at login (the launch event says which).
    private static var launchedAtLogin: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Opening the app again while it runs (Finder, Spotlight) brings the window back,
    /// which is how you reach settings with the menu bar icon hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func refresh() {
        overlay.update(enabled: settings.isEnabled, scope: settings.scope, roundCorners: settings.roundCorners)
    }

    @objc private func showSettings() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Blackout"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Hide Notch", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.tag = 1
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Blackout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.state = settings.isEnabled ? .on : .off
    }
}
