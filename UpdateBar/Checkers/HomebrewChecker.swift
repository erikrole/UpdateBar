import Foundation

/// Compares apps against Homebrew's public cask index.
///
/// For casks installed with Homebrew it is authoritative and offers `brew upgrade`.
/// For other apps it is a fallback that only speaks when no real updater answered,
/// and it links to the app's homepage instead of installing anything.
struct HomebrewChecker: UpdateChecker {
    let source = UpdateSource.homebrew
    var client = HTTPClient.shared
    var caskrooms: [URL] = [
        URL(filePath: "/opt/homebrew/Caskroom", directoryHint: .isDirectory),
        URL(filePath: "/usr/local/Caskroom", directoryHint: .isDirectory),
    ]
    var cacheURL: URL = HomebrewChecker.defaultCacheURL
    /// The cask index is ~20 MB, so it is refreshed at most this often.
    var maxCacheAge: TimeInterval = 6 * 60 * 60

    static var defaultCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "UpdateBar/cask.json")
    }

    func check(_ apps: [InstalledApp]) async -> CheckerResult {
        do {
            let casks = try await loadCasks()
            let installed = Self.installedCasks(in: caskrooms)
            return Self.evaluate(apps, casks: casks, installed: installed)
        } catch {
            return CheckerResult(failures: [
                CheckFailure(source: .homebrew, subject: "Homebrew", message: error.localizedDescription),
            ])
        }
    }

    // MARK: - Cask index

    private func loadCasks() async throws -> [Cask] {
        let fileManager = FileManager.default
        let modified = (try? fileManager.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        if let modified, Date().timeIntervalSince(modified) < maxCacheAge,
           let data = try? Data(contentsOf: cacheURL), let casks = try? Self.decode(data) {
            return casks
        }

        do {
            let (data, response) = try await client.data(from: URL(string: "https://formulae.brew.sh/api/cask.json")!)
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPClient.HTTPError.status(response.statusCode)
            }
            let casks = try Self.decode(data)
            try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return casks
        } catch {
            // Offline: a stale index is better than none.
            if let data = try? Data(contentsOf: cacheURL), let casks = try? Self.decode(data) { return casks }
            throw error
        }
    }

    static func decode(_ data: Data) throws -> [Cask] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap(Cask.init(json:))
    }

    /// Cask tokens and the version Homebrew last installed, read from the Caskroom.
    static func installedCasks(in caskrooms: [URL]) -> [String: String] {
        var installed: [String: String] = [:]
        let fileManager = FileManager.default
        for room in caskrooms {
            guard let tokens = try? fileManager.contentsOfDirectory(atPath: room.path) else { continue }
            for token in tokens where !token.hasPrefix(".") {
                let versions = (try? fileManager.contentsOfDirectory(atPath: room.appending(path: token).path))?
                    .filter { !$0.hasPrefix(".") } ?? []
                let newest = versions.max { VersionComparator.isNewer($1, than: $0) }
                installed[token] = newest ?? ""
            }
        }
        return installed
    }

    // MARK: - Matching

    static func evaluate(_ apps: [InstalledApp], casks: [Cask], installed: [String: String]) -> CheckerResult {
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
            if let owned = matches.first(where: { installed[$0.token] != nil }) {
                cask = owned
                brewInstalled = true
            } else {
                let agreeing = matches.filter { $0.bundleIdentifiers.isEmpty || $0.bundleIdentifiers.contains(app.bundleIdentifier) }
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
