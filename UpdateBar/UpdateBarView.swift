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
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showingSettings ? "Settings" : headline)
                    .font(.headline)
                Text(subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let banner = store.banner, !showingSettings {
                    Text(banner.text)
                        .font(.caption)
                        .foregroundStyle(banner.isWarning ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
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
                .accessibilityLabel("Check now")
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: showingSettings ? "xmark" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help(showingSettings ? "Close settings" : "Settings")
                .accessibilityLabel(showingSettings ? "Close settings" : "Settings")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headline: String { store.statusSummary }

    private var subheadline: String {
        guard let lastChecked = store.lastChecked else { return "Scanning your apps…" }
        let relative = lastChecked.formatted(.relative(presentation: .named))
        return "\(store.appCount) apps scanned · \(relative)"
    }

    private var footer: some View {
        HStack {
            if store.inPlaceUpdateCount > 1 && !showingSettings {
                Button("Update all (\(store.inPlaceUpdateCount))") {
                    store.updateAllInPlace()
                }
                .controlSize(.small)
                .disabled(!store.canInstallUpdates || store.isChecking)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .disabled(!store.runningActions.isEmpty)
                .help(store.runningActions.isEmpty ? "Quit UpdateBar" : "Wait for the current update to finish")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty && store.requestedTools.isEmpty && store.dependencyTools.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text(store.lastChecked == nil ? "Looking for updates…" : (store.failures.isEmpty ? "No updates right now" : "Check incomplete"))
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
                            canInstall: store.canInstallUpdates && !store.isChecking,
                            message: store.actionMessages[row.id],
                            toggle: { expanded = expanded == row.id ? nil : row.id },
                            perform: { store.perform(row) },
                            skip: { store.skip(row) },
                            ignore: { store.ignore(row) }
                        )
                        Divider().padding(.leading, 56)
                    }
                    if !store.requestedTools.isEmpty || !store.dependencyTools.isEmpty {
                        toolsSection
                    }
                    if !store.failures.isEmpty {
                        failureDisclosure.padding(16)
                    }
                }
            }
        }
    }

    // MARK: - Command-line tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Command-line tools")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if store.toolRun == nil {
                    Button("Upgrade all (\(store.tools.count))") { store.upgradeAllTools() }
                        .controlSize(.small)
                        .disabled(!store.canInstallUpdates || store.isChecking)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if let run = store.toolRun {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: run.fraction)
                        .progressViewStyle(.linear)
                        .animation(.easeOut(duration: 0.3), value: run.fraction)
                    Text(run.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            if let message = store.actionMessages[UpdateStore.allToolsID] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
            }

            ForEach(store.requestedTools) { tool in
                ToolRow(
                    tool: tool,
                    stage: store.stage(of: tool),
                    canUpgrade: store.canInstallUpdates && !store.isChecking,
                    message: store.actionMessages["formula|\(tool.name)"],
                    upgrade: { store.upgrade(tool) }
                )
            }

            if !store.dependencyTools.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.dependencyTools) { tool in
                            HStack(spacing: 6) {
                                Text("\(tool.name)  \(tool.installedVersion) → \(tool.latestVersion)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if let stage = store.stage(of: tool) {
                                    StageBadge(stage: stage, compact: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text("\(store.dependencyTools.count) dependencies, included in Upgrade all")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
                        .textSelection(.enabled)
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
    let canInstall: Bool
    let message: String?
    let toggle: () -> Void
    let perform: () -> Void
    let skip: () -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppIcon(app: row.app)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.app.name).font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(versionLine)
                        Text("·")
                        Text(row.update.source.label)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isRunning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(message ?? "Updating")
                } else {
                    Button(actionTitle, action: perform)
                        .controlSize(.small)
                        .disabled(row.requiresInstallerReservation && !canInstall)
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

            Button(action: toggle) {
                Label(isExpanded ? "Hide details" : "Release notes and options", systemImage: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.leading, 42)
            .accessibilityLabel("\(isExpanded ? "Hide" : "Show") details for \(row.app.name)")

            if isExpanded {
                details.padding(.leading, 42)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var versionLine: String {
        if let channel = row.update.channel {
            return "\(row.app.displayVersion) → \(row.update.version) \(channel)"
        }
        return "\(row.app.displayVersion) → \(row.update.version)"
    }

    private var actionTitle: String {
        switch row.update.action {
        case .brewUpgrade, .sparkleInstall, .dmgInstall, .archiveInstall: "Update"
        case .pkgInstall: "Install…"
        case .openAppStore: "App Store"
        case .launchApp: UpdateStore.updatePage(for: row.app.bundleIdentifier) == nil ? "Open" : "Update"
        case .openURL: "Download"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .pkgInstall = row.update.action {
                Text("Downloads and verifies the package, then opens Apple’s Installer. Finish the installation there and check again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

/// A package's place in a running brew upgrade: waiting, a live spinner with the
/// current step, or a check mark.
private struct StageBadge: View {
    let stage: BrewStage
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            switch stage {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.tertiary)
            case .downloading, .installing:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if !compact || stage.isActive {
                Text(stage.label)
                    .foregroundStyle(stage == .done ? .green : (stage == .queued ? .secondary : .primary))
            }
        }
        .font(.caption)
        .frame(minWidth: compact ? nil : 90, alignment: .trailing)
        .animation(.easeOut(duration: 0.2), value: stage)
    }
}

private struct ToolRow: View {
    let tool: ToolUpdate
    let stage: BrewStage?
    let canUpgrade: Bool
    let message: String?
    let upgrade: () -> Void

    private var toolDetail: String {
        var parts = ["\(tool.installedVersion) → \(tool.latestVersion)"]
        if tool.isRebuild { parts.append("rebuild") }
        if let summary = tool.summary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if tool.isRebuild {
                            Text(tool.name)
                                .help("Same release, rebuilt by Homebrew against newer libraries.")
                        } else {
                            Text(tool.name)
                        }
                    }
                    .font(.body.weight(.medium).monospaced())
                    .lineLimit(1)
                    Text(toolDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let stage {
                    StageBadge(stage: stage)
                } else {
                    Button("Upgrade", action: upgrade)
                        .controlSize(.small)
                        .disabled(!canUpgrade)
                }
            }
            .contextMenu {
                if let homepage = tool.homepage {
                    Button("Open Homepage") { NSWorkspace.shared.open(homepage) }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct SettingsView: View {
    @AppStorage(SelfUpdate.autoUpdateKey) private var autoUpdate = true
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

            Section("UpdateBar") {
                Toggle("Update UpdateBar automatically", isOn: $autoUpdate)
                Button("Check for UpdateBar Updates…") { SelfUpdate.checkNow() }
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

/// Load an icon once per app/version, outside SwiftUI body evaluation. Progress
/// messages can redraw a row frequently without repeating Launch Services I/O.
@MainActor
private struct AppIcon: View {
    let app: InstalledApp
    @State private var icon: NSImage?
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "app").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: 32, height: 32)
        .task(id: app) {
            let key = "\(app.url.path)|\(app.displayVersion)|\(app.buildVersion ?? "")" as NSString
            if let cached = Self.cache.object(forKey: key) { icon = cached }
            else {
                let source = NSWorkspace.shared.icon(forFile: app.url.path)
                let loaded = IconThumbnail.fitted(from: source)
                Self.cache.setObject(loaded, forKey: key, cost: 64 * 64 * 4)
                icon = loaded
            }
        }
    }
}

/// A 32-point bitmap. `icon(forFile:)` keeps every size in the .icns, which is
/// far more memory than a menu row needs.
@MainActor
enum IconThumbnail {
    static func fitted(from source: NSImage, points: CGFloat = 32) -> NSImage {
        let pixels = max(1, Int((points * 2).rounded()))
        let empty = NSImage(size: NSSize(width: points, height: points))
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: pixels * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return empty }
        let previous = NSGraphicsContext.current
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        graphics.imageInterpolation = .high
        NSGraphicsContext.current = graphics
        // The context is pixel-sized. Drawing in points would leave the icon in
        // one corner of a mostly empty bitmap.
        source.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        NSGraphicsContext.current = previous
        guard let cgImage = context.makeImage() else { return empty }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: points, height: points))
        return image
    }
}
