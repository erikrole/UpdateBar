import AppKit
import XCTest
@testable import UpdateBar

final class SourceRegressionTests: XCTestCase {
    func testSparkleRejectsWindowsAndMaximumOSReleases() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure url="https://example.com/mac.zip" sparkle:version="20" sparkle:os="macos" /></item>
        <item><sparkle:maximumSystemVersion>13.9</sparkle:maximumSystemVersion><enclosure sparkle:version="30" /></item>
        <item><enclosure url="https://example.com/windows.exe" sparkle:version="40" sparkle:os="windows" /></item>
        </channel></rss>
        """
        let items = AppcastParser.parse(Data(xml.utf8))
        let selected = SparkleChecker.newestCompatible(items, systemVersion: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(selected?.version, "20")
    }

    func testSparkleKeepsFullEnclosureAndRejectsTruncatedXML() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure url="https://example.com/full.zip" sparkle:version="20" />
        <sparkle:deltas><enclosure url="https://example.com/delta.patch" sparkle:version="999" sparkle:deltaFrom="10" /></sparkle:deltas>
        </item></channel></rss>
        """
        let items = AppcastParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.first?.downloadURL?.lastPathComponent, "full.zip")
        XCTAssertEqual(items.first?.version, "20")
        XCTAssertTrue(AppcastParser.parse(Data(xml.dropLast(6).utf8)).isEmpty)
    }

    func testHomebrewUsesExactPlatformVariation() throws {
        let json = Data("""
        [{"token":"viewer","version":"5.0","url":"https://example.com/arm.zip","artifacts":[{"app":["Viewer.app"]}],
          "variations":{"sonoma":{"version":"4.0","url":"https://example.com/intel.zip"},"arm64_sonoma":{"version":"4.1"}}}]
        """.utf8)
        let intel = try XCTUnwrap(HomebrewChecker.decode(json, platform: "sonoma").first)
        XCTAssertEqual(intel.version, "4.0")
        XCTAssertEqual(intel.downloadURL?.lastPathComponent, "intel.zip")
        XCTAssertEqual(intel.appNames, ["Viewer.app"])
        XCTAssertEqual(try HomebrewChecker.decode(json, platform: "arm64_sonoma").first?.version, "4.1")
        XCTAssertEqual(try HomebrewChecker.decode(json, platform: "arm64_tahoe").first?.version, "5.0")
        let formula = Data("""
        [{"name":"tool","versions":{"stable":"5.0"},"revision":1,"variations":{"sonoma":{"versions":{"stable":"4.0"},"revision":2}}}]
        """.utf8)
        XCTAssertEqual(try FormulaChecker.decode(formula, platform: "sonoma").first?.packageVersion, "4.0_2")
    }

    func testInstalledCaskStillRequiresMatchingIdentityAndNoAmbiguity() {
        let app = InstalledApp(bundleIdentifier: "com.other.Viewer", name: "Viewer", url: URL(filePath: "/Applications/Viewer.app"), shortVersion: "1", buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        let wrong = Cask(token: "viewer", version: "2", appNames: ["Viewer.app"], bundleIdentifiers: ["com.vendor.Viewer"])
        XCTAssertTrue(HomebrewChecker.evaluate([app], casks: [wrong], installed: ["viewer": [URL(filePath: "/Applications/Other.app")]]).updates.isEmpty)
        let one = Cask(token: "one", version: "2", appNames: ["Viewer.app"])
        let two = Cask(token: "two", version: "3", appNames: ["Viewer.app"])
        XCTAssertTrue(HomebrewChecker.evaluate([app], casks: [one, two], installed: ["one": [app.url], "two": [app.url]]).updates.isEmpty)
    }

    func testInstalledArtifactProvesOwnershipWithHelperOnlyIDs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let version = root.appending(path: "Caskroom/hazel/1.0")
        let destination = root.appending(path: "Applications/Hazel.app")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: version.appending(path: "Hazel.app"), withDestinationURL: destination)
        let installed = HomebrewChecker.installedCasks(in: [root.appending(path: "Caskroom")])
        let app = InstalledApp(bundleIdentifier: "com.noodlesoft.Hazel", name: "Hazel", url: destination, shortVersion: "1", buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        let cask = Cask(token: "hazel", version: "2", appNames: ["Hazel.app"], bundleIdentifiers: ["helper.HazelHelper"])
        let result = HomebrewChecker.evaluate([app], casks: [cask], installed: installed)
        XCTAssertEqual(result.updates.first?.action, .brewUpgrade(token: "hazel"))
        XCTAssertTrue(result.isCovered(app.id, by: .homebrew))
    }

    func testInvalidIndexShapeThrowsInsteadOfClaimingNoUpdates() throws {
        XCTAssertThrowsError(try HomebrewChecker.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try FormulaChecker.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try HomebrewChecker.decode(Data("[{".utf8)))
        XCTAssertThrowsError(try HomebrewChecker.decode(Data("[1]".utf8)))
        XCTAssertThrowsError(try HomebrewChecker.decode(Data("[] trailing".utf8)))
        let empty = try HomebrewChecker.decode(Data(" \n[]\n ".utf8))
        XCTAssertEqual(empty.count, 0)
    }

    func testScannerKeepsNeededFieldsAndSkipsTheRest() throws {
        let casks = Data(#"""
        [{"token":"view\"er","version":"3.1,77","homepage":"https://example.com/a\/b","url":"https://example.com/arm.zip","disabled":true,
          "artifacts":[{"uninstall":[{"quit":"com.vendor.Viewer"},{"signal":{"TERM":"com.vendor.Viewer"}}]},{"app":["Apps/Viewer.app",{"target":"/Applications"}]},{"binary":["tool"]}],
          "caveats":"ignore","depends_on":{"macos":{">=":["14"]}},
          "variations":{"sonoma":{"version":"4.0","url":null,"disabled":false,"artifacts":[{"app":["Viewer Sonoma.app"],"uninstall":[{"quit":["one","two"]}]}]},
                        "arm64_sonoma":{"auto_updates":true,"version":"1\u00202"}}}]
        """#.utf8)
        let sonoma = try XCTUnwrap(HomebrewChecker.decode(casks, platform: "sonoma").first)
        XCTAssertEqual(sonoma.token, "view\"er")
        XCTAssertEqual(sonoma.version, "4.0")
        XCTAssertEqual(sonoma.homepage?.absoluteString, "https://example.com/a/b")
        XCTAssertNil(sonoma.downloadURL)
        XCTAssertFalse(sonoma.isDisabled)
        XCTAssertEqual(sonoma.appNames, ["Viewer Sonoma.app"])
        XCTAssertEqual(sonoma.bundleIdentifiers, ["one", "two"])
        XCTAssertFalse(sonoma.autoUpdates)
        let arm = try XCTUnwrap(HomebrewChecker.decode(casks, platform: "arm64_sonoma").first)
        XCTAssertEqual(arm.version, "1 2")
        XCTAssertEqual(arm.downloadURL?.lastPathComponent, "arm.zip")
        XCTAssertTrue(arm.isDisabled)
        XCTAssertEqual(arm.appNames, ["Viewer.app"])
        XCTAssertEqual(arm.bundleIdentifiers, ["com.vendor.Viewer"])
        XCTAssertTrue(arm.autoUpdates)

        let formulae = Data(#"""
        [{"name":"tool","versions":{"stable":"5.0","head":"HEAD"},"revision":1,"desc":"A \"tool\"","homepage":"https://ex.com","oldnames":["old"],
          "bottle":{"stable":{"files":{"sonoma":{"cellar":":any","url":"https://example.bottle","sha256":"abc"}},"rebuild":0}},
          "variations":{"sonoma":{"versions":{"stable":"4.0"},"revision":2,"oldnames":["older","oldest"],"disabled":true,"desc":null}}}]
        """#.utf8)
        let overridden = try XCTUnwrap(FormulaChecker.decode(formulae, platform: "sonoma").first)
        XCTAssertEqual(overridden.packageVersion, "4.0_2")
        XCTAssertEqual(overridden.oldNames, ["older", "oldest"])
        XCTAssertTrue(overridden.isDisabled)
        XCTAssertNil(overridden.summary)
        XCTAssertEqual(overridden.homepage, URL(string: "https://ex.com"))
        let base = try XCTUnwrap(FormulaChecker.decode(formulae, platform: "other").first)
        XCTAssertEqual(base.packageVersion, "5.0_1")
        XCTAssertEqual(base.summary, "A \"tool\"")
        XCTAssertEqual(base.oldNames, ["old"])
        XCTAssertFalse(base.isDisabled)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// No real network traffic in cache tests; every response is fixed by the URL.
private final class IndexProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = url.path == "/unchanged" && request.value(forHTTPHeaderField: "If-None-Match") == "old" ? 304 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((url.path == "/bad" ? "<html>error</html>" : "[2]").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class IndexRegressionTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ path: String, contents: String = "[1]", ttl: TimeInterval = 0) throws -> IndexCache {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "index.json")
        try Data(contents.utf8).write(to: file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IndexProtocol.self]
        return IndexCache(remoteURL: URL(string: "https://example.com/\(path)")!, fileURL: file,
                          client: HTTPClient(session: URLSession(configuration: configuration)), revalidateAfter: ttl)
    }

    func testConcurrentAndWarmLoadsDecodeOnlyOnce() async throws {
        let index = try fixture("valid", ttl: 600)
        let cache = DecodedIndex<[Int]>()
        let counter = Counter()
        let values = try await withThrowingTaskGroup(of: [Int].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await cache.load(from: index) { data in
                        _ = counter.increment()
                        return try JSONDecoder().decode([Int].self, from: data)
                    }.value
                }
            }
            var values: [[Int]] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values, Array(repeating: [1], count: 20))
        XCTAssertEqual(counter.value, 1)
    }

    func testMemoryCacheDoesNotExtendDiskFreshnessWindow() async throws {
        let index = try fixture("valid", ttl: 600)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-599)], ofItemAtPath: index.fileURL.path)
        let cache = DecodedIndex<[Int]>()
        let counter = Counter()
        for date in [now, now.addingTimeInterval(2)] {
            _ = try await cache.load(from: index, now: date) { data in
                _ = counter.increment()
                return try JSONDecoder().decode([Int].self, from: data)
            }
        }
        XCTAssertEqual(counter.value, 2)
    }

    func testBadResponsePreservesValidCacheAndWarns() async throws {
        let index = try fixture("bad")
        let loaded = try await index.load { try JSONDecoder().decode([Int].self, from: $0) }
        XCTAssertEqual(loaded.value, [1])
        XCTAssertNotNil(loaded.warning)
        XCTAssertEqual(try String(contentsOf: index.fileURL, encoding: .utf8), "[1]")
    }

    func testOfflineCacheIsMarkedStale() async throws {
        let index = try fixture("offline")
        let loaded = try await index.load { try JSONDecoder().decode([Int].self, from: $0) }
        XCTAssertEqual(loaded.value, [1])
        XCTAssertTrue(loaded.warning?.contains("cached index") == true)
    }

    func testRevalidationAndValidatorReplacement() async throws {
        let index = try fixture("unchanged")
        try "old".write(to: index.fileURL.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
        let loaded = try await index.load { try JSONDecoder().decode([Int].self, from: $0) }
        XCTAssertEqual(loaded.value, [1])
        XCTAssertNil(loaded.warning)
        let fresh = IndexCache(remoteURL: URL(string: "https://example.com/valid")!, fileURL: index.fileURL, client: index.client, revalidateAfter: 0)
        let replaced = try await fresh.load { try JSONDecoder().decode([Int].self, from: $0) }
        XCTAssertEqual(replaced.value, [2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.fileURL.appendingPathExtension("etag").path))
    }

    func testCorruptCacheIsRecovered() async throws {
        let index = try fixture("valid", contents: "bad JSON", ttl: 600)
        let loaded = try await index.load { try JSONDecoder().decode([Int].self, from: $0) }
        XCTAssertEqual(loaded.value, [2])
        XCTAssertNil(loaded.warning)
    }

    func testHTTPRejectsNonHTTPSAndRedirectDowngrades() async throws {
        let client = HTTPClient()
        do {
            _ = try await client.data(from: URL(string: "file:///tmp/index.json")!)
            XCTFail("Non-HTTPS request accepted")
        } catch { XCTAssertTrue(error is HTTPClient.HTTPError) }
        let delegate = HTTPSRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "http://example.com")!)) { request in
            XCTAssertNil(request)
        }
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://cdn.example.com")!)) { request in
            XCTAssertEqual(request?.url?.host, "cdn.example.com")
        }
        session.invalidateAndCancel()
    }

    func testSharedClientDoesNotRetainResponseBodies() {
        let configuration = HTTPClient.shared.session.configuration
        XCTAssertEqual(configuration.urlCache?.memoryCapacity, Optional(0))
        XCTAssertEqual(configuration.urlCache?.diskCapacity, Optional(0))
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testDecodedIndexDropsEntriesWhenTheWindowEnds() async throws {
        let index = try fixture("valid", ttl: 600)
        let cache = DecodedIndex<[Int]>()
        let loaded = try await cache.load(from: index) { try JSONDecoder().decode([Int].self, from: $0) }
        let fresh = loaded.validatedAt.addingTimeInterval(30)
        let stillFresh = await cache.retainsFreshEntry(for: index, now: fresh)
        XCTAssertTrue(stillFresh)
        await cache.evictExpired(at: fresh)
        let kept = await cache.retainsFreshEntry(for: index, now: fresh)
        XCTAssertTrue(kept)
        let expired = loaded.validatedAt.addingTimeInterval(601)
        await cache.evictExpired(at: expired)
        let dropped = await cache.retainsFreshEntry(for: index, now: expired)
        XCTAssertFalse(dropped)
    }

    func testZeroFreshnessWindowIsNotRetained() async throws {
        let index = try fixture("valid", ttl: 0)
        let cache = DecodedIndex<[Int]>()
        _ = try await cache.load(from: index) { try JSONDecoder().decode([Int].self, from: $0) }
        let retained = await cache.retainsFreshEntry(for: index)
        XCTAssertFalse(retained)
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor
final class StoreRegressionTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let name = "UpdateBarTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: "notificationsEnabled")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    private func snapshot() -> UpdateStore.CheckSnapshot {
        let app = InstalledApp(bundleIdentifier: "test.App", name: "App", url: URL(filePath: "/tmp/App.app"), shortVersion: "1", buildVersion: "1", sparkleFeedURL: nil, hasAppStoreReceipt: false)
        let update = AvailableUpdate(bundleIdentifier: app.id, source: .homebrew, version: "2", comparableVersion: "2", releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil, action: .brewUpgrade(token: "app"))
        let tool = ToolUpdate(name: "tool", installedVersion: "1", latestVersion: "2", requested: true, summary: nil, homepage: nil)
        return .init(apps: [app], result: CheckerResult(updates: [update]), tools: [tool])
    }

    private func packageSnapshot() -> UpdateStore.CheckSnapshot {
        var value = snapshot()
        let app = InstalledApp(bundleIdentifier: "test.Package", name: "Package", url: URL(filePath: "/tmp/Package.app"), shortVersion: "1", buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        value.apps.append(app)
        value.result.updates.append(AvailableUpdate(bundleIdentifier: app.id, source: .homebrew, version: "2", comparableVersion: "2", releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil, action: .pkgInstall(URL(string: "https://example.com/update.pkg")!)))
        return value
    }

    func testUpdateAllExcludesInteractivePackages() async {
        let result = packageSnapshot(), checks = Counter()
        let refreshed = expectation(description: "refreshed")
        var installed: [String] = []
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }
            return result
        }, installApp: { row, _, _ in installed.append(row.id); return nil })
        await store.checkNow(notify: false)
        XCTAssertEqual(store.inPlaceUpdateCount, 1)
        store.updateAllInPlace()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(installed, ["test.App"])
        XCTAssertEqual(store.banner?.text, "Updated 1 app")
    }

    func testPackageReservesInstallerAndReportsManualFinish() async throws {
        let result = packageSnapshot(), checks = Counter(), installs = Counter(), gate = Gate()
        let started = expectation(description: "package started"), refreshed = expectation(description: "refreshed")
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }
            return result
        }, installApp: { _, _, _ in
            _ = installs.increment(); started.fulfill(); await gate.wait(); return nil
        })
        await store.checkNow(notify: false)
        let package = try XCTUnwrap(store.rows.first { $0.id == "test.Package" })
        XCTAssertFalse(package.installsInPlace)
        XCTAssertTrue(package.requiresInstallerReservation)
        store.perform(package)
        store.perform(package)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(store.canInstallUpdates)
        XCTAssertEqual(store.statusSummary, "Updating apps…")
        XCTAssertEqual(installs.value, 1)
        await gate.open()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(store.actionMessages[package.id], PKGInstaller.openedNotice)
        XCTAssertEqual(store.banner?.text, "Opened in Installer. Finish the installation there, then check again.")
    }

    func testCheckingBlocksInstallEntryPoints() async {
        let result = snapshot(), gate = Gate(), checks = Counter(), installs = Counter()
        let checking = expectation(description: "checking")
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { checking.fulfill(); await gate.wait() }
            return result
        }, installApp: { _, _, _ in _ = installs.increment(); return nil },
        installTools: { _, _ in _ = installs.increment(); return .success })
        await store.checkNow(notify: false)
        let refresh = Task { await store.checkNow(notify: false) }
        await fulfillment(of: [checking], timeout: 2)
        store.perform(store.rows[0])
        store.updateAllInPlace()
        store.upgradeAllTools()
        XCTAssertTrue(store.runningActions.isEmpty)
        await gate.open()
        await refresh.value
        XCTAssertEqual(installs.value, 0)
    }

    func testConcurrentChecksShareOnePassAndAwaitCompletion() async {
        let gate = Gate(), started = expectation(description: "check started")
        let count = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            _ = count.increment(); started.fulfill(); await gate.wait(); return .init()
        })
        let first = Task { await store.checkNow(notify: false) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await store.checkNow(notify: false) }
        await Task.yield()
        XCTAssertTrue(store.isChecking)
        await gate.open()
        await first.value; await second.value
        XCTAssertEqual(count.value, 1)
        XCTAssertFalse(store.isChecking)
    }

    func testPreferenceChangeDuringCheckGetsOneFollowupPass() async {
        let gate = Gate(), started = expectation(description: "first check")
        let count = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { betas, _, _ in
            if count.increment() == 1 { started.fulfill(); await gate.wait() }
            return .init(result: CheckerResult(feedChannels: ["test.App": betas]))
        })
        let first = Task { await store.checkNow(notify: false) }
        await fulfillment(of: [started], timeout: 2)
        store.setBeta(true, for: "test.App")
        let followup = Task { await store.checkNow(refreshAfterCurrent: true, notify: false) }
        await Task.yield()
        await gate.open()
        await first.value; await followup.value
        XCTAssertEqual(count.value, 2)
        XCTAssertEqual(store.betaChannels(for: "test.App"), ["test.App"])
        XCTAssertTrue(store.isBetaEnabled("test.App"))
    }

    func testBatchBlocksDuplicateAndToolInstallersBeforeYielding() async throws {
        let snapshot = snapshot(), gate = Gate()
        let started = expectation(description: "install"), refreshed = expectation(description: "refresh")
        let checks = Counter(), installs = Counter(), tools = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }; return snapshot
        }, installApp: { _, _, _ in
            _ = installs.increment(); started.fulfill(); await gate.wait(); return nil
        }, installTools: { _, _ in _ = tools.increment(); return .success })
        await store.checkNow(notify: false)
        store.updateAllInPlace()
        store.updateAllInPlace()
        store.perform(try XCTUnwrap(store.rows.first))
        store.upgradeAllTools()
        XCTAssertFalse(store.canInstallUpdates)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(installs.value, 1)
        XCTAssertEqual(tools.value, 0)
        await gate.open()
        await fulfillment(of: [refreshed], timeout: 2)
        await store.checkNow(notify: false)
        XCTAssertTrue(store.canInstallUpdates)
    }

    func testBatchStaysReservedAfterFirstAppFinishes() async {
        var batch = snapshot()
        let second = InstalledApp(bundleIdentifier: "test.Second", name: "Second", url: URL(filePath: "/tmp/Second.app"), shortVersion: "1", buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        batch.apps.append(second)
        batch.result.updates.append(AvailableUpdate(bundleIdentifier: second.id, source: .homebrew, version: "2", comparableVersion: "2", releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil, action: .brewUpgrade(token: "second")))
        let result = batch, gate = Gate(), installs = Counter(), tools = Counter(), checks = Counter()
        let secondStarted = expectation(description: "second installer"), refreshed = expectation(description: "final refresh")
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }; return result
        }, installApp: { _, _, _ in
            if installs.increment() == 2 { secondStarted.fulfill(); await gate.wait() }
            return nil
        }, installTools: { _, _ in _ = tools.increment(); return .success })
        await store.checkNow(notify: false)
        store.updateAllInPlace()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(store.runningActions, ["test.App", "test.Second"])
        store.updateAllInPlace()
        store.upgradeAllTools()
        XCTAssertEqual(installs.value, 2)
        XCTAssertEqual(tools.value, 0)
        await gate.open()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertTrue(store.canInstallUpdates)
    }

    func testToolInstallerBlocksAppAndDuplicateToolRuns() async throws {
        let snapshot = snapshot(), gate = Gate()
        let started = expectation(description: "tool install"), refreshed = expectation(description: "refresh")
        let checks = Counter(), apps = Counter(), tools = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }; return snapshot
        }, installApp: { _, _, _ in _ = apps.increment(); return nil }, installTools: { _, _ in
            _ = tools.increment(); started.fulfill(); await gate.wait(); return .success
        })
        await store.checkNow(notify: false)
        store.upgradeAllTools()
        store.upgradeAllTools()
        store.perform(try XCTUnwrap(store.rows.first))
        store.updateAllInPlace()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(tools.value, 1)
        XCTAssertEqual(apps.value, 0)
        await gate.open()
        await fulfillment(of: [refreshed], timeout: 2)
        await store.checkNow(notify: false)
        XCTAssertTrue(store.canInstallUpdates)
    }

    func testHiddenToolsPreferenceReachesCollector() async {
        let defaults = preferences()
        defaults.set(false, forKey: "showsCommandLineTools")
        let store = UpdateStore(defaults: defaults, collect: { _, _, showsTools in
            XCTAssertFalse(showsTools)
            return .init()
        })
        await store.checkNow(notify: false)
        XCTAssertTrue(store.tools.isEmpty)
    }

    func testIncompleteCheckDoesNotClaimUpToDateOrChangeNotificationHistory() async {
        let defaults = preferences()
        defaults.set(["existing"], forKey: "notifiedUpdateIDs")
        let store = UpdateStore(defaults: defaults, collect: { _, _, _ in
            .init(result: CheckerResult(failures: [.init(source: .sparkle, subject: "App", message: "Offline")]))
        })
        await store.checkNow(notify: false)
        XCTAssertEqual(store.statusSummary, "Some updates couldn’t be checked")
        XCTAssertEqual(defaults.stringArray(forKey: "notifiedUpdateIDs"), ["existing"])
    }

    func testPartialAppBatchContinuesAndWarns() async {
        var batch = snapshot()
        let second = InstalledApp(bundleIdentifier: "test.Second", name: "Second", url: URL(filePath: "/tmp/Second.app"), shortVersion: "1", buildVersion: nil, sparkleFeedURL: nil, hasAppStoreReceipt: false)
        batch.apps.append(second)
        batch.result.updates.append(AvailableUpdate(bundleIdentifier: second.id, source: .homebrew, version: "2", comparableVersion: "2", releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil, action: .brewUpgrade(token: "second")))
        let result = batch
        let refreshed = expectation(description: "refresh")
        let checks = Counter(), installs = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }
            return result
        }, installApp: { row, _, _ in
            _ = installs.increment()
            return row.app.bundleIdentifier == "test.App" ? "needs a password" : nil
        })
        await store.checkNow(notify: false)
        store.updateAllInPlace()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(installs.value, 2)
        XCTAssertEqual(store.banner, UpdateStore.Banner(text: "Updated 1 of 2. App still needs an update", isWarning: true))
        XCTAssertEqual(store.actionMessages["test.App"], "needs a password")
        XCTAssertNil(store.actionMessages["test.Second"])
        XCTAssertTrue(store.canInstallUpdates)
    }

    func testPartialToolUpgradeWarnsWithoutASuccessBanner() async {
        var snap = snapshot()
        snap.tools.append(ToolUpdate(name: "ffmpeg", installedVersion: "1", latestVersion: "2", requested: true, summary: nil, homepage: nil))
        let result = snap
        let refreshed = expectation(description: "refresh")
        let checks = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }
            return result
        }, installTools: { names, progress in
            progress(.init(names: [names[0]], stage: .done))
            return .failure("Error: ffmpeg: download failed")
        })
        await store.checkNow(notify: false)
        store.upgradeAllTools()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(store.banner, UpdateStore.Banner(text: "Upgraded 1 of 2 before brew stopped", isWarning: true))
        XCTAssertEqual(store.actionMessages[UpdateStore.allToolsID], "Error: ffmpeg: download failed")
        XCTAssertNil(store.toolRun)
        XCTAssertTrue(store.canInstallUpdates)
    }

    func testFailedToolUpgradeDoesNotLookSuccessful() async {
        let result = snapshot()
        let refreshed = expectation(description: "refresh")
        let checks = Counter()
        let store = UpdateStore(defaults: preferences(), collect: { _, _, _ in
            if checks.increment() == 2 { refreshed.fulfill() }
            return result
        }, installTools: { _, _ in .failure("Error: locked") })
        await store.checkNow(notify: false)
        store.upgradeAllTools()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(store.banner, UpdateStore.Banner(text: "Couldn't upgrade tool", isWarning: true))
        XCTAssertEqual(store.actionMessages[UpdateStore.allToolsID], "Error: locked")
        XCTAssertTrue(store.canInstallUpdates)
    }
}

@MainActor
final class BackgroundCheckSchedulerTests: XCTestCase {
    func testScheduleToleranceMatchesTheInterval() {
        let hour = BackgroundCheckSchedule(hours: 1)
        XCTAssertEqual(hour.interval, 3600)
        XCTAssertEqual(hour.tolerance, hour.interval / 2)
        let day = BackgroundCheckSchedule(hours: 24)
        XCTAssertEqual(day.tolerance, 12 * 3600)
        let clamped = BackgroundCheckSchedule(hours: 0)
        XCTAssertEqual(clamped.interval, 3600)
        XCTAssertEqual(clamped.tolerance, clamped.interval / 2)
    }

    func testSystemSchedulerAcceptsConfiguredTiming() {
        let activity = SystemBackgroundActivity(identifier: "com.erole.UpdateBar.test.\(UUID())")
        let timing = BackgroundCheckSchedule(hours: 1)
        activity.interval = timing.interval
        activity.tolerance = timing.tolerance
        activity.repeats = true
        activity.schedule { completion in completion(.finished) }
        activity.invalidate()
    }

    func testDeferredInvocationDoesNotCheck() {
        let ran = Counter()
        let sink = ResultSink()
        BackgroundCheckRunner.handle(shouldDefer: true, perform: { _ = ran.increment() }) { sink.result = $0 }
        XCTAssertEqual(ran.value, 0)
        XCTAssertEqual(sink.result, .deferred)
    }

    func testAllowedInvocationFinishesBeforeTheCheckReturns() async {
        let ran = expectation(description: "check ran")
        let sink = ResultSink()
        BackgroundCheckRunner.handle(shouldDefer: false, perform: { ran.fulfill() }) { sink.result = $0 }
        XCTAssertEqual(sink.result, .finished)
        await fulfillment(of: [ran], timeout: 2)
    }

    func testReschedulingInvalidatesThePreviousActivity() {
        var made: [ScriptedBackgroundActivity] = []
        let scheduler = BackgroundCheckScheduler { _ in
            let activity = ScriptedBackgroundActivity()
            made.append(activity)
            return activity as any BackgroundActivityScheduling
        }
        scheduler.schedule(intervalHours: 6) { }
        scheduler.schedule(intervalHours: 1) { }
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[0].invalidated)
        XCTAssertNil(made[0].handler)
        XCTAssertFalse(made[1].invalidated)
        XCTAssertEqual(made[1].interval, 3600)
        XCTAssertEqual(made[1].tolerance, 1800)
        XCTAssertTrue(made[1].repeats)
        XCTAssertEqual(made[1].qualityOfService, .utility)
    }

    func testRepeatingCheckUsesWideToleranceAndSkipsDeferredWakes() async {
        let activity = ScriptedBackgroundActivity()
        let scheduler = BackgroundCheckScheduler { _ in activity as any BackgroundActivityScheduling }
        let checks = Counter()
        let name = "UpdateBarTests.scheduler.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: "notificationsEnabled")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let checked = expectation(description: "check ran")
        let store = UpdateStore(defaults: defaults, collect: { _, _, _ in
            if checks.increment() == 1 { checked.fulfill() }
            return .init()
        }, backgroundChecks: scheduler)
        store.checkIntervalHours = 12

        XCTAssertEqual(activity.interval, 12 * 3600)
        XCTAssertEqual(activity.tolerance, activity.interval / 2)
        XCTAssertTrue(activity.repeats)
        XCTAssertEqual(activity.qualityOfService, .utility)
        XCTAssertEqual(checks.value, 0, "Scheduling the repeating check must not run it")

        activity.shouldDefer = true
        activity.fire()
        XCTAssertEqual(activity.results, [.deferred])
        XCTAssertEqual(checks.value, 0)
        XCTAssertNil(store.lastChecked)

        activity.shouldDefer = false
        activity.fire()
        XCTAssertEqual(activity.results, [.deferred, .finished])
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertEqual(checks.value, 1)
        XCTAssertNotNil(store.lastChecked)
    }
}

/// Stands in for `NSBackgroundActivityScheduler` so tests can fire or defer a check
/// without registering a system activity or waiting out the real interval.
private final class ResultSink: @unchecked Sendable {
    var result: NSBackgroundActivityScheduler.Result?
}

private final class ScriptedBackgroundActivity: BackgroundActivityScheduling, @unchecked Sendable {
    var repeats = false
    var interval: TimeInterval = 0
    var tolerance: TimeInterval = 0
    var qualityOfService: QualityOfService = .default
    var shouldDefer = false
    private(set) var invalidated = false
    private(set) var handler: (@Sendable (NSBackgroundActivityScheduler.CompletionHandler) -> Void)?
    private(set) var results: [NSBackgroundActivityScheduler.Result] = []
    var onCompletion: (@Sendable (NSBackgroundActivityScheduler.Result) -> Void)?

    func schedule(_ block: @escaping @Sendable (NSBackgroundActivityScheduler.CompletionHandler) -> Void) {
        invalidated = false
        handler = block
    }

    func invalidate() {
        invalidated = true
        handler = nil
    }

    func fire() {
        handler? { result in
            self.results.append(result)
            self.onCompletion?(result)
        }
    }
}

@MainActor
final class IconThumbnailTests: XCTestCase {
    func testFittedIconIsASmallBitmap() {
        let source = NSImage(size: NSSize(width: 512, height: 512))
        let fitted = IconThumbnail.fitted(from: source)
        XCTAssertEqual(fitted.size, NSSize(width: 32, height: 32))
        let width = fitted.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width ?? 0
        XCTAssertEqual(width, 64)
    }
}

final class PackageStagingTests: XCTestCase {
    func testSweepPreservesRecentPackagesAndUnrelatedFiles() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "UpdateBarPackageTests-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let now = Date()
        for name in ["old.pkg", "recent.pkg", "keep.txt"] {
            let file = directory.appending(path: name)
            try Data("fixture".utf8).write(to: file)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(name == "recent.pkg" ? -60 : -8 * 86400)], ofItemAtPath: file.path)
        }
        let folder = directory.appending(path: "folder.pkg")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: folder.path)
        try fm.createSymbolicLink(at: directory.appending(path: "link.pkg"), withDestinationURL: directory.appending(path: "keep.txt"))
        PKGInstaller.sweepStaging(in: directory, now: now)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: directory.path)), ["recent.pkg", "keep.txt", "folder.pkg", "link.pkg"])
    }
}
