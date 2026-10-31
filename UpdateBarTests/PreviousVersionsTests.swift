import XCTest
@testable import UpdateBar

final class PreviousVersionsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "PreviousVersionsTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func makeApp(_ name: String, version: String) throws -> URL {
        let app = folder.appending(path: name)
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.Viewer", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return app
    }

    func testKeepRestoreAndSwapBack() throws {
        let store = PreviousVersions(root: folder.appending(path: "Previous.noindex"))
        let installed = folder.appending(path: "Viewer.app")
        let backup = try makeApp(".Viewer.app.updatebar-backup", version: "1.0")
        _ = try makeApp("Viewer.app", version: "2.0")
        let app = InstalledApp(bundleIdentifier: "test.Viewer", name: "Viewer", url: installed, shortVersion: "1.0",
                               buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        XCTAssertTrue(store.keep(backup, for: app))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.version, "1.0")

        XCTAssertThrowsError(try store.restore(entry, isRunning: { _ in true })) {
            XCTAssertEqual($0 as? PreviousVersions.Failure, .init(message: "Quit Viewer, then restore it."))
        }
        XCTAssertEqual(try store.restore(entry, isRunning: { _ in false }), "2.0", "the caller skips the swapped-out version")
        XCTAssertEqual(Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0")
        XCTAssertEqual(store.entries().first?.version, "2.0", "the replaced copy is kept so the restore can be undone")
    }

    func testOldOrBrokenEntriesArePruned() throws {
        let store = PreviousVersions(root: folder.appending(path: "Previous.noindex"))
        let backup = try makeApp(".Viewer.app.updatebar-backup", version: "1.0")
        let app = InstalledApp(bundleIdentifier: "test.Viewer", name: "Viewer", url: folder.appending(path: "Viewer.app"),
                               shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        store.keep(backup, for: app, now: Date().addingTimeInterval(-15 * 86_400))
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appending(path: "test.Viewer").path))
    }
}

@MainActor
final class ScheduledInstallTests: XCTestCase {
    func testNextFireIsTheComingHourAndLateRunsWait() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22))!
        let fire = ScheduledInstall.nextFire(after: evening, hour: 3, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: fire), DateComponents(day: 1, hour: 3))
        let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 1))!
        XCTAssertEqual(calendar.component(.day, from: ScheduledInstall.nextFire(after: early, hour: 3, calendar: calendar)), 1)
        XCTAssertFalse(ScheduledInstall.isTooLate(fire: fire, now: fire.addingTimeInterval(600)))
        XCTAssertTrue(ScheduledInstall.isTooLate(fire: fire, now: fire.addingTimeInterval(5 * 3600)))
    }

    func testTargetsSkipOpenAppsAndInteractiveInstalls() {
        func row(_ id: String, _ action: UpdateAction) -> AppUpdate {
            let app = InstalledApp(bundleIdentifier: id, name: id, url: URL(filePath: "/Applications/\(id).app"), shortVersion: "1",
                                   buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
            return AppUpdate(app: app, update: AvailableUpdate(bundleIdentifier: id, source: .homebrew, version: "2", comparableVersion: "2",
                                                               releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil,
                                                               action: action), alsoReportedBy: [])
        }
        let rows = [row("a", .brewUpgrade(token: "a")), row("open", .sparkleInstall),
                    row("pkg", .pkgInstall(URL(string: "https://example.com/x.pkg")!)), row("store", .openAppStore)]
        XCTAssertEqual(ScheduledInstall.targets(rows, isRunning: { $0 == "open" }).map(\.id), ["a"])
    }
}
