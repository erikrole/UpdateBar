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

    func testBuildIncreaseCannotRollTheReadableVersionBackwards() {
        let item = AppcastItem(version: "300", shortVersion: "1.0")
        XCTAssertNil(SparkleChecker.update(for: app("com.x.App", short: "2.0", build: "100"), item: item))
    }

    func testSystemBoundsAreInclusive() {
        let items = [
            AppcastItem(version: "2", shortVersion: "2.0", minimumSystemVersion: "14.0"),
            AppcastItem(version: "3", shortVersion: "3.0", minimumSystemVersion: "14.0.1"),
            AppcastItem(version: "4", shortVersion: "4.0", maximumSystemVersion: "14.0"),
            AppcastItem(version: "5", shortVersion: "5.0", maximumSystemVersion: "13.9"),
        ]
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let selected = SparkleChecker.newestCompatible(items, systemVersion: sonoma)
        XCTAssertEqual(selected?.version, "4")
    }

    func testDecoratedShortVersionWithSameBuildIsCurrent() {
        // Dia publishes "1.52.0 (88431)" while the app says "1.52.0".
        let item = AppcastItem(version: "88431", shortVersion: "1.52.0 (88431)")
        XCTAssertNil(SparkleChecker.update(for: app("company.thebrowser.dia", short: "1.52.0", build: "88431"), item: item))
        let newer = AppcastItem(version: "88500", shortVersion: "1.53.0 (88500)")
        XCTAssertNotNil(SparkleChecker.update(for: app("company.thebrowser.dia", short: "1.52.0", build: "88431"), item: newer))
    }
}

final class BetaTests: XCTestCase {
    private let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
    private let items = [
        AppcastItem(version: "210", shortVersion: "2.1"),
        AppcastItem(version: "220", shortVersion: "2.2b1", channel: "beta"),
    ]

    func testBetasOnlyWhenOptedIn() throws {
        XCTAssertEqual(SparkleChecker.newestCompatible(items, systemVersion: system)?.shortVersion, "2.1")
        let beta = try XCTUnwrap(SparkleChecker.newestCompatible(items, systemVersion: system, includeBetas: true))
        XCTAssertEqual(beta.shortVersion, "2.2b1")
        let update = try XCTUnwrap(SparkleChecker.update(for: app("com.x.App", short: "2.1", build: "210"), item: beta))
        XCTAssertEqual(update.channel, "beta")
    }

    func testFeedsThatTagStableReleases() throws {
        // OBS tags regular releases "stable" and betas "beta".
        let obs = [
            AppcastItem(version: "300", shortVersion: "33.0.0", channel: "beta"),
            AppcastItem(version: "200", shortVersion: "32.2.2", channel: "stable"),
        ]
        XCTAssertEqual(SparkleChecker.newestCompatible(obs, systemVersion: system)?.shortVersion, "32.2.2")
        let beta = try XCTUnwrap(SparkleChecker.newestCompatible(obs, systemVersion: system, includeBetas: true))
        XCTAssertEqual(SparkleChecker.update(for: app("com.obsproject.obs-studio", short: "32.2.2", build: "200"), item: beta)?.channel, "beta")
        XCTAssertNil(SparkleChecker.update(for: app("x", short: "32.2.1", build: "100"), item: obs[1])?.channel)
    }

    func testStableNewerThanOldBetaWins() {
        let mixed = items + [AppcastItem(version: "300", shortVersion: "3.0")]
        XCTAssertEqual(SparkleChecker.newestCompatible(mixed, systemVersion: system, includeBetas: true)?.shortVersion, "3.0")
    }
}

final class FormulaTests: XCTestCase {
    private let formulae = [
        FormulaChecker.Formula(name: "ffmpeg", oldNames: [], packageVersion: "9.0.2_1", summary: "Video tools", homepage: nil, isDisabled: false),
        FormulaChecker.Formula(name: "uv", oldNames: [], packageVersion: "0.13.0", summary: nil, homepage: nil, isDisabled: false),
        FormulaChecker.Formula(name: "pycparser", oldNames: [], packageVersion: "3.11", summary: nil, homepage: nil, isDisabled: false),
        FormulaChecker.Formula(name: "git", oldNames: [], packageVersion: "2.52.0", summary: nil, homepage: nil, isDisabled: false),
        FormulaChecker.Formula(name: "node@24", oldNames: ["node24"], packageVersion: "24.21.0_2", summary: nil, homepage: nil, isDisabled: false),
    ]

