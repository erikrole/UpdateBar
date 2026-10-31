import AppKit
import Foundation

/// Keeps the copy an in-place update replaced, so it can be put back. One copy per app, kept for two weeks,
/// in a `.noindex` folder so Spotlight doesn't offer it as a second copy of the app.
struct PreviousVersions: Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let bundleIdentifier: String
        let name: String
        let version: String
        /// Where the app lives; a restore puts the old copy back here.
        let installedPath: String
        let savedAt: Date

        var id: String { bundleIdentifier }
    }

    static let standard = PreviousVersions(
        root: URL.applicationSupportDirectory.appending(path: "UpdateBar/Previous.noindex", directoryHint: .isDirectory))
    static let keepDays = 14

    let root: URL

    private func folder(for bundleIdentifier: String) -> URL {
        // Bundle IDs are reverse-DNS; anything else is rejected rather than turned into a path.
        root.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && id.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) }
    }

    /// Moves `backup` (the replaced app) into the store. On any failure the backup is deleted, as before.
    @discardableResult
    func keep(_ backup: URL, for app: InstalledApp, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        guard Self.validID(app.bundleIdentifier) else { try? fm.removeItem(at: backup); return false }
        let target = folder(for: app.bundleIdentifier)
        do {
            try? fm.removeItem(at: target)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.moveItem(at: backup, to: target.appending(path: app.url.lastPathComponent))
            let entry = Entry(bundleIdentifier: app.bundleIdentifier, name: app.name, version: app.displayVersion,
                              installedPath: app.url.path, savedAt: now)
            try JSONEncoder().encode(entry).write(to: target.appending(path: "entry.json"), options: .atomic)
            return true
        } catch {
            try? fm.removeItem(at: backup)
            try? fm.removeItem(at: target)
            return false
        }
    }

    /// Saved copies, newest first. Copies older than two weeks, or missing their app, are removed.
    func entries(now: Date = Date()) -> [Entry] {
        let fm = FileManager.default
        var result: [Entry] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where Self.validID(name) {
            let folder = folder(for: name)
            guard let data = try? Data(contentsOf: folder.appending(path: "entry.json")),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.bundleIdentifier == name,
                  now.timeIntervalSince(entry.savedAt) < TimeInterval(Self.keepDays) * 86_400,
                  fm.fileExists(atPath: savedApp(entry).path)
            else {
                try? fm.removeItem(at: folder)
                continue
            }
            result.append(entry)
        }
        return result.sorted { $0.savedAt > $1.savedAt }
    }

    func savedApp(_ entry: Entry) -> URL {
        folder(for: entry.bundleIdentifier).appending(path: URL(filePath: entry.installedPath).lastPathComponent)
    }

    struct Failure: Error, Equatable { let message: String }

    /// Swaps the saved copy back into place. The copy it replaces is kept in its stead, so a restore can be undone.
    func restore(_ entry: Entry, now: Date = Date(), isRunning: (String) -> Bool = PreviousVersions.isRunning) throws {
        let fm = FileManager.default
        let installed = URL(filePath: entry.installedPath)
        let saved = savedApp(entry)
        guard fm.fileExists(atPath: saved.path) else { throw Failure(message: "The saved copy of \(entry.name) is gone.") }
        guard !isRunning(entry.bundleIdentifier) else { throw Failure(message: "Quit \(entry.name), then restore it.") }
        let swap = installed.deletingLastPathComponent().appending(path: ".\(installed.lastPathComponent).updatebar-restore")
        try? fm.removeItem(at: swap)
        let hadInstalled = fm.fileExists(atPath: installed.path)
        do {
            if hadInstalled { try fm.moveItem(at: installed, to: swap) }
            try fm.moveItem(at: saved, to: installed)
        } catch {
            if hadInstalled, !fm.fileExists(atPath: installed.path) { try? fm.moveItem(at: swap, to: installed) }
            throw Failure(message: "Couldn't restore \(entry.name): \(error.localizedDescription)")
        }
        guard hadInstalled else {
            try? fm.removeItem(at: folder(for: entry.bundleIdentifier))
            return
        }
        let replacedVersion = Bundle(url: swap)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let replaced = InstalledApp(bundleIdentifier: entry.bundleIdentifier, name: entry.name, url: installed,
                                    shortVersion: replacedVersion, buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        keep(swap, for: replaced, now: now)
    }

    static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
