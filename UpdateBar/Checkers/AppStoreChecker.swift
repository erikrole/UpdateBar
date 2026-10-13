import Foundation

/// Looks up App Store apps through Apple's public iTunes Search API, in batches.
/// It reads versions only; installs go through the App Store itself.
struct AppStoreChecker: UpdateChecker {
    let source = UpdateSource.appStore
    var client = HTTPClient.shared
    var country = Locale.current.region?.identifier.lowercased() ?? "us"

    func check(_ apps: [InstalledApp]) async -> CheckerResult {
        let storeApps = apps.filter(\.hasAppStoreReceipt)
        guard !storeApps.isEmpty else { return CheckerResult() }

        var result = CheckerResult()
        let batches = stride(from: 0, to: storeApps.count, by: 40).map {
            Array(storeApps[$0..<min($0 + 40, storeApps.count)])
        }
        for batch in batches {
            do {
                let lookups = try await lookup(batch.map(\.bundleIdentifier))
                result.merge(Self.evaluate(batch, lookups: lookups))
            } catch {
                result.failures.append(CheckFailure(source: .appStore, subject: "App Store", message: error.localizedDescription))
            }
        }
        return result
    }

    private func lookup(_ bundleIdentifiers: [String]) async throws -> [StoreLookup] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifiers.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: country),
        ]
        let (data, response) = try await client.data(from: components.url!)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPClient.HTTPError.status(response.statusCode)
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [StoreLookup] {
        try autoreleasepool { try JSONDecoder.iso8601.decode(LookupResponse.self, from: data).results }
    }

    static func evaluate(_ apps: [InstalledApp], lookups: [StoreLookup]) -> CheckerResult {
        var result = CheckerResult()
        let byBundle = Dictionary(lookups.map { ($0.bundleId, $0) }, uniquingKeysWith: { first, _ in first })
        for app in apps {
            guard let lookup = byBundle[app.bundleIdentifier] else { continue }
            result.cover(app.bundleIdentifier, by: .appStore)
            guard VersionComparator.isNewer(lookup.version, than: app.displayVersion) else { continue }
            result.updates.append(AvailableUpdate(
                bundleIdentifier: app.bundleIdentifier,
                source: .appStore,
                version: lookup.version,
                comparableVersion: lookup.version,
                releaseDate: lookup.currentVersionReleaseDate,
                releaseNotes: lookup.releaseNotes?.nilIfEmpty,
                releaseNotesURL: lookup.trackViewUrl,
                downloadURL: nil,
                action: .openAppStore
            ))
        }
        return result
    }

    private struct LookupResponse: Decodable {
        let results: [StoreLookup]
    }
}

struct StoreLookup: Decodable, Sendable {
    let bundleId: String
    let version: String
    let releaseNotes: String?
    let currentVersionReleaseDate: Date?
    let trackViewUrl: URL?
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
