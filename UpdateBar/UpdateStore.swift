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
    /// The brew run in progress for tools, if any.
    private(set) var toolRun: BrewRunProgress?
    /// A short result line after an install or upgrade. Warnings stay until the next run.
    private(set) var banner: Banner?

    struct Banner: Equatable, Sendable {
        var text: String
        var isWarning: Bool
    }
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
        didSet {
            defaults.set(showsTools, forKey: Keys.showsTools)
            if showsTools != oldValue { Task { await checkNow(refreshAfterCurrent: true) } }
        }
    }

    private var lastResult = CheckerResult()
    private var installedApps: [InstalledApp] = []
    private var notifiedUpdateIDs: Set<String>
    private var timer: Timer?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var activeAppID: String?
    @ObservationIgnored private var toolRunID: UUID?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var shouldNotifyForCheck = false
    private let defaults: UserDefaults
    private let collect: @Sendable (Set<String>, [String: String], Bool) async -> CheckSnapshot
    private let installApp: @MainActor (AppUpdate, Set<String>, @escaping @MainActor (String) -> Void) async -> String?
    private let installTools: @Sendable ([String], @escaping @Sendable (BrewOutputParser.Event) -> Void) async -> BrewRunner.Outcome

    struct CheckSnapshot: Sendable {
        var apps: [InstalledApp] = []
        var result = CheckerResult()
        var tools: [ToolUpdate] = []
        var toolFailures: [CheckFailure] = []
    }

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

    init(
        defaults: UserDefaults = .standard,
        collect: @escaping @Sendable (Set<String>, [String: String], Bool) async -> CheckSnapshot = UpdateStore.collectUpdates,
        installApp: @escaping @MainActor (AppUpdate, Set<String>, @escaping @MainActor (String) -> Void) async -> String? = UpdateStore.installUpdate,
        installTools: @escaping @Sendable ([String], @escaping @Sendable (BrewOutputParser.Event) -> Void) async -> BrewRunner.Outcome = { names, progress in
            await BrewRunner.upgrade(formulae: names, onEvent: progress)
        }
    ) {
        self.defaults = defaults
        self.collect = collect
        self.installApp = installApp
        self.installTools = installTools
        checkIntervalHours = defaults.object(forKey: Keys.interval) as? Int ?? 6
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        ignoredApps = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        ignoredAppNames = defaults.dictionary(forKey: Keys.ignoredNames) as? [String: String] ?? [:]
        skippedVersions = defaults.dictionary(forKey: Keys.skipped) as? [String: String] ?? [:]
        notifiedUpdateIDs = Set(defaults.stringArray(forKey: Keys.notified) ?? [])
        betaApps = Set(defaults.stringArray(forKey: Keys.betaApps) ?? [])
        showsTools = defaults.object(forKey: Keys.showsTools) as? Bool ?? true
    }

    /// Tools you installed yourself, real releases before rebuilds; dependencies are
    /// upgraded along with them.
    var requestedTools: [ToolUpdate] {
        guard showsTools else { return [] }
        let requested = tools.filter(\.requested)
        return requested.filter { !$0.isRebuild } + requested.filter(\.isRebuild)
    }
    var dependencyTools: [ToolUpdate] { showsTools ? tools.filter { !$0.requested } : [] }

    /// Your tools with a new upstream release. Rebuilds of the same release are listed
    /// but don't count toward the badge or trigger notifications.
    var newReleaseTools: [ToolUpdate] { requestedTools.filter { !$0.isRebuild } }

    /// What the menu bar count shows: app updates plus new releases of your tools.
    var pendingCount: Int { rows.count + newReleaseTools.count }

    var statusSummary: String {
        if isChecking && lastChecked == nil { return "Checking for updates" }
        if pendingCount > 0 { return "\(pendingCount) update\(pendingCount == 1 ? "" : "s") available" }
        if !failures.isEmpty { return "Some updates couldn’t be checked" }
        if lastChecked == nil { return "Waiting to check for updates" }
        if !requestedTools.isEmpty || !dependencyTools.isEmpty { return "Tool maintenance available" }
        return "Everything is up to date"
    }

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
        Task { await checkNow(refreshAfterCurrent: true) }
    }

    /// Channels Sparkle may install from: the feed's stable-named channels always,
    /// and its pre-release channels only when you opted the app into betas.
    func betaChannels(for bundleIdentifier: String) -> Set<String> {
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

    /// Ordinary requests share a running check. Preference changes and completed
    /// installs request one more pass so an older in-flight snapshot cannot win.
    func checkNow(refreshAfterCurrent: Bool = false, notify: Bool = true) async {
        shouldNotifyForCheck = shouldNotifyForCheck || notify
        if let checkTask {
            refreshRequested = refreshRequested || refreshAfterCurrent
            await checkTask.value
            return
        }
        isChecking = true
        let task = Task {
            repeat {
                refreshRequested = false
                let repositories = defaults.dictionary(forKey: Keys.repositories) as? [String: String] ?? [:]
                let snapshot = await collect(betaApps, repositories, showsTools)
                // A setting changed during the fetch. Do not publish its obsolete result.
                guard !refreshRequested else { continue }
                installedApps = snapshot.apps
                appCount = snapshot.apps.count
                lastResult = snapshot.result
                tools = snapshot.tools
                failures = (snapshot.result.failures + snapshot.toolFailures)
                    .sorted { ($0.source, $0.subject) < ($1.source, $1.subject) }
                lastChecked = Date()
                resolve()
                if shouldNotifyForCheck { notifyAboutNewUpdates() }
            } while refreshRequested
            shouldNotifyForCheck = false
            isChecking = false
            checkTask = nil
        }
        checkTask = task
        await task.value
    }

    nonisolated private static func collectUpdates(
        betaApps: Set<String>, repositories: [String: String], showsTools: Bool
    ) async -> CheckSnapshot {
        let apps = await Task.detached(priority: .utility) { AppScanner().scan() }.value
        let checkers: [any UpdateChecker] = [
            AppStoreChecker(), SparkleChecker(betaApps: betaApps),
            HomebrewChecker(), GitHubChecker(repositories: repositories),
        ]
        async let formulae = showsTools ? FormulaChecker().check() : (tools: [], failures: [])
        let combined = await withTaskGroup(of: CheckerResult.self) { group in
            for checker in checkers { group.addTask { await checker.check(apps) } }
            var combined = CheckerResult()
            for await result in group { combined.merge(result) }
            return combined
        }
        let toolResult = await formulae
        return CheckSnapshot(apps: apps, result: combined, tools: toolResult.tools, toolFailures: toolResult.failures)
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
        guard !row.installsInPlace || canInstallUpdates else { return }
        actionMessages[id] = nil
        switch row.update.action {
        case .brewUpgrade, .sparkleInstall:
            installUpdates([row])
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
    var canInstallUpdates: Bool { runningActions.isEmpty }

    func updateAllInPlace() {
        installUpdates(rows.filter(\.installsInPlace))
    }

    private func installUpdates(_ targets: [AppUpdate]) {
        guard canInstallUpdates, !targets.isEmpty else { return }
        // Reserve the entire batch before yielding: buttons and queued tasks cannot
        // start a second installer or a competing Homebrew formula upgrade.
        let ids = targets.map(\.id)
        runningActions.formUnion(ids)
        for row in targets { actionMessages[row.id] = "Waiting…" }
        banner = nil
        Task {
            var released = false
            defer {
                if !released {
                    activeAppID = nil
                    runningActions.subtract(ids)
                }
            }
            var failed: [String] = []
            for row in targets {
                activeAppID = row.id
                actionMessages[row.id] = "Starting update…"
                let message = await installApp(row, betaChannels(for: row.id)) { status in
                    guard self.activeAppID == row.id else { return }
                    self.actionMessages[row.id] = status
                }
                activeAppID = nil
                if let message {
                    actionMessages[row.id] = message
                    failed.append(row.app.name)
                } else {
                    actionMessages[row.id] = nil
                }
                // Keep the batch reserved until every installer has finished.
            }
            if !failed.isEmpty {
                let updated = targets.count - failed.count
                let names = failed.joined(separator: ", ")
                let text = updated == 0
                    ? "Couldn't update \(names)"
                    : "Updated \(updated) of \(targets.count). \(names) still \(failed.count == 1 ? "needs" : "need") an update"
                banner = Banner(text: text, isWarning: true)
            }
            activeAppID = nil
            runningActions.subtract(ids)
            released = true
            await checkNow(refreshAfterCurrent: true)
        }
    }

    private static func installUpdate(
        _ row: AppUpdate, channels: Set<String>, progress: @escaping @MainActor (String) -> Void
    ) async -> String? {
        switch row.update.action {
        case let .brewUpgrade(token):
            let outcome = await BrewRunner.upgrade(cask: token) { event in
                Task { @MainActor in progress("\(event.stage.label)…") }
            }
            if case let .failure(message) = outcome { return message }
        case .sparkleInstall:
            if case let .failure(message) = await SparkleInstaller.install(row.app, channels: channels, progress: progress) {
                return message
            }
        default: break
        }
        return nil
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
        guard !names.isEmpty, canInstallUpdates else { return }
        actionMessages[actionID] = nil
        banner = nil
        runningActions.insert(actionID)
        toolRun = BrewRunProgress(names: names)
        let runID = UUID()
        toolRunID = runID
        let events = ToolEventBuffer()
        Task {
            var released = false
            defer {
                if !released {
                    if toolRunID == runID { toolRunID = nil }
                    runningActions.remove(actionID)
                    toolRun = nil
                }
            }
            let outcome = await installTools(names) { event in
                events.append(event)
                Task { @MainActor in
                    guard self.toolRunID == runID else { return }
                    for event in events.drain() { self.toolRun?.apply(event) }
                }
            }
            // Progress hops to the main actor asynchronously. Apply whatever is
            // still queued before deciding how much of the run finished.
            for event in events.drain() where toolRunID == runID {
                toolRun?.apply(event)
            }
            switch outcome {
            case .success:
                let notice = names.count == 1 ? "Upgraded \(names[0])" : "Upgraded \(names.count) tools"
                let shown = Banner(text: notice, isWarning: false)
                banner = shown
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    if banner == shown { banner = nil }
                }
            case let .failure(message):
                toolRun?.markUnfinishedFailed()
                let finished = toolRun?.finished ?? 0
                actionMessages[actionID] = message
                let text: String
                if finished == 0 {
                    text = names.count == 1 ? "Couldn't upgrade \(names[0])" : "Couldn't upgrade those tools"
                } else if finished < names.count {
                    text = "Upgraded \(finished) of \(names.count) before brew stopped"
                } else {
                    text = "Brew stopped after upgrading \(finished)"
                }
                banner = Banner(text: text, isWarning: true)
            }
            if toolRunID == runID { toolRunID = nil }
            runningActions.remove(actionID)
            toolRun = nil
            released = true
            await checkNow(refreshAfterCurrent: true)
        }
    }

    /// The stage of one tool while an upgrade is running, if it's part of it.
    func stage(of tool: ToolUpdate) -> BrewStage? {
        toolRun?.stages[tool.name]
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard !Self.isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private func notifyAboutNewUpdates() {
        let pending: [(id: String, name: String)] = rows.map { ($0.update.id, $0.app.name) }
            + newReleaseTools.map { ($0.notificationID, $0.name) }
        let freshTools = newReleaseTools.filter { !notifiedUpdateIDs.contains($0.notificationID) }
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

/// Brew progress is produced off the main actor. The buffer keeps every event
/// so the final tally still sees lines that have not been drawn yet.
private final class ToolEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrewOutputParser.Event] = []

    func append(_ event: BrewOutputParser.Event) {
        lock.withLock { events.append(event) }
    }

    func drain() -> [BrewOutputParser.Event] {
        lock.withLock {
            let copy = events
            events.removeAll(keepingCapacity: false)
            return copy
        }
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

    static func upgrade(cask token: String, onEvent: (@Sendable (BrewOutputParser.Event) -> Void)? = nil) async -> Outcome {
        await run(["upgrade", "--cask", token], retryHint: "brew upgrade --cask \(token)", onEvent: onEvent)
    }

    static func upgrade(formulae names: [String], onEvent: (@Sendable (BrewOutputParser.Event) -> Void)? = nil) async -> Outcome {
        await run(["upgrade", "--formula"] + names, retryHint: "brew upgrade --formula \(names.joined(separator: " "))", onEvent: onEvent)
    }

    private static func run(
        _ arguments: [String],
        retryHint: String,
        onEvent: (@Sendable (BrewOutputParser.Event) -> Void)?
    ) async -> Outcome {
        guard let brewPath else { return .failure("Homebrew isn't installed in the usual place.") }
        // Output is read line by line while brew runs: it drives the progress display,
        // and waiting for exit first would deadlock once a verbose upgrade fills the pipe.
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(filePath: brewPath)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["NONINTERACTIVE"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            environment["HOMEBREW_NO_COLOR"] = "1"
            environment["HOMEBREW_NO_EMOJI"] = "1"
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

            var transcript = Data()
            var pending = Data()
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                transcript.append(chunk)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if let onEvent, let event = BrewOutputParser.event(for: line) { onEvent(event) }
                }
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .success }
            return .failure(summary(of: String(decoding: transcript, as: UTF8.self), command: retryHint))
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
