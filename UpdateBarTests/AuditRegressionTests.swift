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

    func testInvalidIndexShapeThrowsInsteadOfClaimingNoUpdates() {
        XCTAssertThrowsError(try HomebrewChecker.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try FormulaChecker.decode(Data("{}".utf8)))
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
}
