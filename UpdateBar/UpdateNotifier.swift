import Foundation
import UserNotifications

/// Notification permission and the "something new" alert. History is updated even
/// when alerts are off, so turning them back on does not repeat old updates.
@MainActor
enum UpdateNotifier {
    static func requestPermission() {
        guard !isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    static func notifyAboutNewUpdates(_ store: UpdateStore) {
        let pending: [(id: String, name: String)] = store.rows.map { ($0.update.id, $0.app.name) }
            + store.newReleaseTools.map { ($0.notificationID, $0.name) }
        let freshTools = store.newReleaseTools.filter { !store.notifiedUpdateIDs.contains($0.notificationID) }
        let fresh = store.rows.filter { !store.notifiedUpdateIDs.contains($0.update.id) }
        let pendingIDs = Set(pending.map(\.id))
        store.notifiedUpdateIDs.formUnion(pendingIDs)
        // Keep the memory small: only IDs still pending matter.
        store.notifiedUpdateIDs.formIntersection(pendingIDs)
        store.defaults.set(Array(store.notifiedUpdateIDs), forKey: UpdateStore.Keys.notified)

        let freshCount = fresh.count + freshTools.count
        guard store.notificationsEnabled, freshCount > 0, !isRunningTests else { return }
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
        let request = UNNotificationRequest(
            identifier: "updates-\(Date().timeIntervalSince1970)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
