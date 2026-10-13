import Foundation

/// Reads each app's Sparkle appcast and reports the newest release this Mac can run.
struct SparkleChecker: UpdateChecker {
    let source = UpdateSource.sparkle
    var client = HTTPClient.shared
    var systemVersion = ProcessInfo.processInfo.operatingSystemVersion
    /// Apps you've opted into beta releases for.
    var betaApps: Set<String> = []

    func check(_ apps: [InstalledApp]) async -> CheckerResult {
        let candidates = apps.filter { $0.sparkleFeedURL != nil && !$0.hasAppStoreReceipt }
        let client = client
        let systemVersion = systemVersion
        let betaApps = betaApps
        let results = await candidates.concurrentMap(limit: 8) { app -> CheckerResult in
            await Self.check(app, client: client, systemVersion: systemVersion,
                             includeBetas: betaApps.contains(app.bundleIdentifier))
        }
        return results.reduce(into: CheckerResult()) { $0.merge($1) }
    }

    private static func check(
        _ app: InstalledApp,
        client: HTTPClient,
        systemVersion: OperatingSystemVersion,
        includeBetas: Bool
    ) async -> CheckerResult {
        guard let feed = app.sparkleFeedURL else { return CheckerResult() }
        var result = CheckerResult()
        do {
            let (data, response) = try await client.data(from: feed)
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPClient.HTTPError.status(response.statusCode)
            }
            let items = AppcastParser.parse(data)
            guard !items.isEmpty else {
                result.failures.append(CheckFailure(source: .sparkle, subject: app.name, message: "Its update feed had no releases."))
                return result
            }
            result.cover(app.bundleIdentifier, by: .sparkle)
            let channels = Set(items.compactMap(\.channel))
            if !channels.isEmpty { result.feedChannels[app.bundleIdentifier] = channels }
            if let item = newestCompatible(items, systemVersion: systemVersion, includeBetas: includeBetas),
               let update = update(for: app, item: item) {
                result.updates.append(update)
            }
        } catch {
            result.failures.append(CheckFailure(source: .sparkle, subject: app.name, message: error.localizedDescription))
        }
        return result
    }

    /// The newest item whose minimum macOS this Mac meets: stable only, or any
    /// channel when you've opted the app into betas.
    static func newestCompatible(
        _ items: [AppcastItem],
        systemVersion: OperatingSystemVersion,
        includeBetas: Bool = false
    ) -> AppcastItem? {
        let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        return items
            .filter { includeBetas || !$0.isPrerelease }
            .filter { $0.operatingSystem == nil || $0.operatingSystem == "macos" }
            .filter { item in
                guard let minimum = item.minimumSystemVersion else { return true }
                return VersionComparator.compare(system, to: minimum) != .older
            }
            .filter { item in
                guard let maximum = item.maximumSystemVersion else { return true }
                return VersionComparator.compare(system, to: maximum) != .newer
            }
            .filter { $0.version != nil || $0.shortVersion != nil }
            .max { lhs, rhs in
                VersionComparator.isNewer(rhs.version ?? rhs.shortVersion ?? "", than: lhs.version ?? lhs.shortVersion ?? "")
            }
    }

    /// Sparkle compares builds (`CFBundleVersion` against `sparkle:version`).
    static func update(for app: InstalledApp, item: AppcastItem) -> AvailableUpdate? {
        let isNewer: Bool
        let shortOrder = item.shortVersion.flatMap { itemShort in
            app.shortVersion.map { VersionComparator.compare(itemShort, to: $0) }
        }
        if let itemBuild = item.version, let appBuild = app.buildVersion {
            // Sparkle's own rule: the build decides. A readable version that went
            // backwards vetoes it, so an odd build scheme can't flag a current app.
            isNewer = VersionComparator.isNewer(itemBuild, than: appBuild) && shortOrder != .older
        } else if let shortOrder {
            isNewer = shortOrder == .newer
        } else if let itemBuild = item.version {
            isNewer = VersionComparator.isNewer(itemBuild, than: app.displayVersion)
        } else {
            isNewer = false
        }
        guard isNewer else { return nil }

        return AvailableUpdate(
            bundleIdentifier: app.bundleIdentifier,
            source: .sparkle,
            version: item.shortVersion ?? item.version ?? "?",
            comparableVersion: item.version ?? item.shortVersion ?? "?",
            releaseDate: item.publishedAt,
            releaseNotes: item.notes?.plainTextFromHTML.nilIfEmpty,
            releaseNotesURL: item.releaseNotesURL,
            downloadURL: item.downloadURL,
            action: app.hasSparkleEDKey ? .sparkleInstall : .launchApp,
            channel: item.isPrerelease ? item.channel : nil
        )
    }
}

struct AppcastItem: Equatable, Sendable {
    /// Channel names some feeds (OBS, for one) put on their regular releases.
    static let stableChannelNames: Set<String> = ["stable", "release", "production", "default"]

    var title: String?
    var version: String?
    var shortVersion: String?
    var minimumSystemVersion: String?
    var maximumSystemVersion: String?
    var operatingSystem: String?
    var channel: String?
    var publishedAt: Date?
    var notes: String?
    var releaseNotesURL: URL?
    var downloadURL: URL?

    /// On a pre-release channel such as "beta". Sparkle treats untagged items as the
    /// default channel; a few feeds tag their stable releases too.
    var isPrerelease: Bool {
        guard let channel else { return false }
        return !Self.stableChannelNames.contains(channel.lowercased())
    }

    static func isPrereleaseChannel(_ channel: String) -> Bool {
        !stableChannelNames.contains(channel.lowercased())
    }
}

/// A forgiving Sparkle appcast parser. Accepts versions on the enclosure or as child
/// elements, and ignores anything it doesn't understand.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var elements: [String] = []
    private let dateFormatter = DateFormatter()

    static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        let parent = elements.last
        elements.append(elementName)
        text = ""
        if elementName == "item", parent == "channel" {
            current = AppcastItem()
        } else if elementName == "enclosure", parent == "item", current != nil,
                  attributes["sparkle:deltaFrom"] == nil {
            if let url = attributes["url"].flatMap(URL.init(string:)) { current?.downloadURL = url }
            if let version = attributes["sparkle:version"] { current?.version = version }
            if let short = attributes["sparkle:shortVersionString"] { current?.shortVersion = short }
            if let minimum = attributes["sparkle:minimumSystemVersion"] { current?.minimumSystemVersion = minimum }
            if let maximum = attributes["sparkle:maximumSystemVersion"] { current?.maximumSystemVersion = maximum }
            current?.operatingSystem = attributes["sparkle:os"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = ""; elements.removeLast() }
        guard current != nil, elementName == "item" || elements.dropLast().last == "item" else { return }
        switch elementName {
        case "item":
            if let current { items.append(current) }
            current = nil
        case "title": current?.title = value.nilIfEmpty
        case "sparkle:version": current?.version = value.nilIfEmpty
        case "sparkle:shortVersionString": current?.shortVersion = value.nilIfEmpty
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value.nilIfEmpty
        case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value.nilIfEmpty
        case "sparkle:channel": current?.channel = value.nilIfEmpty
        case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink":
            if current?.releaseNotesURL == nil { current?.releaseNotesURL = URL(string: value) }
        case "description": current?.notes = value.nilIfEmpty
        case "pubDate": current?.publishedAt = parseDate(value)
        default: break
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = dateFormatter
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