    func testFindsOutdatedAndRebuilds() {
        let installed: [String: FormulaChecker.Installed] = [
            "ffmpeg": .init(versions: ["9.0.2"], requested: true),
            "uv": .init(versions: ["0.12.18"], requested: true),
            "pycparser": .init(versions: ["3.0"], requested: false),
            "git": .init(versions: ["2.52.0"], requested: true),
            "node24": .init(versions: ["24.21.0_2"], requested: true),
        ]
        let updates = FormulaChecker.evaluate(installed: installed, formulae: formulae, pinned: [])
        XCTAssertEqual(updates.map(\.name), ["ffmpeg", "pycparser", "uv"])
        XCTAssertTrue(updates[0].isRebuild)
        XCTAssertFalse(updates[2].isRebuild)
        XCTAssertFalse(updates[1].requested)
    }

    func testOldNameMatchesAndDisabledFormulaIsSkipped() {
        let formulae = [
            FormulaChecker.Formula(name: "node", oldNames: ["node24"], packageVersion: "24.21.0", summary: nil, homepage: nil, isDisabled: false),
            FormulaChecker.Formula(name: "ffmpeg", oldNames: [], packageVersion: "9.0.2_1", summary: nil, homepage: nil, isDisabled: true),
        ]
        let installed: [String: FormulaChecker.Installed] = [
            "node24": .init(versions: ["24.0.0"], requested: true),
            "ffmpeg": .init(versions: ["8.0"], requested: true),
        ]
        let updates = FormulaChecker.evaluate(installed: installed, formulae: formulae, pinned: [])
        XCTAssertEqual(updates.map(\.name), ["node24"])
        XCTAssertEqual(updates.first?.installedVersion, "24.0.0")
    }

    func testNewestCellarVersionIsTheOneCompared() {
        let installed: [String: FormulaChecker.Installed] = [
            "uv": .init(versions: ["0.1.0", "HEAD-abc", "0.12.0"], requested: true),
        ]
        let updates = FormulaChecker.evaluate(installed: installed, formulae: formulae, pinned: [])
        XCTAssertEqual(updates.first?.installedVersion, "0.12.0")
        XCTAssertEqual(updates.first?.latestVersion, "0.13.0")
    }

    func testSkipsPinnedAndHeadBuilds() {
        let installed: [String: FormulaChecker.Installed] = [
            "uv": .init(versions: ["0.12.18"], requested: true),
            "ffmpeg": .init(versions: ["HEAD-abc123"], requested: true),
        ]
        XCTAssertTrue(FormulaChecker.evaluate(installed: installed, formulae: formulae, pinned: ["uv"]).isEmpty)
    }

    func testDecodesRevisionIntoPackageVersion() throws {
        let json = """
        [{"name":"ffmpeg","oldnames":[],"versions":{"stable":"9.0.2"},"revision":1,"desc":"Play, record, convert","homepage":"https://ffmpeg.org/"},
         {"name":"uv","versions":{"stable":"0.13.0"},"revision":0}]
        """
        let decoded = try FormulaChecker.decode(Data(json.utf8))
        XCTAssertEqual(decoded.map(\.packageVersion), ["9.0.2_1", "0.13.0"])
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
        let result = HomebrewChecker.evaluate([iina], casks: casks, installed: ["iina": [iina.url]])
        let update = try XCTUnwrap(result.updates.first)
        XCTAssertEqual(update.action, .brewUpgrade(token: "iina"))
        XCTAssertTrue(result.isCovered("com.colliderli.iina", by: .homebrew))
    }

    func testCaskThatMatchesTheBuildIsCurrent() {
        let iina = app("com.colliderli.iina", name: "IINA", short: "1.4.4", build: "1.5.0")
        let result = HomebrewChecker.evaluate([iina], casks: casks, installed: ["iina": [iina.url]])
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertTrue(result.isCovered("com.colliderli.iina", by: .homebrew))
    }

