import XCTest
@testable import UpdateBar

private func app(
    _ id: String,
    name: String? = nil,
    bundle: String? = nil,
    short: String?,
    build: String? = nil,
    feed: String? = nil,
    receipt: Bool = false,
    edKey: Bool = false
) -> InstalledApp {
    let name = name ?? id.components(separatedBy: ".").last!
    return InstalledApp(
        bundleIdentifier: id,
        name: name,
        url: URL(filePath: "/Applications/\(bundle ?? name).app"),
        shortVersion: short,
        buildVersion: build,
        sparkleFeedURL: feed.flatMap(URL.init(string:)),
        hasAppStoreReceipt: receipt,
        hasSparkleEDKey: edKey
    )
}

final class SparkleTests: XCTestCase {
    private let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>2.1</title>
          <pubDate>Mon, 05 Oct 2026 10:00:00 +0000</pubDate>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <description><![CDATA[<ul><li>Faster sync</li><li>Fixes &amp; polish</li></ul>]]></description>
          <enclosure url="https://example.com/App-2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1" />
        </item>
        <item>
          <title>2.2 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/App-2.2b1.zip" sparkle:version="220" sparkle:shortVersionString="2.2b1" />
        </item>
        <item>
          <title>3.0</title>
          <sparkle:version>300</sparkle:version>
          <sparkle:shortVersionString>3.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-3.0.zip" />
        </item>
      </channel>
    </rss>
    """

    private let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

    func testParsesEnclosureAndElementVersions() {
        let items = AppcastParser.parse(Data(appcast.utf8))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].version, "210")
        XCTAssertEqual(items[0].shortVersion, "2.1")
        XCTAssertEqual(items[2].version, "300")
        XCTAssertEqual(items[1].channel, "beta")
        XCTAssertNotNil(items[0].publishedAt)
    }

    func testSkipsBetaChannelAndIncompatibleReleases() {
        let items = AppcastParser.parse(Data(appcast.utf8))
        let best = SparkleChecker.newestCompatible(items, systemVersion: system)
        XCTAssertEqual(best?.shortVersion, "2.1")
    }

    func testReportsNewerBuildWithPlainNotes() throws {
        let items = AppcastParser.parse(Data(appcast.utf8))
        let best = try XCTUnwrap(SparkleChecker.newestCompatible(items, systemVersion: system))
        let update = try XCTUnwrap(SparkleChecker.update(for: app("com.x.App", short: "2.0", build: "200"), item: best))
        XCTAssertEqual(update.version, "2.1")
        XCTAssertEqual(update.releaseNotes, "• Faster sync\n• Fixes & polish")
    }

    func testInPlaceInstallOnlyWithEdDSAKey() throws {
        let item = AppcastItem(version: "210", shortVersion: "2.1")
        let signed = try XCTUnwrap(SparkleChecker.update(for: app("com.x.App", short: "2.0", build: "200", edKey: true), item: item))
        XCTAssertEqual(signed.action, .sparkleInstall)
        let unsigned = try XCTUnwrap(SparkleChecker.update(for: app("com.x.App", short: "2.0", build: "200"), item: item))
        XCTAssertEqual(unsigned.action, .launchApp)
    }

    func testCurrentAppIsNotFlagged() throws {
        let items = AppcastParser.parse(Data(appcast.utf8))
        let best = try XCTUnwrap(SparkleChecker.newestCompatible(items, systemVersion: system))
        XCTAssertNil(SparkleChecker.update(for: app("com.x.App", short: "2.1", build: "210"), item: best))
        // A newer readable version wins even if the build scheme looks lower.
        XCTAssertNil(SparkleChecker.update(for: app("com.x.App", short: "2.5", build: "9"), item: best))
    }

    func testDecoratedShortVersionWithSameBuildIsCurrent() {
        // Dia publishes "1.52.0 (88431)" while the app says "1.52.0".
        let item = AppcastItem(version: "88431", shortVersion: "1.52.0 (88431)")
        XCTAssertNil(SparkleChecker.update(for: app("company.thebrowser.dia", short: "1.52.0", build: "88431"), item: item))
        let newer = AppcastItem(version: "88500", shortVersion: "1.53.0 (88500)")
        XCTAssertNotNil(SparkleChecker.update(for: app("company.thebrowser.dia", short: "1.52.0", build: "88431"), item: newer))
    }
}

final class AppStoreTests: XCTestCase {
    func testEvaluatesLookupResults() throws {
        let json = """
        {"resultCount":2,"results":[
          {"bundleId":"com.a.One","version":"8.12.41","releaseNotes":"Bug fixes","currentVersionReleaseDate":"2026-10-01T07:00:00Z","trackViewUrl":"https://apps.apple.com/app/id1"},
          {"bundleId":"com.a.Two","version":"2.0"}
        ]}
        """
        let lookups = try AppStoreChecker.decode(Data(json.utf8))
        let apps = [
            app("com.a.One", short: "8.12.40", receipt: true),
            app("com.a.Two", short: "2.0", receipt: true),
            app("com.a.Three", short: "1.0", receipt: true),
        ]
        let result = AppStoreChecker.evaluate(apps, lookups: lookups)
        XCTAssertEqual(result.updates.map(\.bundleIdentifier), ["com.a.One"])
        XCTAssertEqual(result.updates.first?.releaseNotes, "Bug fixes")
        XCTAssertEqual(result.covered[.appStore], ["com.a.One", "com.a.Two"])
    }
}

final class HomebrewTests: XCTestCase {
    private let casks = [
        Cask(token: "iina", version: "1.5.0", appNames: ["IINA.app"], bundleIdentifiers: ["com.colliderli.iina"],
             homepage: URL(string: "https://iina.io")),
        Cask(token: "foo", version: "2026.1", appNames: ["Foo.app"]),
        Cask(token: "bar", version: "3.1,77", appNames: ["Bar.app"]),
        Cask(token: "bar-alt", version: "9.0", appNames: ["Bar.app"]),
        Cask(token: "nightly", version: "latest", appNames: ["Nightly.app"]),
    ]

    func testBrewInstalledCaskIsAuthoritativeAndUpgradable() throws {
        let iina = app("com.colliderli.iina", name: "IINA", short: "1.4.4")
        let result = HomebrewChecker.evaluate([iina], casks: casks, installed: ["iina": "1.4.4"])
        let update = try XCTUnwrap(result.updates.first)
        XCTAssertEqual(update.action, .brewUpgrade(token: "iina"))
        XCTAssertTrue(result.isCovered("com.colliderli.iina", by: .homebrew))
    }

    func testSelfUpdatedCaskIsNotFlagged() {
        let iina = app("com.colliderli.iina", name: "IINA", short: "1.5.0")
        let result = HomebrewChecker.evaluate([iina], casks: casks, installed: ["iina": "1.4.4"])
        XCTAssertTrue(result.updates.isEmpty)
    }

    func testFallbackLinksHomepageAndIsNotAuthoritative() throws {
        let iina = app("com.colliderli.iina", name: "IINA", short: "1.4.0")
        let result = HomebrewChecker.evaluate([iina], casks: casks, installed: [:])
        XCTAssertEqual(try XCTUnwrap(result.updates.first).action, .openURL(URL(string: "https://iina.io")!))
        XCTAssertFalse(result.isCovered("com.colliderli.iina", by: .homebrew))
    }

    func testFallbackActions() {
        let selfUpdating = Cask(token: "google-chrome", version: "2", appNames: ["Google Chrome.app"],
                                downloadURL: URL(string: "https://dl.google.com/x.dmg"), autoUpdates: true)
        XCTAssertEqual(HomebrewChecker.action(for: selfUpdating, brewInstalled: false), .launchApp)
        XCTAssertEqual(HomebrewChecker.action(for: selfUpdating, brewInstalled: true), .brewUpgrade(token: "google-chrome"))
        let plain = Cask(token: "x", version: "2", appNames: ["X.app"], homepage: URL(string: "https://x.com"),
                         downloadURL: URL(string: "https://x.com/X.dmg"))
        XCTAssertEqual(HomebrewChecker.action(for: plain, brewInstalled: false), .openURL(URL(string: "https://x.com/X.dmg")!))
        XCTAssertEqual(UpdateStore.updatePage(for: "com.google.Chrome")?.absoluteString, "chrome://settings/help")
    }

    func testFallbackRejectsAmbiguousAndMismatchedMatches() {
        let apps = [
            app("com.x.Foo", name: "Foo", short: "26.0"),   // different numbering scheme
            app("com.x.Bar", name: "Bar", short: "1.0"),    // two casks ship Bar.app
            app("com.x.Nightly", name: "Nightly", short: "1.0"),
            app("com.wrong.iina", name: "IINA", short: "1.0"), // bundle ID disagrees with the cask
        ]
        XCTAssertTrue(HomebrewChecker.evaluate(apps, casks: casks, installed: [:]).updates.isEmpty)
    }

    func testCaskJSONParsing() throws {
        let json = """
        [{"token":"iina","version":"1.5.0","homepage":"https://iina.io/","url":"https://dl.iina.io/IINA.v1.5.0.dmg",
          "artifacts":[{"uninstall":[{"quit":"com.colliderli.iina"}]},{"app":["IINA.app"]},{"binary":["x"]}]},
         {"token":"cli-only","version":"1.0","artifacts":[{"binary":["tool"]}]}]
        """
        let casks = try HomebrewChecker.decode(Data(json.utf8))
        XCTAssertEqual(casks.count, 1)
        XCTAssertEqual(casks[0].appNames, ["IINA.app"])
        XCTAssertEqual(casks[0].bundleIdentifiers, ["com.colliderli.iina"])
    }
}

final class GitHubTests: XCTestCase {
    func testAutomaticRepositoryForOwnApps() {
        XCTAssertEqual(GitHubChecker.repository(for: app("com.erole.PowerBar", short: "0.1.0"), overrides: [:]), "erikrole/PowerBar")
        XCTAssertNil(GitHubChecker.repository(for: app("com.other.App", short: "1"), overrides: [:]))
        XCTAssertEqual(GitHubChecker.repository(for: app("com.other.App", short: "1"), overrides: ["com.other.App": "me/app"]), "me/app")
    }

    func testReleaseComparison() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/erikrole/PowerBar/releases/tag/v0.2.0","body":"Notes",
         "draft":false,"prerelease":false,"published_at":"2026-10-01T00:00:00Z",
         "assets":[{"name":"PowerBar-0.2.0.zip","browser_download_url":"https://github.com/x.zip"}]}
        """
        let release = try JSONDecoder.iso8601.decode(GitHubRelease.self, from: Data(json.utf8))
        let update = try XCTUnwrap(GitHubChecker.update(for: app("com.erole.PowerBar", short: "0.1.0"), release: release))
        XCTAssertEqual(update.version, "0.2.0")
        XCTAssertEqual(update.downloadURL?.lastPathComponent, "x.zip")
        XCTAssertNil(GitHubChecker.update(for: app("com.erole.PowerBar", short: "0.2.0"), release: release))
    }
}

