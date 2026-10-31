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

            PreviousVersionsSection()

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
                if !store.snoozedUntil.isEmpty {
                    Button("Show \(store.snoozedUntil.count) snoozed updates now") { store.clearSnoozes() }
                        .buttonStyle(.link)
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

/// Apps replaced by an in-place update in the last two weeks, each with a Restore button.
private struct PreviousVersionsSection: View {
    @State private var entries: [PreviousVersions.Entry] = []
    @State private var message: String?
    @State private var confirming: PreviousVersions.Entry?

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("None. When Refresh replaces an app it downloaded itself, the old copy is kept here for two weeks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.name) \(entry.version)")
                        Text("Replaced \(entry.savedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { confirming = entry }
                        .buttonStyle(.link)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Previous versions")
        }
        .onAppear { entries = PreviousVersions.standard.entries() }
        .confirmationDialog(
            "Restore \(confirming?.name ?? "") \(confirming?.version ?? "")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { entry in
            Button("Restore") { restore(entry) }
        } message: { _ in
            Text("The current copy is kept here instead, so you can switch back. Some apps can't read settings or documents saved by a newer version.")
        }
    }

    private func restore(_ entry: PreviousVersions.Entry) {
        do {
            try PreviousVersions.standard.restore(entry)
            message = "Restored \(entry.name) \(entry.version). It will show as outdated on the next check; skip that version to keep it."
        } catch let failure as PreviousVersions.Failure {
            message = failure.message
        } catch {
            message = error.localizedDescription
        }
        entries = PreviousVersions.standard.entries()
    }
}
