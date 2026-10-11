import Foundation

/// Turns every source's findings into at most one row per app.
///
/// An app's highest-ranked covering source decides: if the App Store or the app's
/// own Sparkle feed says it is current, a Homebrew or GitHub hint can't override
/// that. Only when no covering source answered does the best remaining hint show.
enum UpdateResolver {
    static func resolve(
        apps: [InstalledApp],
        result: CheckerResult,
        ignoredApps: Set<String>,
        skippedVersions: [String: String]
    ) -> [AppUpdate] {
        let updatesByApp = Dictionary(grouping: result.updates, by: \.bundleIdentifier)
        var rows: [AppUpdate] = []

        for app in apps where !ignoredApps.contains(app.bundleIdentifier) {
            guard let updates = updatesByApp[app.bundleIdentifier], !updates.isEmpty else { continue }
            let sorted = updates.sorted { $0.source < $1.source }

            let decidingSource = UpdateSource.allCases.sorted().first { source in
                result.isCovered(app.bundleIdentifier, by: source)
            }

            let chosen: AvailableUpdate?
            if let decidingSource {
                chosen = sorted.first { $0.source == decidingSource }
            } else {
                chosen = sorted.first
            }
            guard let chosen else { continue }
            if skippedVersions[app.bundleIdentifier] == chosen.version { continue }

            rows.append(AppUpdate(
                app: app,
                update: chosen,
                alsoReportedBy: sorted.map(\.source).filter { $0 != chosen.source }
            ))
        }
        return rows.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }
}
