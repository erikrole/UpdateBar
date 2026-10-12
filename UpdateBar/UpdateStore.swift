import AppKit
import Foundation
import Observation
import UserNotifications

/// Owns the scan → check → resolve cycle, user preferences, and update actions.
@MainActor
@Observable
final class UpdateStore {
    private(set) var rows: [AppUpdate] = []
    /// Outdated Homebrew formulae, requested ones first.
    private(set) var tools: [ToolUpdate] = []
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
    /// Apps opted into pre-release (beta) updates.
    private(set) var betaApps: Set<String>
    var showsTools: Bool {
        didSet { defaults.set(showsTools, forKey: Keys.showsTools) }
    }

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
        static let betaApps = "betaApps"
        static let showsTools = "showsCommandLineTools"
    }

    init() {
        checkIntervalHours = defaults.object(forKey: Keys.interval) as? Int ?? 6
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        ignoredApps = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        ignoredAppNames = defaults.dictionary(forKey: Keys.ignoredNames) as? [String: String] ?? [:]
        skippedVersions = defaults.dictionary(forKey: Keys.skipped) as? [String: String] ?? [:]
        notifiedUpdateIDs = Set(defaults.stringArray(forKey: Keys.notified) ?? [])
        betaApps = Set(defaults.stringArray(forKey: Keys.betaApps) ?? [])
        showsTools = defaults.object(forKey: Keys.showsTools) as? Bool ?? true
    }

    /// Tools you installed yourself; dependencies are upgraded along with them.
    var requestedTools: [ToolUpdate] { showsTools ? tools.filter(\.requested) : [] }
    var dependencyTools: [ToolUpdate] { showsTools ? tools.filter { !$0.requested } : [] }

    /// What the menu bar count shows: app updates plus tools you installed yourself.
    var pendingCount: Int { rows.count + requestedTools.count }

    /// Sparkle apps whose feeds publish betas, for the beta toggles.
    var betaCapableApps: [InstalledApp] {
        installedApps.filter { app in
            lastResult.feedChannels[app.bundleIdentifier]?.contains(where: AppcastItem.isPrereleaseChannel) == true
        }
    }

    func isBetaEnabled(_ bundleIdentifier: String) -> Bool {
        betaApps.contains(bundleIdentifier)
    }

    func setBeta(_ enabled: Bool, for bundleIdentifier: String) {
        if enabled { betaApps.insert(bundleIdentifier) } else { betaApps.remove(bundleIdentifier) }
        defaults.set(Array(betaApps), forKey: Keys.betaApps)
        Task { await checkNow() }
    }

    /// Channels Sparkle may install from: the feed's stable-named channels always,
    /// and its pre-release channels only when you opted the app into betas.
    private func betaChannels(for bundleIdentifier: String) -> Set<String> {
        let channels = lastResult.feedChannels[bundleIdentifier] ?? []
        if betaApps.contains(bundleIdentifier) { return channels }
        return channels.filter { !AppcastItem.isPrereleaseChannel($0) }
    }

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
            SparkleChecker(betaApps: betaApps),
            HomebrewChecker(),
            GitHubChecker(repositories: repositories),
        ]
        async let formulae = FormulaChecker().check()
        let combined = await withTaskGroup(of: CheckerResult.self) { group in
            for checker in checkers {
                group.addTask { await checker.check(apps) }
            }
            var combined = CheckerResult()
            for await result in group { combined.merge(result) }
            return combined
        }
        let toolResult = await formulae

        lastResult = combined
        tools = toolResult.tools
        failures = (combined.failures + toolResult.failures).sorted { ($0.source, $0.subject) < ($1.source, $1.subject) }
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
                let outcome = await SparkleInstaller.install(row.app, channels: betaChannels(for: row.app.bundleIdentifier)) { [weak self] status in
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
            let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak self] _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in self?.actionMessages[id] = message }
            }
            if let aboutPage = Self.updatePage(for: row.app.bundleIdentifier) {
                // Browsers check for and apply updates when their About page opens.
                NSWorkspace.shared.open([aboutPage], withApplicationAt: row.app.url, configuration: configuration, completionHandler: completion)
            } else {
                NSWorkspace.shared.openApplication(at: row.app.url, configuration: configuration, completionHandler: completion)
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
                    let outcome = await SparkleInstaller.install(row.app, channels: betaChannels(for: row.app.bundleIdentifier)) { [weak self] status in
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

    // MARK: - Command-line tools

    static let allToolsID = "formula|*"

    func upgrade(_ tool: ToolUpdate) {
        upgradeTools([tool.name], actionID: "formula|\(tool.name)")
    }

    /// Upgrades every outdated formula, dependencies included, in one brew run.
    func upgradeAllTools() {
        upgradeTools(tools.map(\.name), actionID: Self.allToolsID)
    }

    private func upgradeTools(_ names: [String], actionID: String) {
        guard !names.isEmpty, runningActions.isDisjoint(with: [actionID, Self.allToolsID]) else { return }
        actionMessages[actionID] = nil
        runningActions.insert(actionID)
        Task {
            let outcome = await BrewRunner.upgrade(formulae: names)
            runningActions.remove(actionID)
            if case let .failure(message) = outcome { actionMessages[actionID] = message }
            await checkNow()
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard !Self.isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private func notifyAboutNewUpdates() {
        let pending: [(id: String, name: String)] = rows.map { ($0.update.id, $0.app.name) }
            + requestedTools.map { ($0.notificationID, $0.name) }
        let freshTools = requestedTools.filter { !notifiedUpdateIDs.contains($0.notificationID) }
        let fresh = rows.filter { !notifiedUpdateIDs.contains($0.update.id) }
        let pendingIDs = Set(pending.map(\.id))
        notifiedUpdateIDs.formUnion(pendingIDs)
        // Keep the memory small: only IDs still pending matter.
        notifiedUpdateIDs.formIntersection(pendingIDs)
        defaults.set(Array(notifiedUpdateIDs), forKey: Keys.notified)

        let freshCount = fresh.count + freshTools.count
        guard notificationsEnabled, freshCount > 0, !Self.isRunningTests else { return }
        let content = UNMutableNotificationContent()
        if fresh.count == 1, freshTools.isEmpty, let row = fresh.first {
            content.title = "\(row.app.name) \(row.update.version) is available"
            content.body = "You have \(row.app.displayVersion). Open UpdateBar to update."
        } else if fresh.isEmpty, freshTools.count == 1, let tool = freshTools.first {
            content.title = "\(tool.name) \(tool.latestVersion) is available"
            content.body = "You have \(tool.installedVersion). Open UpdateBar to upgrade."
        } else {
            content.title = "\(freshCount) updates available"
            let names = fresh.map(\.app.name) + freshTools.map(\.name)
            content.body = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", and more" : "")
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
        await run(["upgrade", "--cask", token], retryHint: "brew upgrade --cask \(token)")
    }

    static func upgrade(formulae names: [String]) async -> Outcome {
        await run(["upgrade", "--formula"] + names, retryHint: "brew upgrade --formula \(names.joined(separator: " "))")
    }

    private static func run(_ arguments: [String], retryHint: String) async -> Outcome {
        guard let brewPath else { return .failure("Homebrew isn't installed in the usual place.") }
        // Read output while brew runs: waiting for exit first would deadlock once a
        // verbose upgrade fills the pipe buffer.
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(filePath: brewPath)
            process.arguments = arguments
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
            return .failure(summary(of: String(decoding: data, as: UTF8.self), command: retryHint))
        }.value
    }

    /// Picks the line that explains a failure, and says what to do when brew needs a password.
    static func summary(of output: String, command: String) -> String {
        if output.localizedCaseInsensitiveContains("sudo") || output.localizedCaseInsensitiveContains("password") {
            return "This needs your password. Run `\(command)` in Terminal."
        }
        let errorLine = output.split(separator: "\n").last { $0.localizedCaseInsensitiveContains("error") }
        return errorLine.map { String($0).trimmingCharacters(in: .whitespaces) }
            ?? "brew failed. Run `\(command)` in Terminal to see why."
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
