import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    var body: some View {
        Form {
            Toggle("Hide the notch", isOn: $settings.isEnabled)
            // An opaque menu bar covers the bar, and no app can draw beneath it.
            if settings.isEnabled && reduceTransparency {
                Label("Reduce transparency is on, so macOS draws the menu bar over Blackout's bar and the notch stays visible. Turn it off in System Settings → Accessibility → Display.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            Picker("Show black bar on", selection: $settings.scope) {
                ForEach(DisplayScope.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!settings.isEnabled)

            Toggle("Round the desktop corners", isOn: $settings.roundCorners)
                .disabled(!settings.isEnabled)

            Section {
                // A custom binding rather than onChange, so correcting the toggle after a
                // failure doesn't register or unregister again.
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { setLogin($0) }))
                Toggle("Show icon in menu bar", isOn: $settings.showMenuBarIcon)
            } footer: {
                Text(settings.showMenuBarIcon
                     ? "Blackout runs quietly in the background."
                     : "With the icon hidden, open Blackout from Applications to bring this window back.")
                    .foregroundStyle(.secondary)
            }
            if let loginError {
                Text(loginError).foregroundStyle(.red)
            }
            Section {
                Button("Quit Blackout") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        // Login Items can change in System Settings while this window is closed or behind
        // it, so read them again whenever the window comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if launchAtLogin { loginError = nil }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    }

    private func setLogin(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Blackout in System Settings → General → Login Items." : nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
