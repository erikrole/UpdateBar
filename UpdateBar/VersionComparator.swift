import Foundation

/// Compares version strings the way people expect: "1.10" > "1.9", "2.0" == "2.0.0",
/// "1.0b2" < "1.0". Letters, digits and separators are split into chunks and
/// compared chunk by chunk.
enum VersionComparator {
    enum Order { case older, same, newer }

    /// Returns how `candidate` relates to `installed`.
    static func compare(_ candidate: String, to installed: String) -> Order {
        let lhs = chunks(of: normalize(candidate))
        let rhs = chunks(of: normalize(installed))
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            guard index < lhs.count, index < rhs.count else { break }
            if let order = compare(lhs[index], rhs[index]) { return order }
        }
        if lhs.count == rhs.count { return .same }

        // One version has extra chunks. Trailing zeros don't count ("2.0.0" == "2.0");
        // a trailing number makes it newer ("1.0.1"), trailing text marks a
        // pre-release and makes it older ("1.0b1" < "1.0").
        let longerIsCandidate = lhs.count > rhs.count
        let remainder = (longerIsCandidate ? lhs : rhs).dropFirst(min(lhs.count, rhs.count))
        guard let first = remainder.first(where: { $0 != .number(0) }) else { return .same }
        let longerIsNewer = !isPrerelease(first)
        return longerIsNewer == longerIsCandidate ? .newer : .older
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, to: installed) == .newer
    }

    // MARK: - Internals

    private enum Chunk: Equatable {
        case number(Int)
        case text(String)
        case separator
    }

    /// Strips a leading "v", Homebrew's ",build" suffix and whitespace.
    static func normalize(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = value.firstIndex(of: ",") { value = String(value[..<comma]) }
        if value.first == "v" || value.first == "V", value.dropFirst().first?.isNumber == true {
            value.removeFirst()
        }
        return value
    }

    private static func chunks(of version: String) -> [Chunk] {
        var result: [Chunk] = []
        var buffer = ""
        var bufferIsNumber = false

        func flush() {
            guard !buffer.isEmpty else { return }
            if bufferIsNumber, let number = Int(buffer.prefix(18)) {
                result.append(.number(number))
            } else {
                result.append(.text(buffer.lowercased()))
            }
            buffer = ""
        }

        for character in version {
            if character.isNumber {
                if !bufferIsNumber { flush() }
                bufferIsNumber = true
                buffer.append(character)
            } else if character.isLetter {
                if bufferIsNumber { flush() }
                bufferIsNumber = false
                buffer.append(character)
            } else {
                flush()
                result.append(.separator)
            }
        }
        flush()
        // Separators only matter for alignment; drop them so "1.0" and "1-0" agree.
        return result.filter { $0 != .separator }
    }

    private static func compare(_ left: Chunk, _ right: Chunk) -> Order? {
        switch (left, right) {
        case let (.number(a), .number(b)):
            return a == b ? nil : (a > b ? .newer : .older)
        case let (.text(a), .text(b)):
            if a == b { return nil }
            return prereleaseRank(a) > prereleaseRank(b) ? .newer
                : prereleaseRank(a) < prereleaseRank(b) ? .older
                : (a > b ? .newer : .older)
        case (.number, .text):
            // "1.1" vs "1.b": a number beats a pre-release tag.
            return .newer
        case (.text, .number):
            return .older
        default:
            return nil
        }
    }

    private static func prereleaseRank(_ text: String) -> Int {
        switch text {
        case "dev", "d": 0
        case "alpha", "a": 1
        case "beta", "b": 2
        case "rc", "c": 3
        default: 4
        }
    }

    private static func isPrerelease(_ chunk: Chunk) -> Bool {
        if case .text = chunk { return true }
        return false
    }
}
