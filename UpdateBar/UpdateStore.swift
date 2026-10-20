import Foundation
import Observation

/// Owns the scan → check → resolve cycle, user preferences, and update actions.
@MainActor
@Observable
final class UpdateStore {
    var rows: [AppUpdate] = []
    /// Outdated Homebrew formulae, requested ones first.
    var tools: [ToolUpdate] = []
    /// The brew run in progress for tools, if any.
    var toolRun: BrewRunProgress?
    /// A short result line after an install or upgrade. Warnings stay until the next run.
    var banner: Banner?

    struct Banner: Equatable, Sendable {
        var text: String
        var isWarning: Bool
    }
    var failures: [CheckFailure] = []
    var appCount = 0
    var lastChecked: Date?
    var isChecking = false
    var runningActions: Set<String> = []
    var actionMessages: [String: String] = [:]

    var checkIntervalHours: Int {
        didSet { defaults.set(checkIntervalHours, forKey: Keys.interval); scheduleChecks() }
    }
    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notifications)
            if notificationsEnabled { UpdateNotifier.requestPermission() }
        }
    }
    var ignoredApps: Set<String>
    var skippedVersions: [String: String]
    var ignoredAppNames: [String: String]
    /// Apps opted into pre-release (beta) updates.
    var betaApps: Set<String>
    var showsTools: Bool {
        didSet {
            defaults.set(showsTools, forKey: Keys.showsTools)
            if showsTools != oldValue { Task { await checkNow(refreshAfterCurrent: true) } }
        }
    }

    var lastResult = CheckerResult()
    var installedApps: [InstalledApp] = []
    var notifiedUpdateIDs: Set<String>
    @ObservationIgnored var checkTask: Task<Void, Never>?
    @ObservationIgnored var activeAppID: String?
    @ObservationIgnored var toolRunID: UUID?
    @ObservationIgnored var refreshRequested = false
    @ObservationIgnored var shouldNotifyForCheck = false
    let defaults: UserDefaults
    let collect: @Sendable (Set<String>, [String: String], Bool) async -> CheckSnapshot
    let installApp: @MainActor (AppUpdate, Set<String>, @escaping @MainActor (String) -> Void) async -> String?
    let installTools: @Sendable ([String], @escaping @Sendable (BrewOutputParser.Event) -> Void) async -> BrewRunner.Outcome
    private let backgroundChecks: BackgroundCheckScheduler

    struct CheckSnapshot: Sendable {
        var apps: [InstalledApp] = []
        var result = CheckerResult()
        var tools: [ToolUpdate] = []
        var toolFailures: [CheckFailure] = []
    }

    enum Keys {
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
        collect: @escaping @Sendable (Set<String>, [String: String], Bool) async -> CheckSnapshot = UpdateCheckCycle.collect,
        installApp: @escaping @MainActor (AppUpdate, Set<String>, @escaping @MainActor (String) -> Void) async -> String? = AppUpdateActions.installUpdate,
        installTools: @escaping @Sendable ([String], @escaping @Sendable (BrewOutputParser.Event) -> Void) async -> BrewRunner.Outcome = { names, progress in
            await BrewRunner.upgrade(formulae: names, onEvent: progress)
        },
        backgroundChecks: BackgroundCheckScheduler = BackgroundCheckScheduler()
    ) {
        self.defaults = defaults
        self.collect = collect
        self.installApp = installApp
        self.installTools = installTools
        self.backgroundChecks = backgroundChecks
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
        if notificationsEnabled { UpdateNotifier.requestPermission() }
        scheduleChecks()
        PKGInstaller.sweepStaging()
        Task { await checkNow() }
    }

    func checkNow(refreshAfterCurrent: Bool = false, notify: Bool = true) async {
        await UpdateCheckCycle.checkNow(self, refreshAfterCurrent: refreshAfterCurrent, notify: notify)
    }

    private func scheduleChecks() {
        backgroundChecks.schedule(intervalHours: checkIntervalHours) { [weak self] in
            await self?.checkNow()
        }
    }

    // MARK: - Skip and ignore

    func skip(_ row: AppUpdate) {
        skippedVersions[row.app.bundleIdentifier] = row.update.version
        defaults.set(skippedVersions, forKey: Keys.skipped)
        UpdateCheckCycle.resolve(self)
    }

    func ignore(_ row: AppUpdate) {
        ignoredApps.insert(row.app.bundleIdentifier)
        ignoredAppNames[row.app.bundleIdentifier] = row.app.name
        defaults.set(Array(ignoredApps), forKey: Keys.ignored)
        defaults.set(ignoredAppNames, forKey: Keys.ignoredNames)
        UpdateCheckCycle.resolve(self)
    }

    func unignore(_ bundleIdentifier: String) {
        ignoredApps.remove(bundleIdentifier)
        ignoredAppNames[bundleIdentifier] = nil
        defaults.set(Array(ignoredApps), forKey: Keys.ignored)
        defaults.set(ignoredAppNames, forKey: Keys.ignoredNames)
        UpdateCheckCycle.resolve(self)
    }

    func clearSkippedVersions() {
        skippedVersions = [:]
        defaults.set(skippedVersions, forKey: Keys.skipped)
        UpdateCheckCycle.resolve(self)
    }

    // MARK: - Actions

    func perform(_ row: AppUpdate) {
        AppUpdateActions.perform(row, store: self)
    }

    /// The page that makes a self-updating browser fetch its update right away.
    nonisolated static func updatePage(for bundleIdentifier: String) -> URL? {
        AppUpdateActions.updatePage(for: bundleIdentifier)
    }

    /// Runs every update that installs in place (Homebrew and Sparkle), one at a time
    /// so brew doesn't lock against itself and installers don't compete.
    var canInstallUpdates: Bool { runningActions.isEmpty }

    func updateAllInPlace() {
        AppUpdateActions.updateAllInPlace(self)
    }

    var inPlaceUpdateCount: Int {
        rows.filter(\.installsInPlace).count
    }

    // MARK: - Command-line tools

    static let allToolsID = "formula|*"

    func upgrade(_ tool: ToolUpdate) {
        ToolUpgradeActions.upgrade(tool, store: self)
    }

    /// Upgrades every outdated formula, dependencies included, in one brew run.
    func upgradeAllTools() {
        ToolUpgradeActions.upgradeAll(self)
    }

    /// The stage of one tool while an upgrade is running, if it's part of it.
    func stage(of tool: ToolUpdate) -> BrewStage? {
        toolRun?.stages[tool.name]
    }
}
