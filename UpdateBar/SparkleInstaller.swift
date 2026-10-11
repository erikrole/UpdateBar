import AppKit
@preconcurrency import Sparkle

/// Installs a Sparkle app's update in place, without opening the app.
///
/// Sparkle 2 can update a bundle other than the one running it: the target app is
/// passed as the host bundle, so Sparkle reads that app's own feed and verifies the
/// download against that app's own `SUPublicEDKey` before installing. Apps without
/// an EdDSA key are never offered this path (see `InstalledApp.hasSparkleEDKey`).
@MainActor
final class SparkleInstaller {
    enum Outcome: Sendable {
        case installed
        case failure(String)
    }

    /// Keeps each in-flight session alive until Sparkle finishes with it.
    private static var sessions: [String: SparkleInstaller] = [:]

    private let app: InstalledApp
    private let driver: SilentUserDriver
    private let delegate: InstallDelegate
    private var updater: SPUUpdater?

    private init(app: InstalledApp, wasRunning: Bool, progress: @escaping @MainActor (String) -> Void) {
        self.app = app
        driver = SilentUserDriver(appName: app.name, progress: progress)
        delegate = InstallDelegate(relaunch: wasRunning)
    }

    static func install(_ app: InstalledApp, progress: @escaping @MainActor (String) -> Void) async -> Outcome {
        guard sessions[app.bundleIdentifier] == nil else { return .failure("An update for \(app.name) is already running.") }
        guard let bundle = Bundle(url: app.url) else { return .failure("Couldn't read \(app.name)'s bundle.") }

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
        let session = SparkleInstaller(app: app, wasRunning: wasRunning, progress: progress)
        sessions[app.bundleIdentifier] = session
        defer { sessions[app.bundleIdentifier] = nil }

        return await withCheckedContinuation { continuation in
            session.driver.onFinish = { outcome in continuation.resume(returning: outcome) }
            let updater = SPUUpdater(
                hostBundle: bundle,
                applicationBundle: bundle,
                userDriver: session.driver,
                delegate: session.delegate
            )
            session.updater = updater
            do {
                try updater.start()
                progress("Checking \(app.name)'s feed…")
                updater.checkForUpdates()
            } catch {
                session.driver.finish(.failure(error.localizedDescription))
            }
        }
    }
}

/// Answers Sparkle's prompts the way a person clicking "Install" would, and reports
/// progress back to the row instead of showing Sparkle's windows.
@MainActor
private final class SilentUserDriver: NSObject, SPUUserDriver {
    var onFinish: ((SparkleInstaller.Outcome) -> Void)?
    private let appName: String
    private let progress: @MainActor (String) -> Void
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var lastPercent = -1
    private var installed = false

    init(appName: String, progress: @escaping @MainActor (String) -> Void) {
        self.appName = appName
        self.progress = progress
    }

    func finish(_ outcome: SparkleInstaller.Outcome) {
        guard let onFinish else { return }
        self.onFinish = nil
        onFinish(outcome)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Never opt the target app into extra automatic checks or profile sharing.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        progress("Downloading \(appcastItem.displayVersionString)…")
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finish(.failure("\(appName) says it's already up to date."))
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finish(.failure(error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        lastPercent = -1
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        let percent = min(100, Int(Double(receivedLength) / Double(expectedLength) * 100))
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress("Downloading… \(percent)%")
    }

    func showDownloadDidStartExtractingUpdate() {
        progress("Verifying and unpacking…")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        progress("Installing…")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        progress(applicationTerminated ? "Installing…" : "Waiting for \(appName) to quit…")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        installed = true
        acknowledgement()
        finish(.installed)
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // Sparkle calls this at the end of every session; anything still open here
        // ended without an install.
        finish(installed ? .installed : .failure("The update for \(appName) was cancelled."))
    }
}

private final class InstallDelegate: NSObject, SPUUpdaterDelegate {
    private let relaunch: Bool

    init(relaunch: Bool) {
        self.relaunch = relaunch
    }

    /// Stable releases only, whatever channel the app itself follows.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }

    /// Reopen the app afterwards only if it was open when the update started.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { relaunch }
}
