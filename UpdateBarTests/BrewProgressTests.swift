import XCTest
import AppKit
@testable import UpdateBar

final class BrewProgressTests: XCTestCase {
    func testParsesBrewUpgradeTranscript() {
        let transcript = """
        ==> Upgrading 3 outdated packages:
        uv 0.12.18 -> 0.13.0
        mediamtx 1.21.1 -> 1.21.2
        ffmpeg 9.0.2 -> 9.0.2_1
        ==> Fetching downloads for: uv, mediamtx and ffmpeg
        ==> Upgrading uv
          0.12.18 -> 0.13.0
        ==> Pouring uv--0.13.0.arm64_tahoe.bottle.tar.gz
        /opt/homebrew/Cellar/uv/0.13.0: 12 files, 41.2MB
        ==> Upgrading mediamtx
        ==> Pouring mediamtx--1.21.2.arm64_tahoe.bottle.tar.gz
        """
        var progress = BrewRunProgress(names: ["uv", "mediamtx", "ffmpeg"])
        for line in transcript.split(separator: "\n") {
            if let event = BrewOutputParser.event(for: String(line)) { progress.apply(event) }
        }
        XCTAssertEqual(progress.stages["uv"], .done)
        XCTAssertEqual(progress.stages["mediamtx"], .installing)
        XCTAssertEqual(progress.stages["ffmpeg"], .downloading)
        XCTAssertEqual(progress.finished, 1)
        XCTAssertEqual(progress.summary, "Installing mediamtx · 1 of 3 done")
    }

    func testIgnoresHeadingsAndUnknownPackages() {
        XCTAssertNil(BrewOutputParser.event(for: "==> Upgrading 3 outdated packages:"))
        XCTAssertNil(BrewOutputParser.event(for: "Removing: /opt/homebrew/Cellar/uv/0.12.18... (12 files, 40MB)"))
        var progress = BrewRunProgress(names: ["uv"])
        progress.apply(.init(names: ["openssl@3"], stage: .installing))
        XCTAssertEqual(progress.stages, ["uv": .queued])
    }

    func testCaskAndTapQualifiedNames() {
        XCTAssertEqual(BrewOutputParser.event(for: "google-chrome was successfully upgraded!"),
                       .init(names: ["google-chrome"], stage: .done))
        XCTAssertEqual(BrewOutputParser.event(for: "==> Upgrading homebrew/core/uv"),
                       .init(names: ["uv"], stage: .installing))
        XCTAssertEqual(BrewOutputParser.event(for: "\u{1B}[34m==>\u{1B}[0m \u{1B}[1mUpgrading uv\u{1B}[0m"),
                       .init(names: ["uv"], stage: .installing))
    }

    func testDoneNeverGoesBackwards() {
        var progress = BrewRunProgress(names: ["uv"])
        progress.apply(.init(names: ["uv"], stage: .done))
        progress.apply(.init(names: ["uv"], stage: .downloading))
        XCTAssertEqual(progress.stages["uv"], .done)
    }

    func testErrorLinesMarkThePackageFailed() {
        XCTAssertEqual(BrewOutputParser.event(for: "Error: ffmpeg: Failed to download resource \"ffmpeg\""),
                       .init(names: ["ffmpeg"], stage: .failed))
        XCTAssertEqual(BrewOutputParser.event(for: "Error: Cask 'google-chrome' is not installed."),
                       .init(names: ["google-chrome"], stage: .failed))
        XCTAssertNil(BrewOutputParser.event(for: "Error: Failure while executing; `/bin/sh` exited with 1."))
    }

