import XCTest
@testable import UpPearCore

final class VersionTests: XCTestCase {
    func testLongVersionsAndRevisions() {
        XCTAssertTrue(Version(versionNumber: "1.2.0.1", buildNumber: nil) > Version(versionNumber: "1.2", buildNumber: nil))
        XCTAssertTrue(PkgVersion("2.14.1_2") > PkgVersion("2.14.1_1"))
        XCTAssertTrue(PkgVersion("2.14.2") > PkgVersion("2.14.1_9"))
    }
    func testLegacyPrereleaseFiltering() {
        XCTAssertTrue(isPreReleaseVersion("2.5rc1"))
        XCTAssertTrue(isPreReleaseVersion("3.0-beta.2"))
        XCTAssertFalse(isPreReleaseVersion("1.2026.10.13"))
    }
}
