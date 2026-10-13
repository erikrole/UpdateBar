import Foundation

/// Finds application bundles in the usual install locations and reads the
/// metadata each update source needs. Nothing here launches or loads app code.
struct AppScanner: Sendable {
    var roots: [URL] = AppScanner.defaultRoots
    /// How many folder levels below a root to look, so "Adobe Photoshop 2026/Photoshop.app" is found.
    var maxDepth = 2

    static var defaultRoots: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        for root in roots {
            for url in appBundles(in: root, depth: 0) {
                guard let app = Self.readApp(at: url), !Self.isSystemApp(app) else { continue }
                // Keep the first copy of each bundle ID; /Applications is scanned first.
                if found[app.bundleIdentifier] == nil {
                    found[app.bundleIdentifier] = app
                }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func appBundles(in folder: URL, depth: Int) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for child in children {
            if child.pathExtension == "app" {
                result.append(child)
            } else if depth < maxDepth,
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result += appBundles(in: child, depth: depth + 1)
            }
        }
        return result
    }

    static func readApp(at url: URL) -> InstalledApp? {
        // One pool per app. Scanning /Applications on a reused thread would
        // otherwise keep every plist object graph until the thread exits.
        autoreleasepool {
            let plistURL = url.appending(path: "Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return makeApp(url: url, plist: plist, hasReceipt: FileManager.default.fileExists(
                atPath: url.appending(path: "Contents/_MASReceipt/receipt").path
            ))
        }
    }

    /// Builds an app from parsed Info.plist values; split out so tests can feed plists directly.
    static func makeApp(url: URL, plist: [String: Any], hasReceipt: Bool) -> InstalledApp? {
        guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else {
            return nil
        }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let feed = (plist["SUFeedURL"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { URL(string: $0) }
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }

        return InstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: name,
            url: url,
            shortVersion: stringValue(plist["CFBundleShortVersionString"]),
            buildVersion: stringValue(plist["CFBundleVersion"]),
            sparkleFeedURL: feed,
            hasAppStoreReceipt: hasReceipt,
            hasSparkleEDKey: (plist["SUPublicEDKey"] as? String)?.isEmpty == false
        )
    }

    /// Apple's own apps update with macOS, so they never belong in the list.
    static func isSystemApp(_ app: InstalledApp) -> Bool {
        app.bundleIdentifier.hasPrefix("com.apple.") && !app.hasAppStoreReceipt
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
