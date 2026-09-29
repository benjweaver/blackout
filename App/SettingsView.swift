import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Hide the notch", isOn: $settings.isEnabled)

            Picker("Show black bar on", selection: $settings.scope) {
                ForEach(DisplayScope.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!settings.isEnabled)

            Toggle("Round the desktop corners", isOn: $settings.roundCorners)
                .disabled(!settings.isEnabled)

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in setLogin(wanted) }
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
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLogin(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