    func testStoppedRunKeepsFinishedPackages() {
        var progress = BrewRunProgress(names: ["uv", "ffmpeg"])
        progress.apply(.init(names: ["uv"], stage: .done))
        progress.apply(.init(names: ["ffmpeg"], stage: .installing))
        progress.markUnfinishedFailed()
        XCTAssertEqual(progress.stages["uv"], .done)
        XCTAssertEqual(progress.stages["ffmpeg"], .failed)
        XCTAssertEqual(progress.finished, 1)
        progress.apply(.init(names: ["ffmpeg"], stage: .downloading))
        XCTAssertEqual(progress.stages["ffmpeg"], .failed)
    }
}

@MainActor
final class BrewAppLifecycleTests: XCTestCase {
    func testLifecycleOrderingAndFailureBoundaries() async {
        for scenario in ["running", "closed", "downloadFailure", "quitRefused", "upgradeFailure", "launchFailure"] {
            var events: [String] = []
            let error = await BrewAppInstaller.lifecycle(
                fetch: { events.append("fetch"); return scenario == "downloadFailure" ? .failure("download") : .success },
                isRunning: { events.append("running"); return scenario != "closed" },
                quit: { events.append("quit"); return scenario == "quitRefused" ? "quit refused" : nil },
                upgrade: { events.append("upgrade"); return scenario == "upgradeFailure" ? .failure("upgrade") : .success },
                relaunch: { events.append("relaunch"); return scenario == "launchFailure" ? "launch" : nil }
            )
            switch scenario {
            case "downloadFailure":
                XCTAssertEqual(events, ["fetch"]); XCTAssertEqual(error, "download")
            case "quitRefused":
                XCTAssertEqual(events, ["fetch", "running", "quit"]); XCTAssertEqual(error, "quit refused")
            case "closed":
                XCTAssertEqual(events, ["fetch", "running", "upgrade"]); XCTAssertNil(error)
            default:
                XCTAssertEqual(events, ["fetch", "running", "quit", "upgrade", "relaunch"])
                if scenario == "running" { XCTAssertNil(error) }
                if scenario == "upgradeFailure" { XCTAssertEqual(error, "upgrade") }
                if scenario == "launchFailure" { XCTAssertTrue(error?.contains("updated, but couldn't reopen") == true) }
            }
        }
    }
}

@MainActor
final class BrewAppLiveTests: XCTestCase {
    /// Explicit opt-in only; updates the named real app through the production action/store pipeline.
    func testRealHomebrewUpdate() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["UPDATEBAR_LIVE_BREW"] == "1")
        let id = try XCTUnwrap(env["UPDATEBAR_LIVE_BUNDLE_ID"])
        let token = try XCTUnwrap(env["UPDATEBAR_LIVE_CASK"])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = UpdateStore(defaults: defaults, collect: { _, _, _ in
            let apps = AppScanner().scan().filter { $0.bundleIdentifier == id }
            return UpdateStore.CheckSnapshot(apps: apps, result: await HomebrewChecker().check(apps))
        })
        await store.checkNow()
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.update.action, .brewUpgrade(token: token))
        guard row.update.action == .brewUpgrade(token: token) else { return }
        let old = NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)
        XCTAssertFalse(old.isEmpty)
        print("LIVE BEFORE \(row.app.displayVersion) -> \(row.update.version), PIDs \(old)")
        AppUpdateActions.perform(row, store: store)
        let deadline = Date().addingTimeInterval(300)
        while (!store.runningActions.isEmpty || store.isChecking) && Date() < deadline {
            if let status = store.actionMessages[row.id] { print("LIVE STAGE \(status)") }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(store.runningActions.isEmpty)
        XCTAssertFalse(store.isChecking)
        XCTAssertEqual(store.banner?.text, "Updated 1 app")
        XCTAssertFalse(store.rows.contains { $0.id == id })
        XCTAssertEqual(store.installedApps.first?.shortVersion, row.update.version)
        let new = NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)
        XCTAssertFalse(new.isEmpty)
        XCTAssertTrue(Set(old).isDisjoint(with: new))
        print("LIVE AFTER PIDs \(new), pending \(store.rows.count), banner \(store.banner?.text ?? "none")")
    }
}
