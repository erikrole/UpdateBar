import Foundation

/// Keeps a local copy of a large Homebrew index (casks ~20 MB, formulae ~30 MB) and
/// revalidates it with its ETag, so a check is fresh within minutes of Homebrew
/// publishing but only downloads the file again when it actually changed.
struct IndexCache: Sendable {
    let remoteURL: URL
    let fileURL: URL
    var client = HTTPClient.shared
    /// Homebrew's CDN serves these with `max-age=600`; don't ask more often than that.
    var revalidateAfter: TimeInterval = 10 * 60

    private var etagURL: URL { fileURL.appendingPathExtension("etag") }

    static func homebrew(_ name: String) -> IndexCache {
        IndexCache(
            remoteURL: URL(string: "https://formulae.brew.sh/api/\(name).json")!,
            fileURL: URL.applicationSupportDirectory.appending(path: "UpdateBar/\(name).json")
        )
    }

    func load() async throws -> Data {
        let fileManager = FileManager.default
        let cached = try? Data(contentsOf: fileURL)
        let modified = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        if let cached, let modified, Date().timeIntervalSince(modified) < revalidateAfter {
            return cached
        }

        var headers: [String: String] = [:]
        if cached != nil, let etag = try? String(contentsOf: etagURL, encoding: .utf8) {
            headers["If-None-Match"] = etag
        }
        do {
            let (data, response) = try await client.data(from: remoteURL, headers: headers)
            if response.statusCode == 304, let cached {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                return cached
            }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPClient.HTTPError.status(response.statusCode)
            }
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
            }
            return data
        } catch {
            // Offline: a stale index is better than none.
            if let cached { return cached }
            throw error
        }
    }
}
