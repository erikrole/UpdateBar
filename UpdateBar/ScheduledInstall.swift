import AppKit
import Foundation

/// The daily unattended "Update all": at a chosen hour, check, then install in-place updates for apps that
/// aren't open. Open apps are left for you, so nothing quits under unsaved work.
enum ScheduledInstall {
    /// A run that wakes more than this late (the Mac was asleep) waits for the next day instead.
    static let lateLimit: TimeInterval = 2 * 3600

    static func nextFire(after now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let components = DateComponents(hour: min(max(hour, 0), 23), minute: 0, second: 0)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    static func isTooLate(fire: Date, now: Date) -> Bool { now.timeIntervalSince(fire) > lateLimit }

    @MainActor
    static func targets(_ rows: [AppUpdate], isRunning: (String) -> Bool = PreviousVersions.isRunning) -> [AppUpdate] {
        rows.filter { $0.installsInPlace && !isRunning($0.app.bundleIdentifier) }
    }
}

extension UpdateStore {
    /// Restarts the daily timer for the current `autoInstallHour`; nil turns it off.
    func scheduleAutoInstall(now: Date = Date()) {
        autoInstallTask?.cancel()
        guard let hour = autoInstallHour else { autoInstallTask = nil; return }
        let fire = ScheduledInstall.nextFire(after: now, hour: hour)
        autoInstallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, fire.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if !ScheduledInstall.isTooLate(fire: fire, now: Date()) { await self.runScheduledInstall() }
            guard !Task.isCancelled else { return }
            self.scheduleAutoInstall()
        }
    }

    func runScheduledInstall() async {
        await checkNow(notify: false)
        let targets = ScheduledInstall.targets(rows)
        guard !targets.isEmpty, canInstallUpdates, !isChecking else { return }
        lastAutoInstall = Date()
        AppUpdateActions.install(targets, on: self)
    }
}
