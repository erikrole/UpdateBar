import Foundation

/// Where one package is in a running `brew upgrade`.
enum BrewStage: Equatable, Sendable {
    case queued
    case downloading
    case installing
    case done
    case failed

    var label: String {
        switch self {
        case .queued: "Waiting"
        case .downloading: "Downloading"
        case .installing: "Installing"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    var isActive: Bool { self == .downloading || self == .installing }
}

/// Reads `brew upgrade` output line by line and reports which package moved to
/// which stage. Brew runs with `HOMEBREW_NO_COLOR` and `HOMEBREW_NO_EMOJI`, so the
/// lines are plain text.
enum BrewOutputParser {
    struct Event: Equatable, Sendable {
        let names: [String]
        let stage: BrewStage
    }

    static func event(for rawLine: String) -> Event? {
        let line = stripANSI(rawLine).trimmingCharacters(in: .whitespaces)

        // "==> Fetching downloads for: ffmpeg, uv and yt-dlp"
        if let list = line.value(after: "==> Fetching downloads for:") {
            let names = list
                .replacingOccurrences(of: " and ", with: ", ")
                .split(separator: ",")
                .map { shortName(String($0)) }
                .filter { !$0.isEmpty }
            return names.isEmpty ? nil : Event(names: names, stage: .downloading)
        }
        // "==> Upgrading uv" (the per-package heading, not "Upgrading 3 outdated packages:")
        if let name = line.value(after: "==> Upgrading "), !name.hasSuffix(":"), !name.contains(" ") {
            return Event(names: [shortName(name)], stage: .installing)
        }
        // "==> Pouring uv--0.13.0.arm64_tahoe.bottle.tar.gz"
        if let file = line.value(after: "==> Pouring "), let name = file.components(separatedBy: "--").first {
            return Event(names: [shortName(name)], stage: .installing)
        }
        // "/opt/homebrew/Cellar/uv/0.13.0: 12 files, 41.2MB"
        if line.contains("/Cellar/"), line.contains(": "),
           let path = line.components(separatedBy: ": ").first {
            let parts = path.components(separatedBy: "/Cellar/")
            if parts.count == 2, let name = parts[1].split(separator: "/").first {
                return Event(names: [String(name)], stage: .done)
            }
        }
        // "google-chrome was successfully upgraded!"
        if line.hasSuffix(" was successfully upgraded!") {
            return Event(names: [shortName(String(line.dropLast(" was successfully upgraded!".count)))], stage: .done)
        }
        // "Error: ffmpeg: Failed to download resource" / "Error: Cask 'docker' is not installed."
        if line.hasPrefix("Error:") {
            let rest = String(line.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("Cask '"), let end = rest.dropFirst("Cask '".count).firstIndex(of: "'") {
                let name = String(rest[rest.index(rest.startIndex, offsetBy: "Cask '".count)..<end])
                return name.isEmpty ? nil : Event(names: [shortName(name)], stage: .failed)
            }
            if let name = rest.split(separator: ":", maxSplits: 1).first {
                let token = shortName(String(name))
                let allowed = token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "@" || $0 == "+" || $0 == "_" }
                if !token.isEmpty, !token.contains(" "), allowed {
                    return Event(names: [token], stage: .failed)
                }
            }
        }
        return nil
    }

    /// "homebrew/core/uv" → "uv".
    private static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

/// Progress of one Upgrade-all (or single) run, for the tools section header.
struct BrewRunProgress: Equatable, Sendable {
    var stages: [String: BrewStage]
    var order: [String]

    init(names: [String]) {
        order = names
        stages = Dictionary(uniqueKeysWithValues: names.map { ($0, .queued) })
    }

    mutating func apply(_ event: BrewOutputParser.Event) {
        for name in event.names where stages[name] != nil {
            // A finished or failed package stays that way if later lines mention it.
            if stages[name] == .done || stages[name] == .failed { continue }
            stages[name] = event.stage
        }
    }

    /// Packages brew did not finish when the run stops short.
    mutating func markUnfinishedFailed() {
        for name in order where stages[name] != .done {
            stages[name] = .failed
        }
    }

    var total: Int { order.count }
    var finished: Int { stages.values.filter { $0 == .done }.count }
    var fraction: Double { total == 0 ? 0 : Double(finished) / Double(total) }

    /// The package brew is working on right now, preferring one being installed.
    var current: (name: String, stage: BrewStage)? {
        if let name = order.first(where: { stages[$0] == .installing }) { return (name, .installing) }
        if let name = order.first(where: { stages[$0] == .downloading }) { return (name, .downloading) }
        return nil
    }

    var summary: String {
        guard let current else {
            return finished == total ? "Finishing up…" : "Starting brew…"
        }
        return "\(current.stage.label) \(current.name) · \(finished) of \(total) done"
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
