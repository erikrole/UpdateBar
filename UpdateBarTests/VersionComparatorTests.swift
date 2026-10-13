import XCTest
@testable import UpdateBar

final class VersionComparatorTests: XCTestCase {
    func testNumericOrdering() {
        XCTAssertTrue(VersionComparator.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(VersionComparator.isNewer("2.0.1", than: "2.0"))
        XCTAssertFalse(VersionComparator.isNewer("1.9", than: "1.10"))
    }

    func testTrailingZerosAreEqual() {
        XCTAssertEqual(VersionComparator.compare("2.0.0", to: "2.0"), .same)
        XCTAssertEqual(VersionComparator.compare("2.0", to: "2.0.0"), .same)
    }

    func testPrereleasesSortBeforeRelease() {
        XCTAssertEqual(VersionComparator.compare("1.0b2", to: "1.0"), .older)
        XCTAssertEqual(VersionComparator.compare("1.0", to: "1.0b2"), .newer)
        XCTAssertEqual(VersionComparator.compare("1.0rc1", to: "1.0b5"), .newer)
        XCTAssertEqual(VersionComparator.compare("2.0-beta.3", to: "2.0-beta.2"), .newer)
    }

    func testNormalizesPrefixesAndHomebrewBuilds() {
        XCTAssertEqual(VersionComparator.compare("v1.4.0", to: "1.4"), .same)
        XCTAssertEqual(VersionComparator.compare("1.5.0,1234", to: "1.5.0"), .same)
        XCTAssertTrue(VersionComparator.isNewer("1.5.0,1234", than: "1.4.4"))
    }

    func testBuildNumbers() {
        XCTAssertTrue(VersionComparator.isNewer("1349", than: "1348"))
        XCTAssertFalse(VersionComparator.isNewer("1348", than: "1348"))
    }

    func testPrereleaseRanksAndDottedIdentifiers() {
        XCTAssertEqual(VersionComparator.compare("1.0dev1", to: "1.0alpha1"), .older)
        XCTAssertEqual(VersionComparator.compare("1.0a2", to: "1.0b1"), .older)
        XCTAssertEqual(VersionComparator.compare("1.0beta2", to: "1.0rc1"), .older)
        XCTAssertEqual(VersionComparator.compare("1.0rc1", to: "1.0"), .older)
        XCTAssertEqual(VersionComparator.compare("2.0-beta.10", to: "2.0-beta.2"), .newer)
        XCTAssertEqual(VersionComparator.compare("1.1", to: "1.beta"), .newer)
    }

    func testSeparatorsWhitespaceAndRebuildSuffixes() {
        XCTAssertEqual(VersionComparator.compare("1.2", to: "1-2"), .same)
        XCTAssertEqual(VersionComparator.compare("  V1.2.3 ", to: "1.2.3"), .same)
        XCTAssertEqual(VersionComparator.compare("v1", to: "1"), .same)
        XCTAssertEqual(VersionComparator.compare("version1", to: "1"), .older)
        XCTAssertEqual(VersionComparator.compare("9.0.2_1", to: "9.0.2"), .newer)
        XCTAssertEqual(VersionComparator.compare("1.10.0", to: "1.10"), .same)
        XCTAssertEqual(VersionComparator.compare("1.2.3", to: "1.2.3"), .same)
    }
}
