import AppUpdater
import SwiftUI

struct RefreshSettingsView: View {
    @AppStorage(SelfUpdate.autoUpdateKey) private var autoUpdate = true
    @AppStorage(SelfUpdate.installOnQuitKey) private var installOnQuit = false
    @Bindable var store: UpdateStore
    @Bindable var launchAtLogin: LaunchAtLoginController
    @State private var recoveryTarget: InstalledApp?
    @State private var recoveryMessage: String?

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
                Toggle("Download Refresh updates automatically", isOn: $autoUpdate)
                Toggle("Install Refresh updates on quit", isOn: $installOnQuit)
                Button(SelfUpdate.updater.menuTitle ?? "Check for Refresh Updates…") { SelfUpdate.updater.performMenuAction() }
            }

            if !managedApps.isEmpty {
                Section("App update status") {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ForEach(managedApps) { app in
                            statusRow(app, now: context.date)
                        }
                    }
                    if let recoveryMessage {
                        Text(recoveryMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
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
        .confirmationDialog("Restore the previous app version?", isPresented: Binding(
            get: { recoveryTarget != nil }, set: { if !$0 { recoveryTarget = nil } }
        ), presenting: recoveryTarget) { app in
            Button("Restore Previous Version", role: .destructive) { restore(app) }
        } message: { app in
            Text("Quit \(app.name) first. This restores the verified app bundle. Your app data stays in place.")
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 540)
    }

    private var managedApps: [InstalledApp] {
        store.installedApps.filter { GitHubChecker.selfUpdatingApps.contains($0.bundleIdentifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func statusRow(_ app: InstalledApp, now: Date) -> some View {
        let snapshot = AppUpdater.Status.read(bundleIdentifier: app.bundleIdentifier)
        let fresh = snapshot?.installedVersion == app.displayVersion
        return LabeledContent(app.name) {
            VStack(alignment: .trailing, spacing: 3) {
                Text("Installed \(app.displayVersion)")
                if let snapshot, fresh {
                    Text("Latest checked \(snapshot.latestVersion)")
                    Text("Checked \(snapshot.lastSuccessfulCheck.formatted(.relative(presentation: .named)))")
                    if snapshot.restartRequired, now.timeIntervalSince(snapshot.lastSuccessfulCheck) < 24 * 3600 {
                        Text("Restart to update")
                    }
                } else {
                    Text("Waiting for a check from this version")
                }
                if AppUpdater.hasUnconfirmedUpdate(at: app.url) {
                    Button("Restore Previous Version…") { recoveryTarget = app }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func restore(_ app: InstalledApp) {
        recoveryMessage = nil
        Task {
            do {
                try await AppUpdater.restoreUnconfirmedUpdate(at: app.url, bundleIdentifier: app.bundleIdentifier)
                recoveryMessage = "Restored the previous version of \(app.name)."
                await store.checkNow(refreshAfterCurrent: true)
            } catch {
                recoveryMessage = error.localizedDescription
            }
        }
    }
}
