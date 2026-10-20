import Foundation

/// Compares apps against Homebrew's public cask index.
///
/// For casks installed with Homebrew it is authoritative and offers `brew upgrade`.
/// For other apps it is a fallback that only speaks when no real updater answered,
/// and it opens the app or links its download instead of installing anything.
struct HomebrewChecker: UpdateChecker {
    let source = UpdateSource.homebrew
    var caskrooms: [URL] = HomebrewPlatform.folders("Caskroom")
    private static let decodedIndex = DecodedIndex<[Cask]>()
    var index = IndexCache.homebrew("cask")

    func check(_ apps: [InstalledApp]) async -> CheckerResult {
        do {
            let result = try await evaluated(apps)
            // `evaluated` is the last owner of the cask array. Drop the actor's
            // copy too, then return the parse's empty pages to the system.
            await Self.decodedIndex.removeAll()
            TransientMemory.release()
            return result
        } catch {
            await Self.decodedIndex.removeAll()
            TransientMemory.release()
            return CheckerResult(failures: [
                CheckFailure(source: .homebrew, subject: "Homebrew", message: error.localizedDescription),
            ])
        }
    }

    private func evaluated(_ apps: [InstalledApp]) async throws -> CheckerResult {
        let snapshot = try await Self.decodedIndex.load(from: index) { try Self.decode($0) }
        let installed = Self.installedCasks(in: caskrooms)
        var result = Self.evaluate(apps, casks: snapshot.value, installed: installed)
        if let warning = snapshot.warning {
            result.failures.append(CheckFailure(source: .homebrew, subject: "Homebrew", message: warning))
        }
        return result
    }

    // MARK: - Cask index

    static func decode(_ data: Data, platform: String = HomebrewPlatform.tag) throws -> [Cask] {
        try autoreleasepool {
            try JSONScan.with(data) { cursor in
                var casks: [Cask] = []
                try cursor.readArray { cursor in
                    guard cursor.peekByte() == UInt8(ascii: "{") else { throw JSONParseError() }
                    if let cask = try readCask(from: cursor, platform: platform) {
                        casks.append(cask)
                    }
                }
                return casks
            }
        }
    }

    /// One cask object. A matching `variations` entry replaces same-named fields
    /// after the base object is read, which is Homebrew's shallow merge.
    private static func readCask(from cursor: JSONCursor, platform: String) throws -> Cask? {
        var fields = CaskFields()
        var overlay: CaskFields?
        try cursor.readObject { cursor, key in
            if key == "variations" {
                overlay = try variation(from: cursor, platform: platform)
            } else {
                try apply(key, to: &fields, from: cursor)
            }
        }
        if let overlay { fields.apply(overlay) }
        return fields.cask()
    }

    private static func variation(from cursor: JSONCursor, platform: String) throws -> CaskFields? {
        guard cursor.peekByte() == UInt8(ascii: "{") else {
            try cursor.skipValue()
            return nil
        }
        var match: CaskFields?
        try cursor.readObject { cursor, key in
            guard key == platform, cursor.peekByte() == UInt8(ascii: "{") else {
                try cursor.skipValue()
                return
            }
            var fields = CaskFields()
            try cursor.readObject { cursor, key in
                try apply(key, to: &fields, from: cursor)
            }
            match = fields
        }
        return match
    }

    private static func apply(_ key: String, to fields: inout CaskFields, from cursor: JSONCursor) throws {
        switch key {
        case "token":
            fields.keys.insert(key)
            fields.token = try cursor.takeString()
        case "version":
            fields.keys.insert(key)
            fields.version = try cursor.takeString()
        case "homepage":
            fields.keys.insert(key)
            fields.homepage = try cursor.takeString()
        case "url":
            fields.keys.insert(key)
            fields.downloadURL = try cursor.takeString()
        case "disabled":
            fields.keys.insert(key)
            fields.disabled = try cursor.takeBool()
        case "deprecated":
            fields.keys.insert(key)
            fields.deprecated = try cursor.takeBool()
        case "auto_updates":
            fields.keys.insert(key)
            fields.autoUpdates = try cursor.takeBool()
        case "artifacts":
            fields.keys.insert(key)
            let artifacts = try artifacts(from: cursor)
            fields.appNames = artifacts.names
            fields.bundleIDs = artifacts.ids
            fields.footprintIDs = artifacts.footprint
        default:
            try cursor.skipValue()
        }
    }

