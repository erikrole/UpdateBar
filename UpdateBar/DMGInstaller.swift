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
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
        let wasRunning = !running.isEmpty
        let name = app.name
        do {
            progress("Downloading \(name)…")
            let work = FileManager.default.temporaryDirectory.appending(path: "UpdateBar-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else {
                throw Failure(message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let dmg = work.appending(path: "image.dmg")
            try FileManager.default.moveItem(at: temp, to: dmg)

            progress("Mounting…")
            let mountPoint = work.appending(path: "mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountPoint.path])
            defer { _ = detach(mountPoint) }

            guard let source = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent == app.url.deletingPathExtension().lastPathComponent })
                ?? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw Failure(message: "The disk image doesn't contain an app.") }

            progress("Verifying signature…")
            // Copy off the image first so what we verify is what we install.
            let staged = work.appending(path: source.lastPathComponent)
            try await run("/usr/bin/ditto", [source.path, staged.path])
            try await verify(staged, bundleIdentifier: app.bundleIdentifier)

            if wasRunning {
                progress("Quitting \(name)…")
                try await quit(running)
            }

            progress("Installing…")
            let destination = app.url
            let backup = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).updatebar-backup")
            let fm = FileManager.default
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: destination, to: backup)
            do {
                try fm.moveItem(at: staged, to: destination)
            } catch {
                try? fm.removeItem(at: destination)
                try? fm.moveItem(at: backup, to: destination)
                throw Failure(message: "Couldn't install \(name): \(error.localizedDescription). The previous version was restored.")
            }
            try? fm.removeItem(at: backup)
            _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])

            if wasRunning {
                progress("Relaunching…")
                let configuration = NSWorkspace.OpenConfiguration()
                _ = try? await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            }
            return .installed
        } catch let failure as Failure {
            return .failure(failure.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func verify(_ bundle: URL, bundleIdentifier: String) async throws {
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
        } catch {
            throw Failure(message: "The downloaded app's signature is invalid.")
        }
        let details = (try? await run("/usr/bin/codesign", ["-dv", bundle.path])) ?? ""
        guard details.contains("TeamIdentifier=\(teamID)") else {
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
        for _ in 0..<40 {
            if running.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure(message: "\(running.first?.localizedName ?? "The app") didn't quit. Quit it and try again.")
    }

    private static func detach(_ mountPoint: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
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
