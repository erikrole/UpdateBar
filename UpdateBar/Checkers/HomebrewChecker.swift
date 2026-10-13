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
            let snapshot = try await Self.decodedIndex.load(from: index) { try Self.decode($0) }
            let installed = Self.installedCasks(in: caskrooms)
            var result = Self.evaluate(apps, casks: snapshot.value, installed: installed)
            if let warning = snapshot.warning {
                result.failures.append(CheckFailure(source: .homebrew, subject: "Homebrew", message: warning))
            }
            return result
        } catch {
            return CheckerResult(failures: [
                CheckFailure(source: .homebrew, subject: "Homebrew", message: error.localizedDescription),
            ])
        }
    }

    // MARK: - Cask index

    static func decode(_ data: Data, platform: String = HomebrewPlatform.tag) throws -> [Cask] {
        let array = try HomebrewPlatform.records(data, tag: platform)
        return array.compactMap(Cask.init(json:))
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
                guard agreeing.count == 1, let only = agreeing.first else { continue }
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
    let homepage: URL?
    let downloadURL: URL?
    let isDisabled: Bool
    /// The cask declares that the app updates itself.
    let autoUpdates: Bool

    init(token: String, version: String, appNames: [String], bundleIdentifiers: Set<String> = [],
         homepage: URL? = nil, downloadURL: URL? = nil, isDisabled: Bool = false, autoUpdates: Bool = false) {
        self.token = token
        self.version = version
        self.appNames = appNames
        self.bundleIdentifiers = bundleIdentifiers
        self.homepage = homepage
        self.downloadURL = downloadURL
        self.isDisabled = isDisabled
        self.autoUpdates = autoUpdates
    }

    init?(json: [String: Any]) {
        guard let token = json["token"] as? String, let version = json["version"] as? String else { return nil }
        var appNames: [String] = []
        var bundleIdentifiers: Set<String> = []
        for artifact in json["artifacts"] as? [[String: Any]] ?? [] {
            if let apps = artifact["app"] as? [Any] {
                for case let name as String in apps where name.hasSuffix(".app") {
                    appNames.append((name as NSString).lastPathComponent)
                }
            }
            // `uninstall quit:` and `zap` often name the app's bundle ID, which lets a
            // name-only match be confirmed.
            for key in ["uninstall", "zap"] {
                for case let directive as [String: Any] in artifact[key] as? [Any] ?? [] {
                    for value in [directive["quit"], directive["signal"]] {
                        if let id = value as? String { bundleIdentifiers.insert(id) }
                        if let ids = value as? [String] { bundleIdentifiers.formUnion(ids) }
                    }
                }
            }
        }
        guard !appNames.isEmpty else { return nil }
        self.init(
            token: token,
            version: version,
            appNames: appNames,
            bundleIdentifiers: bundleIdentifiers,
            homepage: (json["homepage"] as? String).flatMap(URL.init(string:)),
            downloadURL: (json["url"] as? String).flatMap(URL.init(string:)),
            isDisabled: (json["disabled"] as? Bool) == true || (json["deprecated"] as? Bool) == true,
            autoUpdates: (json["auto_updates"] as? Bool) == true
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

    static func records(_ data: Data, tag: String) throws -> [[String: Any]] {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a Homebrew index array."))
        }
        return records.map { record in
            guard let variations = record["variations"] as? [String: [String: Any]], let variant = variations[tag] else { return record }
            return record.merging(variant) { _, platformValue in platformValue }
        }
    }
}
