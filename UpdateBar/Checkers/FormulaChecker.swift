import Foundation

/// An outdated Homebrew formula (a command-line tool or library).
struct ToolUpdate: Identifiable, Hashable, Sendable {
    let name: String
    let installedVersion: String
    let latestVersion: String
    /// You asked for it (`brew install x`), as opposed to it arriving as a dependency.
    let requested: Bool
    let summary: String?
    let homepage: URL?

    var id: String { name }
    var notificationID: String { "formula|\(name)|\(latestVersion)" }

    /// Only Homebrew's rebuild number changed ("9.0.2" → "9.0.2_1"): same upstream
    /// release, rebuilt against newer libraries.
    var isRebuild: Bool {
        Self.upstream(installedVersion) == Self.upstream(latestVersion)
    }

    private static func upstream(_ version: String) -> String {
        version.split(separator: "_", maxSplits: 1).first.map(String.init) ?? version
    }
}

/// Compares the formulae in your Cellar against Homebrew's live formula index.
/// Pinned formulae and HEAD builds are left alone, as `brew upgrade` would.
struct FormulaChecker: Sendable {
    var index = IndexCache.homebrew("formula")
    var cellars: [URL] = HomebrewPlatform.folders("Cellar")
    var pinnedFolders: [URL] = HomebrewPlatform.folders("var/homebrew/pinned")
    private static let decodedIndex = DecodedIndex<[Formula]>()

    struct Installed: Equatable, Sendable {
        let versions: [String]
        let requested: Bool
    }

    struct Formula: Equatable, Sendable {
        let name: String
        let oldNames: [String]
        /// The version `brew` installs today, with the rebuild suffix: "9.0.2_1".
        let packageVersion: String
        let summary: String?
        let homepage: URL?
        let isDisabled: Bool
    }

    func check() async -> (tools: [ToolUpdate], failures: [CheckFailure]) {
        let installed = Self.installedFormulae(in: cellars)
        guard !installed.isEmpty else { return ([], []) }
        do {
            let outcome = try await evaluated(installed: installed)
            await Self.decodedIndex.removeAll()
            TransientMemory.release()
            return outcome
        } catch {
            await Self.decodedIndex.removeAll()
            TransientMemory.release()
            return ([], [CheckFailure(source: .homebrew, subject: "Command-line tools", message: error.localizedDescription)])
        }
    }

    private func evaluated(installed: [String: Installed]) async throws -> (tools: [ToolUpdate], failures: [CheckFailure]) {
        let snapshot = try await Self.decodedIndex.load(from: index) { try Self.decode($0) }
        let pinned = Self.pinnedFormulae(in: pinnedFolders)
        let failures = snapshot.warning.map { [CheckFailure(source: .homebrew, subject: "Command-line tools", message: $0)] } ?? []
        return (Self.evaluate(installed: installed, formulae: snapshot.value, pinned: pinned), failures)
    }

    static func decode(_ data: Data, platform: String = HomebrewPlatform.tag) throws -> [Formula] {
        try autoreleasepool {
            let array = try HomebrewPlatform.records(data, tag: platform)
            return array.compactMap { json in
                guard let name = json["name"] as? String,
                      let versions = json["versions"] as? [String: Any],
                      let stable = versions["stable"] as? String
                else { return nil }
                let revision = json["revision"] as? Int ?? 0
                return Formula(
                    name: detachedCopy(name),
                    oldNames: (json["oldnames"] as? [String] ?? []).map(detachedCopy),
                    packageVersion: detachedCopy(revision > 0 ? "\(stable)_\(revision)" : stable),
                    summary: (json["desc"] as? String).map(detachedCopy),
                    homepage: (json["homepage"] as? String).map(detachedCopy).flatMap(URL.init(string:)),
                    isDisabled: (json["disabled"] as? Bool) == true
                )
            }
        }
    }

    static func installedFormulae(in cellars: [URL]) -> [String: Installed] {
        var result: [String: Installed] = [:]
        let fileManager = FileManager.default
        for cellar in cellars {
            guard let names = try? fileManager.contentsOfDirectory(atPath: cellar.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let folder = cellar.appending(path: name)
                let versions = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                guard !versions.isEmpty else { continue }
                let requested = versions.contains { version in
                    autoreleasepool {
                        let receipt = folder.appending(path: "\(version)/INSTALL_RECEIPT.json")
                        guard let data = try? Data(contentsOf: receipt),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { return false }
                        return (json["installed_on_request"] as? Bool) == true
                    }
                }
                result[name] = Installed(versions: versions, requested: requested)
            }
        }
        return result
    }

    static func pinnedFormulae(in folders: [URL]) -> Set<String> {
        Set(folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] })
    }

    static func evaluate(installed: [String: Installed], formulae: [Formula], pinned: Set<String>) -> [ToolUpdate] {
        var byName: [String: Formula] = [:]
        for formula in formulae {
            byName[formula.name] = formula
            for old in formula.oldNames where byName[old] == nil { byName[old] = formula }
        }

        var updates: [ToolUpdate] = []
        for (name, local) in installed where !pinned.contains(name) {
            guard let formula = byName[name], !formula.isDisabled else { continue }
            let releases = local.versions.filter { !$0.hasPrefix("HEAD") }
            guard !releases.isEmpty, !releases.contains(formula.packageVersion) else { continue }
            let newest = releases.max { VersionComparator.isNewer($1, than: $0) } ?? releases[0]
            guard VersionComparator.isNewer(formula.packageVersion, than: newest) else { continue }
            updates.append(ToolUpdate(
                name: name,
                installedVersion: newest,
                latestVersion: formula.packageVersion,
                requested: local.requested,
                summary: formula.summary,
                homepage: formula.homepage
            ))
        }
        return updates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