final class ResolverTests: XCTestCase {
    private func update(_ id: String, _ source: UpdateSource, _ version: String) -> AvailableUpdate {
        AvailableUpdate(bundleIdentifier: id, source: source, version: version, comparableVersion: version,
                        releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil, action: .launchApp)
    }

    func testCoveringSourceOverridesFallbackHints() {
        let apps = [app("com.x.A", short: "1.0"), app("com.x.B", short: "1.0")]
        var result = CheckerResult()
        // A's own Sparkle feed says it's current; Homebrew's guess must not show.
        result.cover("com.x.A", by: .sparkle)
        result.updates = [update("com.x.A", .homebrew, "1.1"), update("com.x.B", .homebrew, "1.1")]
        let rows = UpdateResolver.resolve(apps: apps, result: result, ignoredApps: [], skippedVersions: [:])
        XCTAssertEqual(rows.map(\.app.bundleIdentifier), ["com.x.B"])
    }

    func testOneRowPerAppWithOtherSourcesNoted() {
        let apps = [app("com.x.A", short: "1.0")]
        var result = CheckerResult()
        result.cover("com.x.A", by: .sparkle)
        result.updates = [update("com.x.A", .homebrew, "1.1"), update("com.x.A", .sparkle, "1.1")]
        let rows = UpdateResolver.resolve(apps: apps, result: result, ignoredApps: [], skippedVersions: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.update.source, .sparkle)
        XCTAssertEqual(rows.first?.alsoReportedBy, [.homebrew])
    }

