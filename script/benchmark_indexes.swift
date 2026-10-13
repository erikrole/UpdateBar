import Foundation

// The benchmark compiles only the checker sources; no updater process is run.
enum BrewRunner { static let brewPath: String? = nil }

@main
struct IndexBenchmark {
    static func main() async throws {
        let source = URL.applicationSupportDirectory.appending(path: "UpdateBar")
        let fixture = URL(filePath: CommandLine.arguments[1])
        let caskData = try Data(contentsOf: source.appending(path: "cask.json"))
        let formulaData = try Data(contentsOf: source.appending(path: "formula.json"))
        try caskData.write(to: fixture.appending(path: "cask.json"))
        try formulaData.write(to: fixture.appending(path: "formula.json"))
        print("Input: \(caskData.count + formulaData.count) bytes")

        let uncachedStart = ContinuousClock.now
        for _ in 0..<3 {
            let casks = try HomebrewChecker.decode(caskData)
            let formulae = try FormulaChecker.decode(formulaData)
            print("Decoded: \(casks.count) casks; \(formulae.count) formulae")
        }
        print("Three uncached decodes: \(uncachedStart.duration(to: .now))")

        let casks = DecodedIndex<[Cask]>()
        let formulae = DecodedIndex<[FormulaChecker.Formula]>()
        // Fresh local fixtures ensure this benchmark never fetches an index.
        let caskIndex = IndexCache(remoteURL: URL(string: "https://example.invalid/cask")!, fileURL: fixture.appending(path: "cask.json"))
        let formulaIndex = IndexCache(remoteURL: URL(string: "https://example.invalid/formula")!, fileURL: fixture.appending(path: "formula.json"))
        let cold = ContinuousClock.now
        _ = try await casks.load(from: caskIndex) { try HomebrewChecker.decode($0) }
        _ = try await formulae.load(from: formulaIndex) { try FormulaChecker.decode($0) }
        print("Cold cache load: \(cold.duration(to: .now))")
        let warm = ContinuousClock.now
        for _ in 0..<3 {
            let c = try await casks.load(from: caskIndex) { try HomebrewChecker.decode($0) }.value
            let f = try await formulae.load(from: formulaIndex) { try FormulaChecker.decode($0) }.value
            print("Cached: \(c.count) casks; \(f.count) formulae")
        }
        print("Three warm loads: \(warm.duration(to: .now))")
    }
}
