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

/// Walks Homebrew's index bytes and copies out only the fields a check needs.
/// `JSONSerialization` turns the cask and formula files into a few hundred
/// megabytes of tiny objects, and those pages were still resident after the
/// check (about 276 MB). Skipping the rest — bottle URLs, checksums, caveats —
/// never allocates them.
struct JSONParseError: Error, Sendable {}

enum JSONScan {
    static func with<T>(_ data: Data, _ body: (JSONCursor) throws -> T) throws -> T {
        try data.withUnsafeBytes { raw in
            let cursor = JSONCursor(bytes: raw.bindMemory(to: UInt8.self))
            let value = try body(cursor)
            try cursor.finishDocument()
            return value
        }
    }
}

/// Valid only for the `JSONScan.with` call that created it. The pointer is the
/// file buffer; strings we keep are copies.
final class JSONCursor {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    private static let maxDepth = 64

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    func finishDocument() throws {
        skipWhitespace()
        guard index == bytes.count else { throw JSONParseError() }
    }

    func peekByte() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    func readArray(_ each: (JSONCursor) throws -> Void) throws {
        skipWhitespace()
        try expect(UInt8(ascii: "["))
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return }
        while true {
            try each(self)
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return }
            try expect(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    func readObject(_ each: (JSONCursor, String) throws -> Void) throws {
        skipWhitespace()
        try expect(UInt8(ascii: "{"))
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return }
        while true {
            let key = try readString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            try each(self, key)
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return }
            try expect(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    /// A JSON string, or nil when the value is null or some other type.
    func takeString() throws -> String? {
        guard peekByte() == UInt8(ascii: "\"") else {
            try skipValue()
            return nil
        }
        return try readString()
    }

    /// `true` or `false`. Anything else, including null, is false — the same as
    /// a failed `as? Bool` cast on a parsed object.
    func takeBool() throws -> Bool {
        switch peekByte() {
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return true
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return false
        default:
            try skipValue()
            return false
        }
    }

    /// A whole number, or 0 when the value isn't one.
    func takeInt() throws -> Int {
        guard let byte = peekByte(), byte == UInt8(ascii: "-") || isDigit(byte) else {
            try skipValue()
            return 0
        }
        let start = index
        try skipNumber()
        guard (start..<index).allSatisfy({ bytes[$0] != UInt8(ascii: ".") && bytes[$0] != UInt8(ascii: "e") && bytes[$0] != UInt8(ascii: "E") }),
              let value = Int(string(from: start, to: index))
        else { return 0 }
        return value
    }

    func skipValue() throws {
        skipWhitespace()
        guard let byte = peekByte() else { throw JSONParseError() }
        switch byte {
        case UInt8(ascii: "\""): try skipString()
        case UInt8(ascii: "t"): try expectLiteral("true")
        case UInt8(ascii: "f"): try expectLiteral("false")
        case UInt8(ascii: "n"): try expectLiteral("null")
        case UInt8(ascii: "{"), UInt8(ascii: "["): try skipContainer()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try skipNumber()
        default: throw JSONParseError()
        }
    }

    func readString() throws -> String {
        try expect(UInt8(ascii: "\""))
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                return try readEscapedString(copying: start)
            }
            if byte == UInt8(ascii: "\"") {
                let value = string(from: start, to: index)
                index += 1
                return value
            }
            if byte < 0x20 { throw JSONParseError() }
            index += 1
        }
        throw JSONParseError()
    }

    private func readEscapedString(copying start: Int) throws -> String {
        var out: [UInt8] = []
        out.reserveCapacity(index - start + 16)
        out.append(contentsOf: bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { throw JSONParseError() }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"): try appendUnicode(to: &out)
                default: throw JSONParseError()
                }
                continue
            }
            if byte < 0x20 { throw JSONParseError() }
            out.append(byte)
            index += 1
        }
        throw JSONParseError()
    }

    private func appendUnicode(to out: inout [UInt8]) throws {
        let unit = try readHex4()
        if let scalar = Unicode.Scalar(UInt32(unit)) {
            out.append(contentsOf: String(scalar).utf8)
            return
        }
        guard UTF16.isLeadSurrogate(unit),
              index + 1 < bytes.count,
              bytes[index] == UInt8(ascii: "\\"),
              bytes[index + 1] == UInt8(ascii: "u")
        else {
            out.append(contentsOf: "\u{FFFD}".utf8)
            return
        }
        index += 2
        let trail = try readHex4()
        guard UTF16.isTrailSurrogate(trail) else {
            out.append(contentsOf: "\u{FFFD}".utf8)
            return
        }
        let combined = 0x10000 + (Int(unit) - 0xD800) * 0x400 + (Int(trail) - 0xDC00)
        if let scalar = Unicode.Scalar(UInt32(combined)) {
            out.append(contentsOf: String(scalar).utf8)
        } else {
            out.append(contentsOf: "\u{FFFD}".utf8)
        }
    }

    private func readHex4() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw JSONParseError() }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            value <<= 4
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                value += UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                value += UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                value += UInt16(byte - UInt8(ascii: "A") + 10)
            default:
                throw JSONParseError()
            }
        }
        return value
    }

    private func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw JSONParseError() }
    }

    private func expectLiteral(_ literal: StaticString) throws {
        var offset = 0
        for byte in literal.utf8 {
            guard index + offset < bytes.count, bytes[index + offset] == byte else { throw JSONParseError() }
            offset += 1
        }
        index += offset
    }

    private func skipString() throws {
        try expect(UInt8(ascii: "\""))
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else { throw JSONParseError() }
                index += 2
                continue
            }
            index += 1
            if byte == UInt8(ascii: "\"") { return }
            if byte < 0x20 { throw JSONParseError() }
        }
        throw JSONParseError()
    }

    private func skipContainer() throws {
        guard let opening = peekByte() else { throw JSONParseError() }
        var closers: [UInt8] = [opening == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")]
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                try skipString()
                continue
            }
            index += 1
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                guard closers.count < Self.maxDepth else { throw JSONParseError() }
                closers.append(byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]"))
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                guard closers.popLast() == byte else { throw JSONParseError() }
                if closers.isEmpty { return }
            }
        }
        throw JSONParseError()
    }

    private func skipNumber() throws {
        _ = consume(UInt8(ascii: "-"))
        let whole = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        guard index > whole else { throw JSONParseError() }
        if consume(UInt8(ascii: ".")) {
            let fraction = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > fraction else { throw JSONParseError() }
        }
        if peekByte() == UInt8(ascii: "e") || peekByte() == UInt8(ascii: "E") {
            index += 1
            if peekByte() == UInt8(ascii: "+") || peekByte() == UInt8(ascii: "-") { index += 1 }
            let exponent = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > exponent else { throw JSONParseError() }
        }
    }

    private func string(from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
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
        // A default cache keeps the cask and formula responses (about 50 MB)
        // for the life of this process. UpdateBar already stores those on disk.
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
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