    private static func artifacts(from cursor: JSONCursor) throws -> (names: [String], ids: Set<String>, footprint: Set<String>) {
        guard cursor.peekByte() == UInt8(ascii: "[") else {
            try cursor.skipValue()
            return ([], [], [])
        }
        var names: [String] = []
        var ids = Set<String>()
        var footprint = Set<String>()
        try cursor.readArray { cursor in
            guard cursor.peekByte() == UInt8(ascii: "{") else {
                try cursor.skipValue()
                return
            }
            try cursor.readObject { cursor, key in
                switch key {
                case "app":
                    try appNames(from: cursor, into: &names)
                case "uninstall", "zap":
                    try bundleIDs(from: cursor, into: &ids, footprint: &footprint)
                default:
                    try cursor.skipValue()
                }
            }
        }
        return (names, ids, footprint)
    }

    private static func appNames(from cursor: JSONCursor, into names: inout [String]) throws {
        guard cursor.peekByte() == UInt8(ascii: "[") else {
            try cursor.skipValue()
            return
        }
        try cursor.readArray { cursor in
            guard cursor.peekByte() == UInt8(ascii: "\"") else {
                try cursor.skipValue()
                return
            }
            let name = try cursor.readString()
            guard name.hasSuffix(".app"), let file = name.split(separator: "/", omittingEmptySubsequences: true).last else { return }
            names.append(String(file))
        }
    }

    /// `quit` and `signal` contribute a bundle ID only when they are a string or
    /// an array of strings. A signal dictionary names a process signal, not an ID.
    private static func bundleIDs(from cursor: JSONCursor, into ids: inout Set<String>, footprint: inout Set<String>) throws {
        guard cursor.peekByte() == UInt8(ascii: "[") else {
            try cursor.skipValue()
            return
        }
        try cursor.readArray { cursor in
            guard cursor.peekByte() == UInt8(ascii: "{") else {
                try cursor.skipValue()
                return
            }
            try cursor.readObject { cursor, key in
                switch key {
                case "quit", "signal":
                    try idValues(from: cursor, into: &ids)
                case "trash", "delete", "rmdir":
                    // Paths like "~/Library/Preferences/com.vendor.App.plist" name the app's real bundle ID.
                    var paths = Set<String>()
                    try idValues(from: cursor, into: &paths)
                    for path in paths { if let id = footprintID(in: path) { footprint.insert(id) } }
                default:
                    try cursor.skipValue()
                }
            }
        }
    }

    private static func idValues(from cursor: JSONCursor, into ids: inout Set<String>) throws {
        switch cursor.peekByte() {
        case UInt8(ascii: "\""):
            ids.insert(try cursor.readString())
        case UInt8(ascii: "["):
            try cursor.readArray { cursor in
                if cursor.peekByte() == UInt8(ascii: "\"") {
                    ids.insert(try cursor.readString())
                } else {
                    try cursor.skipValue()
                }
            }
        default:
            try cursor.skipValue()
        }
    }

