import AppKit
import Foundation

/// In-place app updates and the actions that open another app instead.
@MainActor
enum AppUpdateActions {
    static func perform(_ row: AppUpdate, store: UpdateStore) {
        let id = row.id
        guard !row.requiresInstallerReservation || (store.canInstallUpdates && !store.isChecking) else { return }
        store.actionMessages[id] = nil
        switch row.update.action {
        case .brewUpgrade, .sparkleInstall, .dmgInstall, .archiveInstall, .pkgInstall:
            install([row], on: store)
        case .openAppStore:
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/updates")!)
        case .launchApp:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak store] _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in store?.actionMessages[id] = message }
            }
            if let aboutPage = updatePage(for: row.app.bundleIdentifier) {
                // Browsers check for and apply updates when their About page opens.
                NSWorkspace.shared.open(
                    [aboutPage], withApplicationAt: row.app.url, configuration: configuration, completionHandler: completion
                )
            } else {
                NSWorkspace.shared.openApplication(
                    at: row.app.url, configuration: configuration, completionHandler: completion
                )
            }
        case let .openURL(url):
            NSWorkspace.shared.open(url)
        }
    }

    /// The page that makes a self-updating browser fetch its update right away.
    nonisolated static func updatePage(for bundleIdentifier: String) -> URL? {
        let pages = [
            "com.google.Chrome": "chrome://settings/help",
            "com.google.Chrome.beta": "chrome://settings/help",
            "com.google.Chrome.dev": "chrome://settings/help",
            "com.google.Chrome.canary": "chrome://settings/help",
            "com.microsoft.edgemac": "edge://settings/help",
            "com.brave.Browser": "brave://settings/help",
            "com.vivaldi.Vivaldi": "vivaldi://about",
        ]
        return pages[bundleIdentifier].flatMap(URL.init(string:))
    }

    static func updateAllInPlace(_ store: UpdateStore) {
        install(store.rows.filter(\.installsInPlace), on: store)
    }

    /// Runs every update that installs in place (Homebrew, Sparkle and signed DMGs), one at a time
    /// so brew doesn't lock against itself and installers don't compete.
    static func install(_ targets: [AppUpdate], on store: UpdateStore) {
        guard store.canInstallUpdates, !store.isChecking, !targets.isEmpty else { return }
        // Reserve the entire batch before yielding: buttons and queued tasks cannot
        // start a second installer or a competing Homebrew formula upgrade.
        let ids = targets.map(\.id)
        store.runningActions.formUnion(ids)
        for row in targets { store.actionMessages[row.id] = "Waiting…" }
        store.banner = nil
        Task {
            var released = false
            defer {
                if !released {
                    store.activeAppID = nil
                    store.runningActions.subtract(ids)
                }
            }
            var failed: [String] = []
            for row in targets {
                store.activeAppID = row.id
                store.actionMessages[row.id] = "Starting update…"
                let message = await store.installApp(row, store.betaChannels(for: row.id)) { status in
                    guard store.activeAppID == row.id else { return }
                    store.actionMessages[row.id] = status
                }
                store.activeAppID = nil
                if let message {
                    store.actionMessages[row.id] = message
                    failed.append(row.app.name)
                } else if case .pkgInstall = row.update.action {
                    // The installer window is the next step; leave its notice on the row.
                    store.actionMessages[row.id] = PKGInstaller.openedNotice
                } else {
                    store.actionMessages[row.id] = nil
                }
                // Keep the batch reserved until every installer has finished.
            }
            if failed.isEmpty {
                let packages = targets.filter { !$0.installsInPlace }.count
                let text = packages > 0
                    ? "Opened in Installer. Finish the installation there, then check again."
                    : "Updated \(targets.count) app\(targets.count == 1 ? "" : "s")"
                store.banner = UpdateStore.Banner(text: text, isWarning: false)
            } else {
                let updated = targets.count - failed.count
                let names = failed.joined(separator: ", ")
                let text = updated == 0
                    ? "Couldn't update \(names)"
                    : "Updated \(updated) of \(targets.count). \(names) still \(failed.count == 1 ? "needs" : "need") an update"
                store.banner = UpdateStore.Banner(text: text, isWarning: true)
            }
            store.activeAppID = nil
            store.runningActions.subtract(ids)
            released = true
            await store.checkNow(refreshAfterCurrent: true)
        }
    }

    static func installUpdate(
        _ row: AppUpdate, channels: Set<String>, progress: @escaping @MainActor (String) -> Void
    ) async -> String? {
        switch row.update.action {
        case let .brewUpgrade(token):
            return await BrewAppInstaller.install(row.app, token: token, progress: progress)
        case .sparkleInstall:
            if case let .failure(message) = await SparkleInstaller.install(row.app, channels: channels, progress: progress) {
                return message
            }
        case let .dmgInstall(url):
            if case let .failure(message) = await DMGInstaller.install(row.app, from: url, expectedTeamID: DMGInstaller.ownTeamID, progress: progress) {
                return message
            }
        case let .archiveInstall(url):
            if case let .failure(message) = await DMGInstaller.install(row.app, from: url, progress: progress) {
                return message
            }
        case let .pkgInstall(url):
            switch await PKGInstaller.install(row.app, from: url, progress: progress) {
            case .opened: break
            case let .failure(message): return message
            }
        default: break
        }
        return nil
    }
}

extension AppUpdate {
    /// Package preparation also reserves the installer, but requires a manual finish.
    var requiresInstallerReservation: Bool {
        if case .pkgInstall = update.action { return true }
        return installsInPlace
    }

    /// Whether UpdateBar can finish this update without a separate installer window.
    var installsInPlace: Bool {
        switch update.action {
        case .brewUpgrade, .sparkleInstall, .dmgInstall, .archiveInstall: true
        case .openAppStore, .launchApp, .openURL, .pkgInstall: false
        }
    }
}
