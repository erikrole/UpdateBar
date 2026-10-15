import Foundation

/// One Homebrew formula upgrade, including Upgrade all.
@MainActor
enum ToolUpgradeActions {
    static func upgrade(_ tool: ToolUpdate, store: UpdateStore) {
        upgrade(names: [tool.name], actionID: "formula|\(tool.name)", store: store)
    }

    /// Upgrades every outdated formula, dependencies included, in one brew run.
    static func upgradeAll(_ store: UpdateStore) {
        upgrade(names: store.tools.map(\.name), actionID: UpdateStore.allToolsID, store: store)
    }

    private static func upgrade(names: [String], actionID: String, store: UpdateStore) {
        guard !names.isEmpty, store.canInstallUpdates else { return }
        store.actionMessages[actionID] = nil
        store.banner = nil
        store.runningActions.insert(actionID)
        store.toolRun = BrewRunProgress(names: names)
        let runID = UUID()
        store.toolRunID = runID
        let events = ToolEventBuffer()
        Task {
            var released = false
            defer {
                if !released {
                    if store.toolRunID == runID { store.toolRunID = nil }
                    store.runningActions.remove(actionID)
                    store.toolRun = nil
                }
            }
            let outcome = await store.installTools(names) { event in
                events.append(event)
                Task { @MainActor in
                    guard store.toolRunID == runID else { return }
                    for event in events.drain() { store.toolRun?.apply(event) }
                }
            }
            // Progress hops to the main actor asynchronously. Apply whatever is
            // still queued before deciding how much of the run finished.
            for event in events.drain() where store.toolRunID == runID {
                store.toolRun?.apply(event)
            }
            switch outcome {
            case .success:
                let notice = names.count == 1 ? "Upgraded \(names[0])" : "Upgraded \(names.count) tools"
                let shown = UpdateStore.Banner(text: notice, isWarning: false)
                store.banner = shown
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    if store.banner == shown { store.banner = nil }
                }
            case let .failure(message):
                store.toolRun?.markUnfinishedFailed()
                let finished = store.toolRun?.finished ?? 0
                store.actionMessages[actionID] = message
                let text: String
                if finished == 0 {
                    text = names.count == 1 ? "Couldn't upgrade \(names[0])" : "Couldn't upgrade those tools"
                } else if finished < names.count {
                    text = "Upgraded \(finished) of \(names.count) before brew stopped"
                } else {
                    text = "Brew stopped after upgrading \(finished)"
                }
                store.banner = UpdateStore.Banner(text: text, isWarning: true)
            }
            if store.toolRunID == runID { store.toolRunID = nil }
            store.runningActions.remove(actionID)
            store.toolRun = nil
            released = true
            await store.checkNow(refreshAfterCurrent: true)
        }
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
