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
}
