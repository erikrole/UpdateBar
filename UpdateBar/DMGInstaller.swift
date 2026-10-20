import AppKit
import Foundation

/// Installs an app from a signed DMG or zip: download, open, verify, swap into place, relaunch.
/// The new app must be signed by the expected Team ID (our own for own-app releases, otherwise the
/// installed app's own Team ID) and carry the same bundle ID; the previous copy is kept until the
/// new one is in place and restored if anything fails.
enum DMGInstaller {
    /// Team ID of our own apps (Fetch, Offload).
    static let ownTeamID = "T26T3G8C7Q"

    enum Outcome: Sendable {
        case installed
        case failure(String)
    }

    struct Failure: Error { let message: String }

    @MainActor
    static func install(
        _ app: InstalledApp, from url: URL, expectedTeamID: String? = nil, progress: @escaping @MainActor (String) -> Void
    ) async -> Outcome {
        let name = app.name
        let destination = app.url
        let fm = FileManager.default
        var staged: URL?
        do {
            guard !destination.path.contains("/AppTranslocation/"),
                  (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly != true,
                  fm.isWritableFile(atPath: destination.deletingLastPathComponent().path)
            else { throw Failure(message: "\(name) is somewhere UpdateBar can't change. Move it to Applications first.") }

            // Own releases pass our Team ID; anything else must be signed by whoever signed the app now installed.
            guard let teamID = expectedTeamID ?? installedTeamID(of: destination) else {
                throw Failure(message: "\(name) isn't signed by a developer team, so UpdateBar can't verify an update for it.")
            }
            guard url.scheme == "https" else { throw Failure(message: "The download isn't served over https.") }

            progress("Downloading \(name)…")
            let work = fm.temporaryDirectory.appending(path: "UpdateBar-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            if response.url?.scheme != "https" { throw Failure(message: "The download was redirected away from https.") }
            let archive = work.appending(path: "download")
            try fm.moveItem(at: temp, to: archive)

            // A zip starts with "PK"; anything else is treated as a disk image.
            let isZip = (try? FileHandle(forReadingFrom: archive).read(upToCount: 2)).map { $0 == Data("PK".utf8) } ?? false
            let mountPoint = work.appending(path: "mount")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            if isZip {
                progress("Unpacking…")
                try await run("/usr/bin/ditto", ["-x", "-k", archive.path, mountPoint.path])
            } else {
                progress("Mounting…")
                try await run("/usr/bin/hdiutil", ["attach", archive.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountPoint.path])
            }
            func release() async { if !isZip { _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) } }

            guard let source = findApp(in: mountPoint, named: destination.lastPathComponent) else {
                await release()
                throw Failure(message: "The download doesn't contain an app.")
            }

            progress("Verifying signature…")
            // Stage beside the destination (same volume, so the swap is a rename) and verify that exact copy.
            let stage = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).update-\(UUID().uuidString.prefix(8))")
            staged = stage
            var copyError: Error?
            do { try await run("/usr/bin/ditto", [source.path, stage.path]) } catch { copyError = error }
            await release()
            if let copyError { throw copyError }
            try await verify(stage, bundleIdentifier: app.bundleIdentifier, teamID: teamID, installedVersion: app.shortVersion)
            _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stage.path])

            // Re-check now: the app may have been opened or closed during the download.
            // Only the copy being replaced counts; another copy of the same app elsewhere is left alone.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
                .filter { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
            let wasRunning = !running.isEmpty
            if wasRunning {
                progress("Waiting for \(name) to quit…")
                try await quit(running)
            }

            progress("Installing…")
            let backup = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).updatebar-backup")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: destination, to: backup)
            do {
                try fm.moveItem(at: stage, to: destination)
                staged = nil
            } catch {
                try? fm.removeItem(at: destination)
                try? fm.moveItem(at: backup, to: destination)
                throw Failure(message: "Couldn't install \(name): \(error.localizedDescription). The previous version was restored.")
            }

            if wasRunning {
                progress("Relaunching…")
                let configuration = NSWorkspace.OpenConfiguration()
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                } catch {
                    try? fm.removeItem(at: destination)
                    try? fm.moveItem(at: backup, to: destination)
                    throw Failure(message: "\(name) updated but wouldn't open, so the previous version was restored.")
                }
            }
            try? fm.removeItem(at: backup)
            return .installed
        } catch let failure as Failure {
            if let staged { try? fm.removeItem(at: staged) }
            return .failure(failure.message)
        } catch {
            if let staged { try? fm.removeItem(at: staged) }
            return .failure(error.localizedDescription)
        }
    }

    /// The app at the top level of the folder, or one folder down (zips often wrap it), preferring the installed name.
    static func findApp(in directory: URL, named name: String) -> URL? {
        let fm = FileManager.default
        func apps(in folder: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        }
        var found = apps(in: directory)
        if found.isEmpty {
            for sub in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                found += apps(in: sub)
            }
        }
        return found.first { $0.lastPathComponent == name } ?? found.first
    }

    /// The Team ID the installed app is signed with, if any.
    static func installedTeamID(of app: URL) -> String? {
        guard let output = try? runSyncOutput("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]) else { return nil }
        return teamID(in: output)
    }

    static func teamID(in output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }.flatMap { $0 == "not set" ? nil : $0 }
    }

    private static func runSyncOutput(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func verify(_ bundle: URL, bundleIdentifier: String, teamID: String, installedVersion: String?) async throws {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", bundle.path])
        } catch {
            throw Failure(message: "The downloaded app's signature is invalid.")
        }
        let details = (try? await run("/usr/bin/codesign", ["-dv", bundle.path])) ?? ""
        guard Self.teamID(in: details) == teamID else {
            throw Failure(message: "The downloaded app isn't signed by the expected developer.")
        }
        guard Bundle(url: bundle)?.bundleIdentifier == bundleIdentifier else {
            throw Failure(message: "The downloaded app isn't the one being updated.")
        }
        // A stale download link must never roll the app back.
        if let installedVersion, let downloaded = Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String,
           VersionComparator.isNewer(installedVersion, than: downloaded) {
            throw Failure(message: "The download (\(downloaded)) is older than the installed version (\(installedVersion)), so it wasn't installed.")
        }
        do {
            try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", bundle.path])
        } catch {
            throw Failure(message: "macOS Gatekeeper rejected the downloaded app.")
        }
    }

    /// Asks the app to quit, waits briefly, and never force-quits (unsaved work stays safe).
    @MainActor
    private static func quit(_ running: [NSRunningApplication]) async throws {
        for app in running { app.terminate() }
        for _ in 0..<240 {  // up to a minute: a save sheet shouldn't cost the user a re-download
            if running.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(message: "\(running.first?.localizedName ?? "The app") didn't quit. Quit it and try again.")
    }

    /// Runs a tool off the main thread; returns combined output, throws its output on a non-zero exit.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw Failure(message: output) }
            return output
        }.value
    }
}
