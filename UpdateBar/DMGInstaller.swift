import AppKit
import Foundation

/// Installs an app from a signed DMG: download, mount, verify, swap into place, relaunch.
/// Only apps signed by our own Team ID are accepted; the previous copy is kept until the
/// new one is in place and restored if anything fails.
enum DMGInstaller {
    static let teamID = "T26T3G8C7Q"

    enum Outcome: Sendable {
        case installed
        case failure(String)
    }

    struct Failure: Error { let message: String }

    @MainActor
    static func install(
        _ app: InstalledApp, from url: URL, progress: @escaping @MainActor (String) -> Void
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

            progress("Downloading \(name)…")
            let work = fm.temporaryDirectory.appending(path: "UpdateBar-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let dmg = work.appending(path: "image.dmg")
            try fm.moveItem(at: temp, to: dmg)

            progress("Mounting…")
            let mountPoint = work.appending(path: "mount")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountPoint.path])

            let apps = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
            guard let source = apps.first(where: { $0.lastPathComponent == destination.lastPathComponent }) ?? apps.first else {
                _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
                throw Failure(message: "The disk image doesn't contain an app.")
            }

            progress("Verifying signature…")
            // Stage beside the destination (same volume, so the swap is a rename) and verify that exact copy.
            let stage = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).update-\(UUID().uuidString.prefix(8))")
            staged = stage
            var copyError: Error?
            do { try await run("/usr/bin/ditto", [source.path, stage.path]) } catch { copyError = error }
            _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            if let copyError { throw copyError }
            try await verify(stage, bundleIdentifier: app.bundleIdentifier)
            _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stage.path])

            // Re-check now: the app may have been opened or closed during the download.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
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

    private static func verify(_ bundle: URL, bundleIdentifier: String) async throws {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", bundle.path])
        } catch {
            throw Failure(message: "The downloaded app's signature is invalid.")
        }
        let details = (try? await run("/usr/bin/codesign", ["-dv", bundle.path])) ?? ""
        guard details.split(separator: "\n").contains("TeamIdentifier=\(teamID)") else {
            throw Failure(message: "The downloaded app isn't signed by the expected developer.")
        }
        guard Bundle(url: bundle)?.bundleIdentifier == bundleIdentifier else {
            throw Failure(message: "The downloaded app isn't the one being updated.")
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
