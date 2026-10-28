import AppKit
import Foundation

/// Updates an app that ships as an installer package: download it, verify the package's signature against the
/// installed app's own Team ID, then open it in Apple's Installer. Installer asks for the password itself and
/// does the install, so UpdateBar never handles elevated rights.
enum PKGInstaller {
    enum Outcome: Sendable {
        case opened
        case failure(String)
    }

    struct Failure: Error { let message: String }

    static let openedNotice = "Opened in Installer. Finish there, then Refresh will pick up the new version."

    /// Where verified packages wait for Installer to read them. Swept at launch.
    static var stagingDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: "UpdateBar").appending(path: "pkg")
    }

    /// Keep recent packages across relaunches, and never sweep while Installer is open.
    @MainActor
    static func sweepStaging() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.installer").isEmpty else { return }
        sweepStaging(in: stagingDirectory, now: Date())
    }

    static func sweepStaging(in directory: URL, now: Date) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        for file in files where file.pathExtension == "pkg" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > 7 * 24 * 60 * 60 else { continue }
            try? fm.removeItem(at: file)
        }
    }

    /// The Team ID in the "Developer ID Installer: Name (TEAMID)" line of `pkgutil --check-signature`, when the
    /// package is signed by a certificate issued by Apple.
    static func signerTeamID(in output: String) -> String? {
        guard output.contains("signed by a developer certificate issued by Apple") || output.contains("Status: signed Apple Software") else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.contains("Developer ID Installer:"),
                  let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { continue }
            let team = String(text[text.index(after: open)..<close])
            if team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }) { return team }
        }
        return nil
    }

    @MainActor
    static func install(_ app: InstalledApp, from url: URL, progress: @escaping @MainActor (String) -> Void) async -> Outcome {
        let name = app.name
        let fm = FileManager.default
        var staged: URL?
        do {
            guard let teamID = DMGInstaller.installedTeamID(of: app.url) else {
                throw Failure(message: "\(name) isn't signed by a developer team, so Refresh can't verify an update for it.")
            }
            guard url.scheme == "https" else { throw Failure(message: "The download isn't served over https.") }

            progress("Downloading \(name)…")
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https" else {
                throw Failure(message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let pkg = stagingDirectory.appending(path: "\(UUID().uuidString).pkg")
            try fm.moveItem(at: temp, to: pkg)
            staged = pkg

            progress("Verifying signature…")
            let check = try await run("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
            guard check.status == 0 else { throw Failure(message: "The downloaded package isn't signed, so it wasn't opened.") }
            guard signerTeamID(in: check.output) == teamID else {
                throw Failure(message: "The downloaded package isn't signed by \(name)'s developer, so it wasn't opened.")
            }
            let assess = try await run("/usr/sbin/spctl", ["--assess", "--type", "install", pkg.path])
            guard assess.status == 0 else { throw Failure(message: "macOS Gatekeeper rejected the downloaded package.") }

            progress("Opening Installer…")
            let installer = URL(filePath: "/System/Library/CoreServices/Installer.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([pkg], withApplicationAt: installer, configuration: configuration)
            return .opened
        } catch let failure as Failure {
            if let staged { try? fm.removeItem(at: staged) }
            return .failure(failure.message)
        } catch {
            if let staged { try? fm.removeItem(at: staged) }
            return .failure(error.localizedDescription)
        }
    }

    struct ToolResult: Sendable {
        let status: Int32
        let output: String
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> ToolResult {
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
            return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