    /// The reverse-DNS name at the end of a zap/uninstall path, if there is one:
    /// "~/Library/Preferences/com.vendor.App.plist" → "com.vendor.App".
    static func footprintID(in path: String) -> String? {
        guard var name = path.split(separator: "/").last.map(String.init) else { return nil }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        for suffix in [".plist", ".savedState", ".binarycookies", ".sfl2", ".sfl3"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              parts[0].allSatisfy(\.isLetter) else { return nil }
        return name
    }

    /// Resolve the installed .app artifacts to their real destinations. Cask
    /// uninstall/quit IDs can refer only to helpers; they do not prove ownership.
    static func installedCasks(in caskrooms: [URL]) -> [String: Set<URL>] {
        var installed: [String: Set<URL>] = [:]
        let fileManager = FileManager.default
        for room in caskrooms {
            guard let tokens = try? fileManager.contentsOfDirectory(at: room, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for token in tokens {
                guard let enumerator = fileManager.enumerator(at: token, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let artifact as URL in enumerator {
                    if artifact.pathExtension == "app" {
                        installed[token.lastPathComponent, default: []].insert(artifact.resolvingSymlinksInPath().standardizedFileURL)
                        enumerator.skipDescendants()
                    } else if enumerator.level >= 3 {
                        enumerator.skipDescendants()
                    }
                }
            }
        }
        return installed
    }

    // MARK: - Matching

    static func evaluate(_ apps: [InstalledApp], casks: [Cask], installed: [String: Set<URL>]) -> CheckerResult {
        var result = CheckerResult()
        var casksByApp: [String: [Cask]] = [:]
        for cask in casks {
            for appName in cask.appNames { casksByApp[appName.lowercased(), default: []].append(cask) }
        }

        for app in apps where !app.hasAppStoreReceipt {
            let bundleName = app.url.lastPathComponent.lowercased()
            guard let matches = casksByApp[bundleName] else { continue }

            // Prefer the cask Homebrew actually installed; otherwise only trust an
            // unambiguous match whose bundle ID, when the cask declares one, agrees.
            let cask: Cask
            let brewInstalled: Bool
            let agreeing = matches.filter { $0.bundleIdentifiers.isEmpty || $0.bundleIdentifiers.contains(app.bundleIdentifier) }
            let appURL = app.url.resolvingSymlinksInPath().standardizedFileURL
            let owned = matches.filter { installed[$0.token]?.contains(appURL) == true }
            if owned.count == 1, let match = owned.first {
                cask = match
                brewInstalled = true
            } else if !owned.isEmpty {
                continue
            } else {
                // Not installed by Homebrew, so the cask is only a guess from the app's name. Two different apps can
                // share a name (Fetch the downloader vs Fetch the FTP client), and following the guess would replace
                // one with the other, so the cask must also show it is this app.
                guard agreeing.count == 1, let only = agreeing.first, identifies(only, app) else { continue }
                cask = only
                brewInstalled = false
            }

            guard cask.version != "latest", !cask.isDisabled else { continue }
            let caskVersion = VersionComparator.normalize(cask.version)
            if brewInstalled { result.cover(app.bundleIdentifier, by: .homebrew) }

            let appIsBehind = VersionComparator.isNewer(caskVersion, than: app.displayVersion)
                && (app.buildVersion.map { !$0.isEmpty && caskVersion == VersionComparator.normalize($0) } != true)
            guard appIsBehind else { continue }
            if !brewInstalled, !plausiblySameScheme(caskVersion, app.displayVersion) { continue }

            result.updates.append(AvailableUpdate(
                bundleIdentifier: app.bundleIdentifier,
                source: .homebrew,
                version: caskVersion,
                comparableVersion: caskVersion,
                releaseDate: nil,
                releaseNotes: nil,
                releaseNotesURL: cask.homepage,
                downloadURL: cask.downloadURL,
                action: Self.action(for: cask, brewInstalled: brewInstalled)
            ))
        }
        return result
    }

    /// Evidence that a cask is this particular app and not another one with the same name: a bundle ID the cask
    /// declares (quit/signal) or leaves behind (zap/uninstall paths) must be the app's, or, when the cask names none,
    /// the vendor in the app's bundle ID must appear in the cask's web address.
    static func identifies(_ cask: Cask, _ app: InstalledApp) -> Bool {
        let id = app.bundleIdentifier.lowercased()
        let known = Set(cask.bundleIdentifiers.union(cask.footprintIDs).map { $0.lowercased() })
        if !known.isEmpty { return known.contains(id) }
        let labels = id.split(separator: ".")
        guard labels.count >= 2 else { return false }
        let vendor = labels[1]
        let hosts = [cask.homepage, cask.downloadURL].compactMap { $0?.host()?.lowercased() }
        return hosts.contains { $0.split(separator: ".").contains(vendor) }
    }

    /// Homebrew installs upgrade through brew. Otherwise, apps that update themselves
    /// (Chrome, Edge, …) are opened so their own updater runs; the rest get the cask's
    /// direct download rather than a marketing homepage.
    static func action(for cask: Cask, brewInstalled: Bool) -> UpdateAction {
        if brewInstalled { return .brewUpgrade(token: cask.token) }
        if cask.autoUpdates { return .launchApp }
        if let download = cask.downloadURL { return .openURL(download) }
        return cask.homepage.map(UpdateAction.openURL) ?? .launchApp
    }

    /// Guards the fallback path against casks that number releases differently from
    /// the app (e.g. "2026.1" against "26.1"), which would otherwise look like updates.
    static func plausiblySameScheme(_ candidate: String, _ installed: String) -> Bool {
        func major(_ version: String) -> Int? {
            Int(version.prefix { $0.isNumber })
        }
        guard let lhs = major(candidate), let rhs = major(installed) else { return false }
        return abs(lhs - rhs) <= 5
    }
}

struct Cask: Sendable, Equatable {
    let token: String
    let version: String
    let appNames: [String]
    let bundleIdentifiers: Set<String>
    /// Bundle IDs named by the cask's zap/uninstall paths (preferences, caches, saved state).
    let footprintIDs: Set<String>
    let homepage: URL?
    let downloadURL: URL?
    let isDisabled: Bool
    /// The cask declares that the app updates itself.
    let autoUpdates: Bool

    init(token: String, version: String, appNames: [String], bundleIdentifiers: Set<String> = [], footprintIDs: Set<String> = [],
         homepage: URL? = nil, downloadURL: URL? = nil, isDisabled: Bool = false, autoUpdates: Bool = false) {
        self.token = token
        self.version = version
        self.appNames = appNames
        self.bundleIdentifiers = bundleIdentifiers
        self.footprintIDs = footprintIDs
        self.homepage = homepage
        self.downloadURL = downloadURL
        self.isDisabled = isDisabled
        self.autoUpdates = autoUpdates
    }

}

/// Fields read from one cask object. `keys` records which names a variation
/// actually set, so an absent key does not wipe the base value.
private struct CaskFields {
    var token: String?
    var version: String?
    var homepage: String?
    var downloadURL: String?
    var disabled = false
    var deprecated = false
    var autoUpdates = false
    var appNames: [String] = []
    var bundleIDs: Set<String> = []
    var footprintIDs: Set<String> = []
    var keys: Set<String> = []

    mutating func apply(_ overlay: CaskFields) {
        if overlay.keys.contains("token") { token = overlay.token }
        if overlay.keys.contains("version") { version = overlay.version }
        if overlay.keys.contains("homepage") { homepage = overlay.homepage }
        if overlay.keys.contains("url") { downloadURL = overlay.downloadURL }
        if overlay.keys.contains("disabled") { disabled = overlay.disabled }
        if overlay.keys.contains("deprecated") { deprecated = overlay.deprecated }
        if overlay.keys.contains("auto_updates") { autoUpdates = overlay.autoUpdates }
        if overlay.keys.contains("artifacts") {
            appNames = overlay.appNames
            bundleIDs = overlay.bundleIDs
            footprintIDs = overlay.footprintIDs
        }
    }

    func cask() -> Cask? {
        guard let token, let version, !appNames.isEmpty else { return nil }
        return Cask(
            token: token,
            version: version,
            appNames: appNames,
            bundleIdentifiers: bundleIDs,
            footprintIDs: footprintIDs,
            homepage: homepage.flatMap(URL.init(string:)),
            downloadURL: downloadURL.flatMap(URL.init(string:)),
            isDisabled: disabled || deprecated,
            autoUpdates: autoUpdates
        )
    }
}

/// Homebrew selects an exact platform variation with a shallow merge. Scanning
/// only the prefix used by the runner avoids confusing Intel and ARM installs.
enum HomebrewPlatform {
    static var tag: String {
        #if arch(arm64)
        let prefix = "arm64_"
        #else
        let prefix = ""
        #endif
        let names = [11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma",
                     15: "sequoia", 26: "tahoe", 27: "golden_gate"]
        return prefix + (names[ProcessInfo.processInfo.operatingSystemVersion.majorVersion] ?? "unknown")
    }

    static func folders(_ path: String) -> [URL] {
        guard let executable = BrewRunner.brewPath else { return [] }
        return [URL(filePath: executable).deletingLastPathComponent().deletingLastPathComponent().appending(path: path)]
    }

}
