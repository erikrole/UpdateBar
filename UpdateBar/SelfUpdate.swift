import AppKit
import AppUpdater
import Observation

/// One updater for the lifetime of the host.
@MainActor
enum SelfUpdate {
    @Observable final class MenuState {
        var title = "Check for Refresh Updates…"
    }

    static let menuState = MenuState()
    static var busyReason: @MainActor @Sendable () -> String? = { nil }
    static let updater: AppUpdater = {
        let updater = AppUpdater(.init(
            repository: "erikrole/UpdateBar", assetName: "UpdateBar.zip",
            busyReason: { busyReason() }, postUpdate: .quiet,
            autoInstall: { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true },
            installOnQuit: { UserDefaults.standard.bool(forKey: installOnQuitKey) }
        ))
        updater.onStateChange = { _ in
            let next = updater.menuTitle ?? "Check for Refresh Updates…"
            if menuState.title != next { menuState.title = next }
        }
        return updater
    }()

    /// The Settings switch; on unless turned off.
    nonisolated static let autoUpdateKey = "autoUpdate"
    nonisolated static let installOnQuitKey = "installUpdatesOnQuit"

    static var isPreparing: Bool { updater.isInstalling && !updater.isAwaitingRelaunch }

    static func checkOnLaunch() {
        #if !DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        updater.checkOnLaunch()
        #endif
    }

    static func checkNow() { updater.checkNow() }
}
