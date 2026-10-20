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
        let outcome = await DMGInstaller.install(app, from: url) { _ in }
        guard case .installed = outcome else { return XCTFail("\(outcome)") }
        let version = Bundle(url: copy)?.infoDictionary?["CFBundleShortVersionString"] as? String
        XCTAssertNotEqual(version, "1.0.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["Offload.app"].sorted())
    }
}