    func testFallbackMajorMustBeClose() {
        let casks = [
            Cask(token: "close", version: "6.0", appNames: ["Close.app"], homepage: URL(string: "https://close.example")),
            Cask(token: "far", version: "12.0", appNames: ["Far.app"], homepage: URL(string: "https://far.example")),
        ]
        let apps = [
            app("com.example.Close", name: "Close", short: "1.0"),
            app("com.example.Far", name: "Far", short: "1.0"),
        ]
        let result = HomebrewChecker.evaluate(apps, casks: casks, installed: [:])
        XCTAssertEqual(result.updates.map(\.bundleIdentifier), ["com.example.Close"])
    }

    /// Two different apps called Fetch: Erik's downloader (com.erole.Fetch) and Fetch Softworks' FTP client, whose cask
    /// installs the same Fetch.app. Suggesting it would replace one app with another.
    func testFallbackNeedsProofItIsTheSameApp() {
        let ftp = Cask(token: "fetch-app", version: "5.8.3", appNames: ["Fetch.app"],
                       footprintIDs: ["com.fetchsoftworks.Fetch"],
                       homepage: URL(string: "https://fetchsoftworks.com/fetch/"),
                       downloadURL: URL(string: "https://fetchsoftworks.com/fetch/download/Fetch_5.8.3.zip"))
        let downloader = app("com.erole.Fetch", name: "Fetch", short: "1.4.1")
        XCTAssertTrue(HomebrewChecker.evaluate([downloader], casks: [ftp], installed: [:]).updates.isEmpty)
        let theirs = app("com.fetchsoftworks.Fetch", name: "Fetch", short: "5.8.0")
        XCTAssertEqual(HomebrewChecker.evaluate([theirs], casks: [ftp], installed: [:]).updates.map(\.bundleIdentifier), ["com.fetchsoftworks.Fetch"])
        // No IDs at all: the vendor must show up in the cask's web address.
        let anonymous = Cask(token: "fetch-app", version: "5.8.3", appNames: ["Fetch.app"], homepage: URL(string: "https://fetchsoftworks.com/fetch/"))
        XCTAssertTrue(HomebrewChecker.evaluate([downloader], casks: [anonymous], installed: [:]).updates.isEmpty)
        // Installed by Homebrew is proof enough.
        XCTAssertFalse(HomebrewChecker.evaluate([theirs], casks: [anonymous], installed: ["fetch-app": [theirs.url]]).updates.isEmpty)
    }

    func testFootprintIDsComeFromZapPaths() {
        XCTAssertEqual(HomebrewChecker.footprintID(in: "~/Library/Preferences/com.fetchsoftworks.Fetch.plist"), "com.fetchsoftworks.Fetch")
        XCTAssertEqual(HomebrewChecker.footprintID(in: "~/Library/Saved Application State/com.fetchsoftworks.Fetch.savedState"), "com.fetchsoftworks.Fetch")
        XCTAssertEqual(HomebrewChecker.footprintID(in: "~/Library/Caches/com.apple.helpd/Generated/com.fetchsoftworks.fetch.help*"), "com.fetchsoftworks.fetch.help")
        XCTAssertNil(HomebrewChecker.footprintID(in: "~/Library/Application Support/Fetch"))
        XCTAssertNil(HomebrewChecker.footprintID(in: "~/Library/Logs/Fetch 5.8.log"))
    }

