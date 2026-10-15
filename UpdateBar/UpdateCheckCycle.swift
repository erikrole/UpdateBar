import Foundation

/// One scan → check → resolve pass, including a follow-up when preferences change mid-fetch.
enum UpdateCheckCycle {
    /// Ordinary requests share a running check. Preference changes and completed
    /// installs request one more pass so an older in-flight snapshot cannot win.
    @MainActor
    static func checkNow(
        _ store: UpdateStore,
        refreshAfterCurrent: Bool = false,
        notify: Bool = true
    ) async {
        store.shouldNotifyForCheck = store.shouldNotifyForCheck || notify
        if let checkTask = store.checkTask {
            store.refreshRequested = store.refreshRequested || refreshAfterCurrent
            await checkTask.value
            return
        }
        store.isChecking = true
        let task = Task {
            repeat {
                store.refreshRequested = false
                let repositories = store.defaults.dictionary(forKey: UpdateStore.Keys.repositories) as? [String: String] ?? [:]
                let snapshot = await store.collect(store.betaApps, repositories, store.showsTools)
                // A setting changed during the fetch. Do not publish its obsolete result.
                guard !store.refreshRequested else { continue }
                store.installedApps = snapshot.apps
                store.appCount = snapshot.apps.count
                store.lastResult = snapshot.result
                store.tools = snapshot.tools
                store.failures = (snapshot.result.failures + snapshot.toolFailures)
                    .sorted { ($0.source, $0.subject) < ($1.source, $1.subject) }
                store.lastChecked = Date()
                resolve(store)
                if store.shouldNotifyForCheck { UpdateNotifier.notifyAboutNewUpdates(store) }
            } while store.refreshRequested
            store.shouldNotifyForCheck = false
            store.isChecking = false
            store.checkTask = nil
        }
        store.checkTask = task
        await task.value
    }

    @MainActor
    static func resolve(_ store: UpdateStore) {
        store.rows = UpdateResolver.resolve(
            apps: store.installedApps,
            result: store.lastResult,
            ignoredApps: store.ignoredApps,
            skippedVersions: store.skippedVersions
        )
    }

    static func collect(
        betaApps: Set<String>, repositories: [String: String], showsTools: Bool
    ) async -> UpdateStore.CheckSnapshot {
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
        return UpdateStore.CheckSnapshot(
            apps: apps, result: combined, tools: toolResult.tools, toolFailures: toolResult.failures
        )
    }
}
