import Foundation

/// Repeating discretionary update check.
///
/// Uses `NSBackgroundActivityScheduler` so the system can delay the check by a
/// half interval. A run-loop `Timer` fires as soon as the process resumes if
/// its fire date passed during sleep, which runs a check on wake. Nothing here
/// observes `NSWorkspace.didWakeNotification`.
@MainActor
final class BackgroundCheckScheduler {
    static let identifier = "com.erole.UpdateBar.background-check"

    private var activity: (any BackgroundActivityScheduling)?
    private let makeActivity: (String) -> any BackgroundActivityScheduling

    init(makeActivity: @escaping (String) -> any BackgroundActivityScheduling = { SystemBackgroundActivity(identifier: $0) }) {
        self.makeActivity = makeActivity
    }

    /// Replaces any scheduled check. The new one waits out its interval; scheduling does not check now.
    func schedule(intervalHours: Int, perform: @escaping @MainActor () async -> Void) {
        activity?.invalidate()
        let timing = BackgroundCheckSchedule(hours: intervalHours)
        let scheduled = makeActivity(Self.identifier)
        scheduled.repeats = true
        scheduled.interval = timing.interval
        scheduled.tolerance = timing.tolerance
        scheduled.qualityOfService = .utility
        let box = ActivityBox(scheduled)
        scheduled.schedule { completion in
            // The SDK completion is non-escaping, so it has to run before this
            // block returns. The check itself continues on the main actor.
            BackgroundCheckRunner.handle(shouldDefer: box.shouldDefer, perform: perform, completion: completion)
        }
        activity = scheduled
    }

    func invalidate() {
        activity?.invalidate()
        activity = nil
    }
}

/// How long the system should wait, and how long it may wait beyond that.
struct BackgroundCheckSchedule: Equatable, Sendable {
    let interval: TimeInterval
    let tolerance: TimeInterval

    init(hours: Int) {
        interval = TimeInterval(max(1, hours) * 3600)
        // macOS requires tolerance to be strictly less than the interval.
        // Keep a generous window so discretionary work need not run on wake.
        tolerance = interval / 2
    }
}

/// Decides whether a scheduler invocation is allowed to check right now.
enum BackgroundCheckRunner {
    static func handle(
        shouldDefer: Bool,
        perform: @escaping @MainActor () async -> Void,
        completion: (NSBackgroundActivityScheduler.Result) -> Void
    ) {
        // Set when now is a bad time, including just after the user wakes the
        // Mac and starts using it. Postponing leaves the retry to the system.
        if shouldDefer {
            completion(.deferred)
            return
        }
        Task { @MainActor in
            await perform()
        }
        completion(.finished)
    }
}

protocol BackgroundActivityScheduling: AnyObject {
    var repeats: Bool { get set }
    var interval: TimeInterval { get set }
    var tolerance: TimeInterval { get set }
    var qualityOfService: QualityOfService { get set }
    var shouldDefer: Bool { get }
    func schedule(_ block: @escaping @Sendable (NSBackgroundActivityScheduler.CompletionHandler) -> Void)
    func invalidate()
}

/// `NSBackgroundActivityScheduler` with the shape the check scheduler needs.
final class SystemBackgroundActivity: BackgroundActivityScheduling {
    private let activity: NSBackgroundActivityScheduler

    init(identifier: String) {
        activity = NSBackgroundActivityScheduler(identifier: identifier)
    }

    var repeats: Bool {
        get { activity.repeats }
        set { activity.repeats = newValue }
    }

    var interval: TimeInterval {
        get { activity.interval }
        set { activity.interval = newValue }
    }

    var tolerance: TimeInterval {
        get { activity.tolerance }
        set { activity.tolerance = newValue }
    }

    var qualityOfService: QualityOfService {
        get { activity.qualityOfService }
        set { activity.qualityOfService = newValue }
    }

    var shouldDefer: Bool { activity.shouldDefer }

    func schedule(_ block: @escaping @Sendable (NSBackgroundActivityScheduler.CompletionHandler) -> Void) {
        activity.schedule(block)
    }

    func invalidate() {
        activity.invalidate()
    }
}

/// Lets the system callback, which is not on the main actor, read the activity later.
private final class ActivityBox: @unchecked Sendable {
    private let activity: any BackgroundActivityScheduling
    init(_ activity: any BackgroundActivityScheduling) { self.activity = activity }
    var shouldDefer: Bool { activity.shouldDefer }
}
