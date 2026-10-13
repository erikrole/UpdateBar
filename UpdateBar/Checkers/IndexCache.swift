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
        let modified = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        if let modified, Date().timeIntervalSince(modified) < revalidateAfter,
           let cached = decodeFile(decode) {
            return IndexSnapshot(value: cached, validatedAt: modified)
        }

        var headers: [String: String] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path),
           let etag = try? String(contentsOf: etagURL, encoding: .utf8) {
            headers["If-None-Match"] = etag
        }
        do {
            let (data, response) = try await client.data(from: remoteURL, headers: headers)
            if response.statusCode == 304, let cached = decodeFile(decode) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                return IndexSnapshot(value: cached)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPClient.HTTPError.status(response.statusCode)
            }
            let etag = response.value(forHTTPHeaderField: "ETag")
            // Decode inside a pool so the multi-megabyte JSON object graph is
            // freed before this check returns. The cooperative thread pool does
            // not drain its own pool between jobs, and that graph was sticking
            // around for the life of the menu bar process.
            let decoded = try autoreleasepool { () -> Value in
                let value = try decode(data)
                persist(data, etag: etag)
                return value
            }
            return IndexSnapshot(value: decoded)
        } catch {
            if let cached = decodeFile(decode) {
                return IndexSnapshot(value: cached, warning: "\(error.localizedDescription) Showing a cached index.")
            }
            throw error
        }
    }

    private func decodeFile<Value>(_ decode: (Data) throws -> Value) -> Value? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? decode(data)
        }
    }

    private func persist(_ data: Data, etag: String?) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // An old validator must never be paired with a new payload.
            try? fileManager.removeItem(at: etagURL)
            if let etag {
                try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
            }
        } catch { /* This check can still use the validated network response. */ }
    }
}

/// Keeps a decoded index for the freshness window, then drops it. Concurrent
/// callers still share one load. Holding both Homebrew indexes past that window
/// left the menu bar process idle on the decoded lists for hours.
actor DecodedIndex<Value: Sendable> {
    private struct Key: Hashable {
        let remote: URL
        let file: URL
    }

    private struct Entry {
        var snapshot: IndexSnapshot<Value>
        var expiresAt: Date
        var generation: UInt
    }

    private var entries: [Key: Entry] = [:]
    private var generations: [Key: UInt] = [:]
    private var loading: [Key: Task<IndexSnapshot<Value>, Error>] = [:]

    func load(from index: IndexCache, now: Date = Date(), decode: @escaping @Sendable (Data) throws -> Value) async throws -> IndexSnapshot<Value> {
        let key = Key(remote: index.remoteURL, file: index.fileURL)
        evictExpired(at: now)
        if let entry = entries[key] {
            return entry.snapshot
        }
        if let task = loading[key] { return try await task.value }
        let task = Task { try await index.load(decode: decode) }
        loading[key] = task
        defer { loading[key] = nil }
        let value = try await task.value
        retain(value, for: key, revalidateAfter: index.revalidateAfter)
        return value
    }

    /// True when a fresh decoded value is still being held for this index.
    func retainsFreshEntry(for index: IndexCache, now: Date = Date()) -> Bool {
        let key = Key(remote: index.remoteURL, file: index.fileURL)
        guard let entry = entries[key] else { return false }
        return entry.expiresAt > now
    }

    /// Drops indexes whose freshness window has ended. The idle timer calls
    /// this on its own; tests call it with a chosen clock.
    func evictExpired(at now: Date = Date()) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func retain(_ value: IndexSnapshot<Value>, for key: Key, revalidateAfter: TimeInterval) {
        guard value.warning == nil else { return }
        let remaining = revalidateAfter - Date().timeIntervalSince(value.validatedAt)
        guard remaining > 0 else { return }
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        entries[key] = Entry(
            snapshot: value,
            expiresAt: value.validatedAt.addingTimeInterval(revalidateAfter),
            generation: generation
        )
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(remaining))
            await self.evict(key, generation: generation)
        }
    }

    private func evict(_ key: Key, generation: UInt) {
        guard entries[key]?.generation == generation else { return }
        entries[key] = nil
    }
}
