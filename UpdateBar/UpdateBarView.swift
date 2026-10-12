import AppKit
import SwiftUI

struct UpdateBarView: View {
    @Bindable var store: UpdateStore
    @Bindable var launchAtLogin: LaunchAtLoginController
    @State private var expanded: String?
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings {
                SettingsView(store: store, launchAtLogin: launchAtLogin)
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showingSettings ? "Settings" : headline)
                    .font(.headline)
                Text(subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isChecking {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.checkNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isChecking)
            .help("Check now")

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(showingSettings ? "Close settings" : "Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headline: String {
        switch store.pendingCount {
        case 0: store.lastChecked == nil ? "Checking for updates" : "Everything is up to date"
        case 1: "1 update available"
        default: "\(store.pendingCount) updates available"
        }
    }

    private var subheadline: String {
        guard let lastChecked = store.lastChecked else { return "Scanning your apps…" }
        let relative = lastChecked.formatted(.relative(presentation: .named))
        return "\(store.appCount) apps checked \(relative)"
    }

    private var footer: some View {
        HStack {
            if store.inPlaceUpdateCount > 1 && !showingSettings {
                Button("Update all (\(store.inPlaceUpdateCount))") {
                    store.updateAllInPlace()
                }
                .controlSize(.small)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: store.lastChecked == nil ? "hourglass" : "checkmark.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(store.lastChecked == nil ? "Looking for updates…" : "No updates right now")
                    .foregroundStyle(.secondary)
                if !store.failures.isEmpty {
                    failureDisclosure.padding(.horizontal, 16)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.rows) { row in
                        UpdateRow(
                            row: row,
                            isExpanded: expanded == row.id,
                            isRunning: store.runningActions.contains(row.id),
                            message: store.actionMessages[row.id],
                            toggle: { expanded = expanded == row.id ? nil : row.id },
                            perform: { store.perform(row) },
                            skip: { store.skip(row) },
                            ignore: { store.ignore(row) }
                        )
                        Divider().padding(.leading, 56)
                    }
                    if !store.failures.isEmpty {
                        failureDisclosure.padding(16)
                    }
                }
            }
        }
    }

    private var failureDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.failures) { failure in
                    Text("\(failure.subject) (\(failure.source.label)): \(failure.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(store.failures.count) couldn't be checked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UpdateRow: View {
    let row: AppUpdate
    let isExpanded: Bool
    let isRunning: Bool
    let message: String?
    let toggle: () -> Void
    let perform: () -> Void
    let skip: () -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.url.path))
                    .resizable()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.app.name).font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(row.app.displayVersion) → \(row.update.version)")
                        Text("·")
                        Label(row.update.source.label, systemImage: row.update.source.symbolName)
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(actionTitle, action: perform)
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .contextMenu {
                Button("Skip \(row.update.version)", action: skip)
                Button("Ignore \(row.app.name)", action: ignore)
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.app.url]) }
                if let url = row.update.releaseNotesURL {
                    Button("Open Release Page") { NSWorkspace.shared.open(url) }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.leading, 42)
            }

            if isExpanded {
                details.padding(.leading, 42)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var actionTitle: String {
        switch row.update.action {
        case .brewUpgrade, .sparkleInstall: "Update"
        case .openAppStore: "App Store"
        case .launchApp: UpdateStore.updatePage(for: row.app.bundleIdentifier) == nil ? "Open" : "Update"
        case .openURL: "Download"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let date = row.update.releaseDate {
                Text("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = row.update.releaseNotes {
                ScrollView {
                    Text(notes)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            } else {
                Text("No release notes from \(row.update.source.label).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !row.alsoReportedBy.isEmpty {
                Text("Also listed on \(row.alsoReportedBy.map(\.label).joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Skip this version", action: skip)
                Button("Ignore app", action: ignore)
                if let url = row.update.releaseNotesURL {
                    Button("Release page") { NSWorkspace.shared.open(url) }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

private struct SettingsView: View {
    @Bindable var store: UpdateStore
    @Bindable var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
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
        .frame(maxHeight: .infinity)
    }
}
