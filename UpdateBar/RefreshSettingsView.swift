import SwiftUI

struct RefreshSettingsView: View {
    @AppStorage(SelfUpdate.autoUpdateKey) private var autoUpdate = true
    @Bindable var store: UpdateStore
    @Bindable var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Form {
            Section {
                FamilyHeader(title: "Refresh", subtitle: "App and tool updates")
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Notify me about new updates", isOn: $store.notificationsEnabled)
                Picker("Check every", selection: $store.checkIntervalHours) {
                    Text("Hour").tag(1)
                    Text("3 hours").tag(3)
                    Text("6 hours").tag(6)
                    Text("12 hours").tag(12)
                    Text("Day").tag(24)
                }
            }

            Section {
                Toggle("Show Homebrew command-line tools", isOn: $store.showsTools)
            }

            Section {
                if store.betaCapableApps.isEmpty {
                    Text("None of your apps publish betas through their update feed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.betaCapableApps) { app in
                        Toggle(app.name, isOn: Binding(
                            get: { store.isBetaEnabled(app.bundleIdentifier) },
                            set: { store.setBeta($0, for: app.bundleIdentifier) }
                        ))
                    }
                }
            } header: {
                Text("Beta updates")
            } footer: {
                Text("Apps listed here publish betas through Sparkle. Turn one on to be offered its betas as well as stable releases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh updates") {
                Toggle("Update Refresh automatically", isOn: $autoUpdate)
                Button("Check for Refresh Updates…") { SelfUpdate.checkNow() }
            }

            Section("Ignored apps") {
                if store.ignoredApps.isEmpty {
                    Text("None. Right-click an update to ignore its app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.ignoredApps.sorted(), id: \.self) { id in
                        HStack {
                            Text(store.ignoredAppNames[id] ?? id)
                            Spacer()
                            Button("Stop ignoring") { store.unignore(id) }
                                .buttonStyle(.link)
                        }
                    }
                }
                if !store.skippedVersions.isEmpty {
                    Button("Show \(store.skippedVersions.count) skipped versions again") {
                        store.clearSkippedVersions()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 540)
    }
}