    func testIgnoredAndSkipped() {
        let apps = [app("com.x.A", short: "1.0"), app("com.x.B", short: "1.0")]
        var result = CheckerResult()
        result.updates = [update("com.x.A", .github, "1.1"), update("com.x.B", .github, "1.1")]
        let rows = UpdateResolver.resolve(apps: apps, result: result, ignoredApps: ["com.x.A"], skippedVersions: ["com.x.B": "1.1"])
        XCTAssertTrue(rows.isEmpty)
        let later = UpdateResolver.resolve(apps: apps, result: result, ignoredApps: ["com.x.A"], skippedVersions: ["com.x.B": "1.0.9"])
        XCTAssertEqual(later.count, 1)
    }
}

final class ScannerTests: XCTestCase {
    func testReadsPlistAndRejectsInsecureSchemes() throws {
        let made = try XCTUnwrap(AppScanner.makeApp(
            url: URL(filePath: "/Applications/Latest.app"),
            plist: ["CFBundleIdentifier": "com.max-langer.Latest", "CFBundleShortVersionString": "0.12",
                    "CFBundleVersion": 1348, "SUFeedURL": " https://max.codes/latest/update.xml "],
            hasReceipt: false
        ))
        XCTAssertEqual(made.buildVersion, "1348")
        XCTAssertFalse(made.hasSparkleEDKey)
        let keyed = AppScanner.makeApp(url: URL(filePath: "/x.app"), plist: ["CFBundleIdentifier": "a", "SUPublicEDKey": "abc="], hasReceipt: false)
        XCTAssertEqual(keyed?.hasSparkleEDKey, true)
        XCTAssertEqual(made.sparkleFeedURL?.host(), "max.codes")
        XCTAssertNil(AppScanner.makeApp(url: URL(filePath: "/x.app"), plist: [:], hasReceipt: false))
        let ftp = AppScanner.makeApp(url: URL(filePath: "/x.app"), plist: ["CFBundleIdentifier": "a", "SUFeedURL": "ftp://x"], hasReceipt: false)
        XCTAssertNil(ftp?.sparkleFeedURL)
    }

    func testAppleAppsAreHiddenUnlessFromTheStore() {
        XCTAssertTrue(AppScanner.isSystemApp(app("com.apple.Safari", short: "26")))
        XCTAssertFalse(AppScanner.isSystemApp(app("com.apple.Keynote", short: "15", receipt: true)))
    }

    func testBrewFailureSummary() {
        XCTAssertTrue(BrewRunner.summary(of: "==> Running installer\nsudo: a password is required", token: "zoom").contains("brew upgrade --cask zoom"))
        XCTAssertEqual(BrewRunner.summary(of: "x\nError: Download failed\n", token: "t"), "Error: Download failed")
    }
}
