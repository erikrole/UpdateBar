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

    func check(_ apps: [InstalledApp]) async -> CheckerResult {
        let linked: [(InstalledApp, String)] = apps.compactMap { app in
            guard let repo = Self.repository(for: app, overrides: repositories) else { return nil }
            return (app, repo)
        }
        let client = client
        let results = await linked.concurrentMap(limit: 4) { pair -> CheckerResult in
            await Self.check(pair.0, repository: pair.1, client: client)
        }
        return results.reduce(into: CheckerResult()) { $0.merge($1) }
    }

    static func repository(for app: InstalledApp, overrides: [String: String]) -> String? {
        if let repo = overrides[app.bundleIdentifier]?.trimmingCharacters(in: .whitespaces), repo.contains("/") {
            return repo
        }
        guard app.bundleIdentifier.hasPrefix(automaticPrefix) else { return nil }
        let name = String(app.bundleIdentifier.dropFirst(automaticPrefix.count))
        guard !name.isEmpty, !name.contains(".") else { return nil }
        return "\(automaticOwner)/\(name)"
    }

    private static func check(_ app: InstalledApp, repository: String, client: HTTPClient) async -> CheckerResult {
        var result = CheckerResult()
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return result }
        do {
            let (data, response) = try await client.data(from: url, headers: ["Accept": "application/vnd.github+json"])
            switch response.statusCode {
            case 200..<300: break
            case 404: return result // No published release yet; nothing to say.
            default: throw HTTPClient.HTTPError.status(response.statusCode)
            }
            let release = try autoreleasepool { try JSONDecoder.iso8601.decode(GitHubRelease.self, from: data) }
            result.cover(app.bundleIdentifier, by: .github)
            if let update = update(for: app, release: release) { result.updates.append(update) }
        } catch {
            result.failures.append(CheckFailure(source: .github, subject: app.name, message: error.localizedDescription))
        }
        return result
    }

    static func update(for app: InstalledApp, release: GitHubRelease) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease else { return nil }
        let version = VersionComparator.normalize(release.tagName)
        guard VersionComparator.isNewer(version, than: app.displayVersion) else { return nil }
        let asset = release.assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") || name.hasSuffix(".dmg") || name.hasSuffix(".pkg")
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
            action: .openURL(release.htmlURL)
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
