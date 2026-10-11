import AppKit
import Foundation
import Observation
import UserNotifications

/// Owns the scan → check → resolve cycle, user preferences, and update actions.
@MainActor
@Observable
final class UpdateStore {
    private(set) var rows: [AppUpdate] = []
    private(set) var failures: [CheckFailure] = []
    private(set) var appCount = 0
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    private(set) var runningActions: Set<String> = []
    private(set) var actionMessages: [String: String] = [:]

    var checkIntervalHours: Int {
        didSet { defaults.set(checkIntervalHours, forKey: Keys.interval); scheduleTimer() }
    }
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notifications)
            if notificationsEnabled { requestNotificationPermission() }
        }
    }
    private(set) var ignoredApps: Set<String>
    private(set) var skippedVersions: [String: String]
    private(set) var ignoredAppNames: [String: String]

    private var lastResult = CheckerResult()
    private var installedApps: [InstalledApp] = []
    private var notifiedUpdateIDs: Set<String>
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let interval = "checkIntervalHours"
        static let notifications = "notificationsEnabled"
        static let ignored = "ignoredApps"
        static let ignoredNames = "ignoredAppNames"
        static let skipped = "skippedVersions"
        static let notified = "notifiedUpdateIDs"
        static let repositories = "githubRepositories"
    }

    init() {
        checkIntervalHours = defaults.object(forKey: Keys.interval) as? Int ?? 6
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        ignoredApps = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        ignoredAppNames = defaults.dictionary(forKey: Keys.ignoredNames) as? [String: String] ?? [:]
        skippedVersions = defaults.dictionary(forKey: Keys.skipped) as? [String: String] ?? [:]
        notifiedUpdateIDs = Set(defaults.stringArray(forKey: Keys.notified) ?? [])
    }

    var pendingCount: Int { rows.count }

    func start() {
        if notificationsEnabled { requestNotificationPermission() }
        scheduleTimer()
        Task { await checkNow() }
    }

    // MARK: - Checking

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let apps = await Task.detached(priority: .utility) { AppScanner().scan() }.value
        installedApps = apps
        appCount = apps.count

        let repositories = defaults.dictionary(forKey: Keys.repositories) as? [String: String] ?? [:]
        let checkers: [any UpdateChecker] = [
            AppStoreChecker(),
            SparkleChecker(),
            HomebrewChecker(),
            GitHubChecker(repositories: repositories),
        ]
        let combined = await withTaskGroup(of: CheckerResult.self) { group in
            for checker in checkers {
                group.addTask { await checker.check(apps) }
            }
            var combined = CheckerResult()
            for await result in group { combined.merge(result) }
            return combined
        }

        lastResult = combined
        failures = combined.failures.sorted { ($0.source, $0.subject) < ($1.source, $1.subject) }
        lastChecked = Date()
        resolve()
        notifyAboutNewUpdates()
    }

    private func resolve() {
        rows = UpdateResolver.resolve(
            apps: installedApps,
            result: lastResult,
            ignoredApps: ignoredApps,
            skippedVersions: skippedVersions
        )
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, checkIntervalHours) * 3600)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNow() }
        }
        timer?.tolerance = interval * 0.1
    }

    // MARK: - Skip and ignore

    func skip(_ row: AppUpdate) {
        skippedVersions[row.app.bundleIdentifier] = row.update.version
        defaults.set(skippedVersions, forKey: Keys.skipped)
        resolve()
    }

    func ignore(_ row: AppUpdate) {
        ignoredApps.insert(row.app.bundleIdentifier)
        ignoredAppNames[row.app.bundleIdentifier] = row.app.name
        defaults.set(Array(ignoredApps), forKey: Keys.ignored)
        defaults.set(ignoredAppNames, forKey: Keys.ignoredNames)
        resolve()
    }

    func unignore(_ bundleIdentifier: String) {
        ignoredApps.remove(bundleIdentifier)
        ignoredAppNames[bundleIdentifier] = nil
        defaults.set(Array(ignoredApps), forKey: Keys.ignored)
        defaults.set(ignoredAppNames, forKey: Keys.ignoredNames)
        resolve()
    }

    func clearSkippedVersions() {
        skippedVersions = [:]
        defaults.set(skippedVersions, forKey: Keys.skipped)
        resolve()
    }

    // MARK: - Actions

    func perform(_ row: AppUpdate) {
        let id = row.id
        actionMessages[id] = nil
        switch row.update.action {
        case let .brewUpgrade(token):
            runningActions.insert(id)
            Task {
                let outcome = await BrewRunner.upgrade(cask: token)
                runningActions.remove(id)
                switch outcome {
                case .success:
                    actionMessages[id] = nil
                    await checkNow()
                case let .failure(message):
                    actionMessages[id] = message
                }
            }
        case .sparkleInstall:
            runningActions.insert(id)
            Task {
                let outcome = await SparkleInstaller.install(row.app) { [weak self] status in
                    self?.actionMessages[id] = status
                }
                runningActions.remove(id)
                switch outcome {
                case .installed:
                    actionMessages[id] = nil
                    await checkNow()
                case let .failure(message):
                    actionMessages[id] = message
                }
            }
        case .openAppStore:
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/updates")!)
        case .launchApp:
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: row.app.url, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in self?.actionMessages[id] = message }
            }
        case let .openURL(url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Runs every update that installs in place (Homebrew and Sparkle), one at a time
    /// so brew doesn't lock against itself and installers don't compete.
    func updateAllInPlace() {
        let targets = rows.filter(\.installsInPlace)
        guard !targets.isEmpty else { return }
        Task {
            for row in targets {
                runningActions.insert(row.id)
                switch row.update.action {
                case let .brewUpgrade(token):
                    if case let .failure(message) = await BrewRunner.upgrade(cask: token) {
                        actionMessages[row.id] = message
                    }
                case .sparkleInstall:
                    let outcome = await SparkleInstaller.install(row.app) { [weak self] status in
                        self?.actionMessages[row.id] = status
                    }
                    switch outcome {
                    case .installed: actionMessages[row.id] = nil
                    case let .failure(message): actionMessages[row.id] = message
                    }
                default:
                    break
                }
                runningActions.remove(row.id)
            }
            await checkNow()
        }
    }

    var inPlaceUpdateCount: Int {
        rows.filter(\.installsInPlace).count
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard !Self.isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private func notifyAboutNewUpdates() {
        let fresh = rows.filter { !notifiedUpdateIDs.contains($0.update.id) }
        notifiedUpdateIDs.formUnion(rows.map(\.update.id))
        // Keep the memory small: only IDs still pending matter.
        notifiedUpdateIDs.formIntersection(Set(rows.map(\.update.id)))
        defaults.set(Array(notifiedUpdateIDs), forKey: Keys.notified)

        guard notificationsEnabled, !fresh.isEmpty, !Self.isRunningTests else { return }
        let content = UNMutableNotificationContent()
        if fresh.count == 1, let row = fresh.first {
            content.title = "\(row.app.name) \(row.update.version) is available"
            content.body = "You have \(row.app.displayVersion). Open UpdateBar to update."
        } else {
            content.title = "\(fresh.count) app updates available"
            content.body = fresh.prefix(4).map(\.app.name).joined(separator: ", ")
                + (fresh.count > 4 ? ", and more" : "")
        }
        let request = UNNotificationRequest(identifier: "updates-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Runs Homebrew as the current user, never with elevated rights.
enum BrewRunner {
    enum Outcome: Sendable {
        case success
        case failure(String)
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func upgrade(cask token: String) async -> Outcome {
        guard let brewPath else { return .failure("Homebrew isn't installed in the usual place.") }
        // Read output while brew runs: waiting for exit first would deadlock once a
        // verbose upgrade fills the pipe buffer.
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(filePath: brewPath)
            process.arguments = ["upgrade", "--cask", token]
            var environment = ProcessInfo.processInfo.environment
            environment["NONINTERACTIVE"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failure(error.localizedDescription)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .success }
            return .failure(summary(of: String(decoding: data, as: UTF8.self), token: token))
        }.value
    }

    /// Picks the line that explains a failure, and says what to do when brew needs a password.
    static func summary(of output: String, token: String) -> String {
        if output.localizedCaseInsensitiveContains("sudo") || output.localizedCaseInsensitiveContains("password") {
            return "This cask needs your password. Run `brew upgrade --cask \(token)` in Terminal."
        }
        let errorLine = output.split(separator: "\n").last { $0.localizedCaseInsensitiveContains("error") }
        return errorLine.map { String($0).trimmingCharacters(in: .whitespaces) }
            ?? "brew upgrade failed. Run `brew upgrade --cask \(token)` in Terminal to see why."
    }
}

extension AppUpdate {
    /// Whether UpdateBar can install this update itself, without opening anything.
    var installsInPlace: Bool {
        switch update.action {
        case .brewUpgrade, .sparkleInstall: true
        case .openAppStore, .launchApp, .openURL: false
        }
    }
}
