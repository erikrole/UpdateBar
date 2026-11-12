import AppUpdater
import Foundation

/// Checks GitHub Releases for apps that ship neither Sparkle nor a cask, such as
/// your own builds. Each app is linked to an `owner/repo` explicitly; apps with a
/// `com.erole.` bundle ID are linked to `erikrole/<name>` automatically.
struct GitHubChecker: UpdateChecker {
    let source = UpdateSource.github
    var client = HTTPClient.shared
    var repositories: [String: String] = [:]

    static let automaticPrefix = "com.erole."
    static let automaticOwner = "erikrole"
    static let selfUpdatingApps: Set<String> = [
        "com.erole.Fetch", "com.erole.Offload", "com.erole.Scratchpad", "com.erole.Cutdown",
        "com.erole.SnipBar", "com.erole.StatBar", "com.erole.TVBar", "com.erole.Tweaks", "com.erole.UpdateBar",
    ]

    func check(_ apps: [InstalledApp]) async -> CheckerResult {
        let linked: [(InstalledApp, [String])] = apps.compactMap { app in
            let repos = Self.repositories(for: app, overrides: repositories)
            return repos.isEmpty ? nil : (app, repos)
        }
        let client = client
        let results = await linked.concurrentMap(limit: 4) { pair -> CheckerResult in
            // The first repository that has a published release answers; a 404 moves on to the next.
            for repo in pair.1 {
                if let result = await Self.check(pair.0, repository: repo, client: client) { return result }
            }
            return CheckerResult()
        }
        return results.reduce(into: CheckerResult()) { $0.merge($1) }
    }

    static func repository(for app: InstalledApp, overrides: [String: String]) -> String? {
        repositories(for: app, overrides: overrides).first
    }

    /// Where to look, in order. Own apps whose source repository is private publish from a public
    /// `<name>-releases` repository (Fetch: erikrole/fetch-releases), which is tried when the first has no release.
    static func repositories(for app: InstalledApp, overrides: [String: String]) -> [String] {
        if let repo = overrides[app.bundleIdentifier]?.trimmingCharacters(in: .whitespaces), repo.contains("/") {
            return [repo]
        }
        if app.bundleIdentifier == "com.erole.Scratchpad" { return ["erikrole/releases"] }
        guard let repo = automaticRepository(for: app) else { return [] }
        let name = String(repo.dropFirst(automaticOwner.count + 1))
        return [repo, "\(automaticOwner)/\(name.lowercased())-releases"]
    }

    private static func automaticRepository(for app: InstalledApp) -> String? {
        guard app.bundleIdentifier.hasPrefix(automaticPrefix) else { return nil }
        let name = String(app.bundleIdentifier.dropFirst(automaticPrefix.count))
        guard !name.isEmpty, !name.contains(".") else { return nil }
        return "\(automaticOwner)/\(name)"
    }

    /// nil when the repository has no published release (or doesn't exist), so the next candidate can be tried.
    private static func check(_ app: InstalledApp, repository: String, client: HTTPClient) async -> CheckerResult? {
        var result = CheckerResult()
        let isScratchpadFeed = app.bundleIdentifier == "com.erole.Scratchpad" && repository == "erikrole/releases"
        let endpoint = isScratchpadFeed ? "releases?per_page=100" : "releases/latest"
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/\(endpoint)") else { return nil }
        do {
            let (data, response) = try await client.data(from: url, headers: ["Accept": "application/vnd.github+json"])
            switch response.statusCode {
            case 200..<300: break
            case 404: return nil // No published release here; nothing to say.
            default: throw HTTPClient.HTTPError.status(response.statusCode)
            }
            if isScratchpadFeed {
                guard let release = ReleaseInfo.newest(inList: data, assetName: "Scratchpad.zip",
                                                       allowPrerelease: false, tagPrefix: "scratchpad-") else {
                    return result
                }
                result.cover(app.bundleIdentifier, by: .github)
                if ReleaseInfo.isNewer(release.version, than: app.displayVersion) {
                    result.updates.append(AvailableUpdate(bundleIdentifier: app.bundleIdentifier, source: .github,
                        version: release.version, comparableVersion: release.version, releaseDate: release.date,
                        releaseNotes: release.notes, releaseNotesURL: release.pageURL, downloadURL: release.downloadURL,
                        action: .launchApp))
                }
                return result
            }
            let release = try autoreleasepool { try JSONDecoder.iso8601.decode(GitHubRelease.self, from: data) }
            result.cover(app.bundleIdentifier, by: .github)
            if let update = update(for: app, release: release, repository: repository) { result.updates.append(update) }
        } catch {
            result.failures.append(CheckFailure(source: .github, subject: app.name, message: error.localizedDescription))
        }
        return result
    }

    static func update(for app: InstalledApp, release: GitHubRelease, repository: String? = nil) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease else { return nil }
        let version = VersionComparator.normalize(release.tagName)
        guard VersionComparator.isNewer(version, than: app.displayVersion) else { return nil }
        let asset = release.assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") || name.hasSuffix(".dmg") || name.hasSuffix(".pkg")
        }
        // Own releases ship a DMG or a signed app ZIP (AppUpdater apps); DMGInstaller verifies either
        // against our Team ID, so they install in place. A DMG wins when both exist. UpdateBar updates itself through AppUpdater, never through its own installer.
        let installable = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? release.assets.first { asset in
                let name = asset.name.lowercased()
                return name.hasSuffix(".zip") && !name.hasPrefix("fetch-") && !name.contains("-cli") && !name.contains("extension")
            }
        let ownRelease = repository?.hasPrefix(automaticOwner + "/") == true
        let action: UpdateAction
        if selfUpdatingApps.contains(app.bundleIdentifier) {
            action = .launchApp
        } else if ownRelease, let installable {
            action = .dmgInstall(installable.downloadURL)
        } else {
            action = .openURL(release.htmlURL)
        }
        return AvailableUpdate(
            bundleIdentifier: app.bundleIdentifier,
            source: .github,
            version: version,
            comparableVersion: version,
            releaseDate: release.publishedAt,
            releaseNotes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            releaseNotesURL: release.htmlURL,
            downloadURL: asset?.downloadURL,
            action: action
        )
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease, assets
        case publishedAt = "published_at"
    }
}
