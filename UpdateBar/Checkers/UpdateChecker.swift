import Foundation

/// What one source learned in one pass.
struct CheckerResult: Sendable {
    /// Newer versions this source found.
    var updates: [AvailableUpdate] = []
    /// Bundle IDs this source is authoritative for and answered about, whether or not
    /// it found an update. An app's highest-ranked covering source decides its status,
    /// so a fallback source can't contradict the app's real updater.
    var covered: [UpdateSource: Set<String>] = [:]
    var failures: [CheckFailure] = []
    /// Channel names each Sparkle feed uses, stable-named ones included.
    var feedChannels: [String: Set<String>] = [:]

    mutating func cover(_ bundleIdentifier: String, by source: UpdateSource) {
        covered[source, default: []].insert(bundleIdentifier)
    }

    func isCovered(_ bundleIdentifier: String, by source: UpdateSource) -> Bool {
        covered[source]?.contains(bundleIdentifier) == true
    }

    mutating func merge(_ other: CheckerResult) {
        updates += other.updates
        covered.merge(other.covered) { $0.union($1) }
        failures += other.failures
        feedChannels.merge(other.feedChannels) { $0.union($1) }
    }
}

protocol UpdateChecker: Sendable {
    var source: UpdateSource { get }
    func check(_ apps: [InstalledApp]) async -> CheckerResult
}

/// Small HTTP helper shared by the checkers: short timeouts, no cookies, HTTPS only.
struct HTTPClient: Sendable {
    let session: URLSession

    static let shared = HTTPClient()

    init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        configuration.httpAdditionalHeaders = ["User-Agent": "UpdateBar/\(Self.appVersion)"]
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: HTTPSRedirectDelegate(), delegateQueue: nil)
    }

    init(session: URLSession) { self.session = session }

    enum HTTPError: LocalizedError {
        case insecure(URL)
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .insecure: "Its update feed uses plain HTTP, which UpdateBar won't trust."
            case let .status(code): "The server answered \(code)."
            }
        }
    }

    /// Fetches `url`, upgrading plain HTTP to HTTPS. Feeds that only work over HTTP
    /// are reported rather than trusted, since their download links could be tampered with.
    func data(from url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var target = url
        if url.scheme?.lowercased() == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            guard let upgraded = components?.url else { throw HTTPError.insecure(url) }
            target = upgraded
        }
        guard target.scheme?.lowercased() == "https", target.host != nil else { throw HTTPError.insecure(url) }
        var request = URLRequest(url: target)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.status(0) }
            guard http.url?.scheme?.lowercased() == "https" else { throw HTTPError.insecure(http.url ?? target) }
            return (data, http)
        } catch let error as URLError where target != url {
            // The HTTPS upgrade failed outright; say so plainly instead of falling back to HTTP.
            if [.cannotConnectToHost, .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .cannotFindHost]
                .contains(error.code) {
                throw HTTPError.insecure(url)
            }
            throw error
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Refuse HTTPS → HTTP redirects before making the insecure request.
final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

extension Sequence where Element: Sendable {
    /// Runs `transform` over the sequence with at most `limit` tasks in flight.
    func concurrentMap<T: Sendable>(
        limit: Int,
        _ transform: @escaping @Sendable (Element) async -> T
    ) async -> [T] {
        var results: [T] = []
        await withTaskGroup(of: (Int, T).self) { group in
            var iterator = Array(self).enumerated().makeIterator()
            var buffer: [(Int, T)] = []
            for _ in 0..<limit {
                guard let (index, element) = iterator.next() else { break }
                group.addTask { (index, await transform(element)) }
            }
            while let finished = await group.next() {
                buffer.append(finished)
                if let (index, element) = iterator.next() {
                    group.addTask { (index, await transform(element)) }
                }
            }
            results = buffer.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return results
    }
}

extension String {
    /// Turns release-note HTML or Markdown-ish text into readable plain text.
    var plainTextFromHTML: String {
        var text = self
        let replacements: [(String, String)] = [
            ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"),
            ("</p>", "\n\n"), ("</li>", "\n"), ("<li>", "• "), ("</h1>", "\n"), ("</h2>", "\n"),
            ("</h3>", "\n"), ("</h4>", "\n"), ("</ul>", "\n"), ("</ol>", "\n"),
        ]
        for (tag, value) in replacements {
            text = text.replacingOccurrences(of: tag, with: value, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&nbsp;": " ", "&#8217;": "’", "&#8220;": "“", "&#8221;": "”"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
