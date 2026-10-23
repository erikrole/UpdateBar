import Foundation
import AppKit

/// Runs Homebrew as the current user, never with elevated rights.
enum BrewRunner {
    enum Outcome: Sendable {
        case success
        case failure(String)
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fetch(cask token: String) async -> Outcome {
        await run(["fetch", "--cask", token], retryHint: "brew fetch --cask \(token)", onEvent: nil)
    }

    static func upgrade(cask token: String, onEvent: (@Sendable (BrewOutputParser.Event) -> Void)? = nil) async -> Outcome {
        await run(["upgrade", "--cask", token], retryHint: "brew upgrade --cask \(token)", onEvent: onEvent)
    }

    static func upgrade(formulae names: [String], onEvent: (@Sendable (BrewOutputParser.Event) -> Void)? = nil) async -> Outcome {
        await run(["upgrade", "--formula"] + names, retryHint: "brew upgrade --formula \(names.joined(separator: " "))", onEvent: onEvent)
    }

    private static func run(
        _ arguments: [String],
        retryHint: String,
        onEvent: (@Sendable (BrewOutputParser.Event) -> Void)?
    ) async -> Outcome {
        guard let brewPath else { return .failure("Homebrew isn't installed in the usual place.") }
        // Output is read line by line while brew runs: it drives the progress display,
        // and waiting for exit first would deadlock once a verbose upgrade fills the pipe.
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(filePath: brewPath)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["NONINTERACTIVE"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            environment["HOMEBREW_NO_COLOR"] = "1"
            environment["HOMEBREW_NO_EMOJI"] = "1"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failure(error.localizedDescription)
            }

            var transcript = Data()
            var pending = Data()
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                transcript.append(chunk)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if let onEvent, let event = BrewOutputParser.event(for: line) { onEvent(event) }
                }
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .success }
            return .failure(summary(of: String(decoding: transcript, as: UTF8.self), command: retryHint))
        }.value
    }

    /// Picks the line that explains a failure, and says what to do when brew needs a password.
    static func summary(of output: String, command: String) -> String {
        if output.localizedCaseInsensitiveContains("sudo") || output.localizedCaseInsensitiveContains("password") {
            return "This needs your password. Run `\(command)` in Terminal."
        }
        let errorLine = output.split(separator: "\n").last { $0.localizedCaseInsensitiveContains("error") }
        return errorLine.map { String($0).trimmingCharacters(in: .whitespaces) }
            ?? "brew failed. Run `\(command)` in Terminal to see why."
    }
}


/// Keeps the reservation until the app has reopened. Never force-quits unsaved work.
@MainActor
enum BrewAppInstaller {
    static func install(_ app: InstalledApp, token: String, progress: @escaping @MainActor (String) -> Void) async -> String? {
        var running: [NSRunningApplication] = []
        return await lifecycle(
            fetch: { progress("Downloading…"); return await BrewRunner.fetch(cask: token) },
            isRunning: {
                running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
                    .filter { $0.bundleURL?.resolvingSymlinksInPath() == app.url.resolvingSymlinksInPath() }
                return !running.isEmpty
            },
            quit: {
                progress("Waiting for \(app.name) to quit…")
                for process in running { process.terminate() }
                for _ in 0..<150 {
                    if running.allSatisfy(\.isTerminated) { return nil }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                return "Quit \(app.name) and save any open work, then try again."
            },
            upgrade: {
                progress("Installing…")
                return await BrewRunner.upgrade(cask: token)
            },
            relaunch: {
                progress("Relaunching…")
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
                    return nil
                } catch { return error.localizedDescription }
            }
        )
    }

    static func lifecycle(
        fetch: () async -> BrewRunner.Outcome,
        isRunning: () -> Bool,
        quit: () async -> String?,
        upgrade: () async -> BrewRunner.Outcome,
        relaunch: () async -> String?
    ) async -> String? {
        if case let .failure(message) = await fetch() { return message }
        let wasRunning = isRunning()
        if wasRunning, let message = await quit() { return message }
        let outcome = await upgrade()
        // Restore the user's running state on failure too, when Homebrew kept the old app.
        let launchError = wasRunning ? await relaunch() : nil
        if case let .failure(message) = outcome {
            return message + (launchError.map { " Couldn't reopen the app: \($0)" } ?? "")
        }
        if let launchError { return "The app updated, but couldn't reopen: \(launchError)" }
        return nil
    }
}