    func testSelfUpdatedCaskIsNotFlagged() {
        let iina = app("com.colliderli.iina", name: "IINA", short: "1.5.0")
        let result = HomebrewChecker.evaluate([iina], casks: casks, installed: ["iina": [iina.url]])
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
          "artifacts":[{"uninstall":[{"quit":"com.colliderli.iina"}]},{"app":["IINA.app"]},{"binary":["x"]},
                       {"zap":[{"trash":["~/Library/Preferences/com.colliderli.iina.plist","~/Library/Application Support/IINA"]}]}]},
         {"token":"cli-only","version":"1.0","artifacts":[{"binary":["tool"]}]}]
        """
        let casks = try HomebrewChecker.decode(Data(json.utf8))
        XCTAssertEqual(casks.count, 1)
        XCTAssertEqual(casks[0].appNames, ["IINA.app"])
        XCTAssertEqual(casks[0].bundleIdentifiers, ["com.colliderli.iina"])
        XCTAssertEqual(casks[0].footprintIDs, ["com.colliderli.iina"])
    }
}

final class GitHubTests: XCTestCase {
    func testAutomaticRepositoryForOwnApps() {
        XCTAssertEqual(GitHubChecker.repository(for: app("com.erole.PowerBar", short: "0.1.0"), overrides: [:]), "erikrole/PowerBar")
        XCTAssertNil(GitHubChecker.repository(for: app("com.other.App", short: "1"), overrides: [:]))
        XCTAssertEqual(GitHubChecker.repository(for: app("com.other.App", short: "1"), overrides: ["com.other.App": "me/app"]), "me/app")
        XCTAssertEqual(GitHubChecker.repositories(for: app("com.erole.Fetch", short: "1.4.1"), overrides: [:]), ["erikrole/Fetch", "erikrole/fetch-releases"])
        XCTAssertEqual(GitHubChecker.repositories(for: app("com.erole.Fetch", short: "1"), overrides: ["com.erole.Fetch": "me/fetch"]), ["me/fetch"])
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

    func testDraftAndPrereleaseAreNotUpdates() {
        let page = URL(string: "https://github.com/erikrole/PowerBar/releases/tag/v2.0.0")!
        let installed = app("com.erole.PowerBar", short: "1.0.0")
        let draft = GitHubRelease(tagName: "v2.0.0", htmlURL: page, body: nil, draft: true, prerelease: false, publishedAt: nil, assets: [])
        let preview = GitHubRelease(tagName: "v2.0.0", htmlURL: page, body: nil, draft: false, prerelease: true, publishedAt: nil, assets: [])
        XCTAssertNil(GitHubChecker.update(for: installed, release: draft))
        XCTAssertNil(GitHubChecker.update(for: installed, release: preview))
    }
}

final class ResolverTests: XCTestCase {
    private func update(_ id: String, _ source: UpdateSource, _ version: String) -> AvailableUpdate {
        AvailableUpdate(bundleIdentifier: id, source: source, version: version, comparableVersion: version,
                        releaseDate: nil, releaseNotes: nil, releaseNotesURL: nil, downloadURL: nil, action: .launchApp)
    }

    func testAppStoreOutranksASparkleUpdate() {
        let apps = [app("com.x.A", short: "1.0")]
        var result = CheckerResult()
        result.cover("com.x.A", by: .appStore)
        result.cover("com.x.A", by: .sparkle)
        result.updates = [update("com.x.A", .sparkle, "9.0"), update("com.x.A", .appStore, "1.1")]
        let rows = UpdateResolver.resolve(apps: apps, result: result, ignoredApps: [], skippedVersions: [:])
        XCTAssertEqual(rows.first?.update.source, .appStore)
        XCTAssertEqual(rows.first?.update.version, "1.1")
        XCTAssertEqual(rows.first?.alsoReportedBy, [.sparkle])
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
        XCTAssertTrue(BrewRunner.summary(of: "==> Running installer\nsudo: a password is required", command: "brew upgrade --cask zoom").contains("brew upgrade --cask zoom"))
        XCTAssertEqual(BrewRunner.summary(of: "x\nError: Download failed\n", command: "brew upgrade"), "Error: Download failed")
    }

    func testOwnReleaseWithDMGInstallsInPlace() throws {
        let json = #"{"tag_name":"v2.0","html_url":"https://github.com/erikrole/x-releases/releases/v2.0","body":null,"draft":false,"prerelease":false,"published_at":null,"assets":[{"name":"X.dmg","browser_download_url":"https://github.com/erikrole/x-releases/releases/download/v2.0/X.dmg"}]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        let installed = InstalledApp(bundleIdentifier: "com.erole.X", name: "X", url: URL(filePath: "/Applications/X.app"), shortVersion: "1.0", buildVersion: "1", sparkleFeedURL: nil, hasAppStoreReceipt: false)
        let own = try XCTUnwrap(GitHubChecker.update(for: installed, release: release, repository: "erikrole/x-releases"))
        XCTAssertEqual(own.action, .dmgInstall(URL(string: "https://github.com/erikrole/x-releases/releases/download/v2.0/X.dmg")!))
        let other = try XCTUnwrap(GitHubChecker.update(for: installed, release: release, repository: "someone/x"))
        XCTAssertEqual(other.action, .openURL(URL(string: "https://github.com/erikrole/x-releases/releases/v2.0")!))
    }
}
