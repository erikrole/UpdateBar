import Foundation

struct IndexSnapshot<Value: Sendable>: Sendable {
    let value: Value
    var warning: String?
    var validatedAt = Date()
}

/// Revalidates Homebrew's indexes by ETag, validates before replacing a good
/// cached file, and makes offline fallback visible to the caller.
struct IndexCache: Sendable {
    let remoteURL: URL
    let fileURL: URL
    var client = HTTPClient.shared
    var revalidateAfter: TimeInterval = 10 * 60

    private var etagURL: URL { fileURL.appendingPathExtension("etag") }

    static func homebrew(_ name: String) -> IndexCache {
        IndexCache(
            remoteURL: URL(string: "https://formulae.brew.sh/api/\(name).json")!,
            fileURL: URL.applicationSupportDirectory.appending(path: "UpdateBar/\(name).json")
        )
    }

    func load<Value: Sendable>(decode: @Sendable (Data) throws -> Value) async throws -> IndexSnapshot<Value> {
        let fileManager = FileManager.default
        let cached = (try? Data(contentsOf: fileURL)).flatMap { try? decode($0) }
        let modified = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        if let cached, let modified, Date().timeIntervalSince(modified) < revalidateAfter {
            return IndexSnapshot(value: cached, validatedAt: modified)
        }

        var headers: [String: String] = [:]
        if cached != nil, let etag = try? String(contentsOf: etagURL, encoding: .utf8) {
            headers["If-None-Match"] = etag
        }
        do {
            let (data, response) = try await client.data(from: remoteURL, headers: headers)
            if response.statusCode == 304, let cached {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                return IndexSnapshot(value: cached)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPClient.HTTPError.status(response.statusCode)
            }
            // Do not let a proxy's HTML error page poison a valid cache.
            let decoded = try decode(data)
            do {
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                // An old validator must never be paired with a new payload.
                try? fileManager.removeItem(at: etagURL)
                if let etag = response.value(forHTTPHeaderField: "ETag") {
                    try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
                }
            } catch { /* This check can still use the validated network response. */ }
            return IndexSnapshot(value: decoded)
        } catch {
            if let cached {
                return IndexSnapshot(value: cached, warning: "\(error.localizedDescription) Showing a cached index.")
            }
            throw error
        }
    }
}

/// Keeps the small decoded models, rather than rereading and parsing ~50 MB of
/// JSON on every refresh. Concurrent callers share one load; the disk/network
/// cache is still revalidated at its normal interval.
actor DecodedIndex<Value: Sendable> {
    private struct Key: Hashable {
        let remote: URL
        let file: URL
    }
    private var entries: [Key: IndexSnapshot<Value>] = [:]
    private var loading: [Key: Task<IndexSnapshot<Value>, Error>] = [:]

    func load(from index: IndexCache, now: Date = Date(), decode: @escaping @Sendable (Data) throws -> Value) async throws -> IndexSnapshot<Value> {
        let key = Key(remote: index.remoteURL, file: index.fileURL)
        if let entry = entries[key], now.timeIntervalSince(entry.validatedAt) < index.revalidateAfter {
            return entry
        }
        if let task = loading[key] { return try await task.value }
        let task = Task { try await index.load(decode: decode) }
        loading[key] = task
        defer { loading[key] = nil }
        let value = try await task.value
        if value.warning == nil { entries[key] = value }
        return value
    }
}
