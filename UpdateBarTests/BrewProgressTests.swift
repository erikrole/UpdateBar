import XCTest
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
