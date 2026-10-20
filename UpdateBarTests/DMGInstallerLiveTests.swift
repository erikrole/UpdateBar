import XCTest
@testable import UpdateBar

/// Runs a real install of the published Offload release into a scratch copy (never /Applications).
/// `UPDATEBAR_LIVE=1 xcodebuild … test`.
@MainActor
final class DMGInstallerLiveTests: XCTestCase {
    func testInstallsPublishedOffloadIntoScratchCopy() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATEBAR_LIVE"] == "1")
        let dir = FileManager.default.temporaryDirectory.appending(path: "UpdateBarLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appending(path: "Offload.app")
        try FileManager.default.copyItem(at: URL(filePath: "/Applications/Offload.app"), to: copy)
        let plist = copy.appending(path: "Contents/Info.plist")
        var info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        info["CFBundleShortVersionString"] = "1.0.0"
        (info as NSDictionary).write(to: plist, atomically: true)
        let app = InstalledApp(bundleIdentifier: "com.erole.Offload", name: "Offload", url: copy, shortVersion: "1.0.0",
                               buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        let url = URL(string: "https://github.com/erikrole/offload-releases/releases/latest/download/Offload.dmg")!
        let outcome = await DMGInstaller.install(app, from: url, expectedTeamID: DMGInstaller.ownTeamID) { _ in }
        guard case .installed = outcome else { return XCTFail("\(outcome)") }
        let version = Bundle(url: copy)?.infoDictionary?["CFBundleShortVersionString"] as? String
        XCTAssertNotEqual(version, "1.0.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["Offload.app"].sorted())
    }

    /// A third-party cask download installed over a scratch copy, trusting the installed app's own Team ID.
    private func installCask(app name: String, bundleID: String, url: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "UpdateBarLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appending(path: "\(name).app")
        try FileManager.default.copyItem(at: URL(filePath: "/Applications/\(name).app"), to: copy)
        let before = Bundle(url: copy)?.infoDictionary?["CFBundleShortVersionString"] as? String
        let app = InstalledApp(bundleIdentifier: bundleID, name: name, url: copy, shortVersion: before,
                               buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        let outcome = await DMGInstaller.install(app, from: URL(string: url)!) { _ in }
        guard case .installed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["\(name).app"])
        let verify = Process()
        verify.executableURL = URL(filePath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", copy.path]
        try verify.run(); verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)
    }

    func testThirdPartyDMGCaskInstallsIntoScratchCopy() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATEBAR_LIVE"] == "1")
        try await installCask(app: "Keka", bundleID: "com.aone.keka", url: "https://github.com/aonez/Keka/releases/download/v1.6.8/Keka-1.6.8.dmg")
    }

    func testThirdPartyZipCaskInstallsIntoScratchCopy() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATEBAR_LIVE"] == "1")
        try await installCask(app: "WhatCable", bundleID: "uk.whatcable.whatcable", url: "https://github.com/darrylmorley/whatcable/releases/download/v1.5.0/WhatCable.zip")
    }

    func testWrongTeamIsRefused() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UPDATEBAR_LIVE"] == "1")
        let dir = FileManager.default.temporaryDirectory.appending(path: "UpdateBarLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appending(path: "WhatCable.app")
        try FileManager.default.copyItem(at: URL(filePath: "/Applications/WhatCable.app"), to: copy)
        let app = InstalledApp(bundleIdentifier: "uk.whatcable.whatcable", name: "WhatCable", url: copy, shortVersion: "1.0",
                               buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        // Fetch's release is validly signed, but not by WhatCable's developer.
        let url = URL(string: "https://github.com/erikrole/fetch-releases/releases/latest/download/Fetch.dmg")!
        let outcome = await DMGInstaller.install(app, from: url) { _ in }
        guard case let .failure(message) = outcome else { return XCTFail("must refuse") }
        XCTAssertTrue(message.contains("signature is invalid") || message.contains("expected developer") || message.contains("isn't the one"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["WhatCable.app"])
    }
}
