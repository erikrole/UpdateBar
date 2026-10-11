import Foundation

/// An application bundle found on disk.
struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL
    /// `CFBundleShortVersionString`, the version people read.
    let shortVersion: String?
    /// `CFBundleVersion`, the build number Sparkle compares against.
    let buildVersion: String?
    let sparkleFeedURL: URL?
    let hasAppStoreReceipt: Bool
    /// Whether the app ships a Sparkle EdDSA key, which in-place installs require so
    /// every download is verified against the developer's own signature.
    var hasSparkleEDKey = false

    var id: String { bundleIdentifier }

    /// The best version string to show and compare when a source only publishes one.
    var displayVersion: String {
        shortVersion ?? buildVersion ?? "?"
    }
}

/// Where an update was found. Ordered by how authoritative the source is for an app.
enum UpdateSource: String, Codable, CaseIterable, Sendable, Comparable {
    case appStore
    case sparkle
    case homebrew
    case github

    var label: String {
        switch self {
        case .appStore: "App Store"
        case .sparkle: "Sparkle"
        case .homebrew: "Homebrew"
        case .github: "GitHub"
        }
    }

    var symbolName: String {
        switch self {
        case .appStore: "bag"
        case .sparkle: "sparkles"
        case .homebrew: "mug"
        case .github: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var rank: Int {
        switch self {
        case .appStore: 0
        case .sparkle: 1
        case .homebrew: 2
        case .github: 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// How UpdateBar can act on an update.
enum UpdateAction: Hashable, Sendable {
    /// `brew upgrade --cask <token>`, run as the current user.
    case brewUpgrade(token: String)
    /// Open the App Store's Updates page.
    case openAppStore
    /// Download, verify and install through Sparkle without opening the app.
    case sparkleInstall
    /// Launch the app so its own updater takes over.
    case launchApp
    /// Open a download or release page in the browser.
    case openURL(URL)
}

/// A newer version published by one source for one installed app.
struct AvailableUpdate: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let source: UpdateSource
    /// The version people read, e.g. "2.4.1".
    let version: String
    /// The version that was compared against the installed app; may be a build number.
    let comparableVersion: String
    let releaseDate: Date?
    let releaseNotes: String?
    let releaseNotesURL: URL?
    let downloadURL: URL?
    let action: UpdateAction

    var id: String { "\(bundleIdentifier)|\(source.rawValue)|\(version)" }
}

/// One row in the menu: an installed app and the single update chosen for it.
struct AppUpdate: Identifiable, Hashable, Sendable {
    let app: InstalledApp
    let update: AvailableUpdate
    /// Other sources that also reported a newer version, kept for the detail view.
    let alsoReportedBy: [UpdateSource]

    var id: String { app.bundleIdentifier }
}

/// Whether a source could not answer for one app; shown quietly, never as an update.
struct CheckFailure: Identifiable, Hashable, Sendable {
    let source: UpdateSource
    let subject: String
    let message: String

    var id: String { "\(source.rawValue)|\(subject)" }
}
