// Modified for UpPear on 2026-10-14 by WorkBuddy (接管续作).
// Covers Homebrew version string sanitisation and PkgVersion revision parsing/ordering.
// See docs/HANDOFF.md and docs/STATE.md "接管记录" for provenance.
import XCTest
@testable import UpPearCore

final class BrewVersionTests: XCTestCase {

    func testStripBrewRevisionSuffix() {
        XCTAssertEqual("0.14.1,fc796f5b".stripBrewRevisionSuffix(), "0.14.1")
        XCTAssertEqual("4.1.0+8404-main".stripBrewRevisionSuffix(), "4.1.0")
        XCTAssertEqual("2.14.1_1".stripBrewRevisionSuffix(), "2.14.1")
        XCTAssertEqual("8.27.2-4".stripBrewRevisionSuffix(), "8.27.2")
        XCTAssertEqual("141.0.7390.122-1.1".stripBrewRevisionSuffix(), "141.0.7390.122")
        XCTAssertEqual("1.0b5".stripBrewRevisionSuffix(), "1.0b5")
        XCTAssertEqual("v1.2.3".stripBrewRevisionSuffix(), "v1.2.3")
        XCTAssertEqual("1.2.".stripBrewRevisionSuffix(), "1.2")
    }

    func testPkgVersionParsing() {
        XCTAssertEqual(PkgVersion("12.2.0_1").version, "12.2.0")
        XCTAssertEqual(PkgVersion("12.2.0_1").revision, 1)
        XCTAssertEqual(PkgVersion("12.2.0").version, "12.2.0")
        XCTAssertEqual(PkgVersion("12.2.0").revision, 0)
    }

    func testPkgVersionRevisionOrdering() {
        XCTAssertTrue(PkgVersion("2.14.1_2") > PkgVersion("2.14.1_1"))
        XCTAssertTrue(PkgVersion("2.14.2") > PkgVersion("2.14.1_9"))
    }
}
