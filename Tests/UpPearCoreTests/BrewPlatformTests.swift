// Codex 2026-10-14: regression coverage for exact platform selection and
// actual-bundle versions. No live Homebrew command or upgrade is run here.
import XCTest
@testable import UpPearCore

final class BrewPlatformTests: XCTestCase {
    private struct Client: HTTPClient {
        let data: Data
        func fetch(_ request: URLRequest) async throws -> Data { data }
    }
    private func package(appVersion: String? = nil, isCask: Bool = true) -> InstalledPackage {
        let app = appVersion.map {
            AppInfo(path: URL(fileURLWithPath: "/Applications/PlatformTest.app"), bundleIdentifier: "test.platform",
                    appName: "Platform Test", appVersion: $0)
        }
        return InstalledPackage(name: "platform-test", displayName: nil, version: "2.0", isCask: isCask,
            isPinned: false, tap: isCask ? "homebrew/cask" : "homebrew/core", tapRbPath: nil,
            app: app, brewExecutable: URL(fileURLWithPath: "/not/executed/brew"))
    }
    private func client(_ json: [String: Any]) throws -> Client {
        Client(data: try JSONSerialization.data(withJSONObject: json))
    }

    func testArmAndIntelUseOnlyTheirExactOSBranches() async throws {
        let json: [String: Any] = ["version": "9.0", "homepage": "https://example.com", "variations": [
            "arm64_new_os": ["version": "3.0"], "new_os": ["version": "1.0"],
            "arm64_previous_os": ["version": "8.0"]]]
        let arm = await HomebrewUpdateChecker.check(package: package(), client: try client(json), platformTag: "arm64_new_os")
        let intel = await HomebrewUpdateChecker.check(package: package(), client: try client(json), platformTag: "new_os")
        XCTAssertEqual(arm.state, .updateAvailable)
        XCTAssertEqual(arm.availableVersion, "3.0")
        XCTAssertEqual(intel.state, .current)
        XCTAssertEqual(intel.availableVersion, "1.0")
        XCTAssertEqual(arm.homepage?.host, "example.com")
    }
    func testNoExactBranchUsesBaseRatherThanNearestOS() async throws {
        let record = await HomebrewUpdateChecker.check(package: package(),
            client: try client(["version": "2.0", "variations": ["arm64_old_os": ["version": "8.0"]]]),
            platformTag: "arm64_new_os")
        XCTAssertEqual(record.state, .current)
        XCTAssertEqual(record.availableVersion, "2.0")
    }
    func testFormulaVariationPreservesRevisionComparison() async throws {
        let record = await HomebrewUpdateChecker.check(package: package(isCask: false),
            client: try client(["versions": ["stable": "2.0"], "revision": 0,
                "variations": ["arm64_new_os": ["revision": 1]]]), platformTag: "arm64_new_os")
        XCTAssertEqual(record.state, .updateAvailable)
        XCTAssertEqual(record.availableVersion, "2.0_1")
    }
    func testSelfUpdatedAppDoesNotRegressToReceiptVersion() async throws {
        let record = await HomebrewUpdateChecker.check(package: package(appVersion: "5.0"),
            client: try client(["version": "4.0", "variations": ["arm64_new_os": ["version": "3.0"]]]),
            platformTag: "arm64_new_os")
        XCTAssertEqual(record.installedVersion, "5.0")
        XCTAssertEqual(record.state, .current)
    }
    func testMalformedBranchAndMissingVersionFailRatherThanCurrent() async throws {
        let badBranch = await HomebrewUpdateChecker.check(package: package(),
            client: try client(["version": "9.0", "variations": ["arm64_new_os": "invalid"]]),
            platformTag: "arm64_new_os")
        let noVersion = await HomebrewUpdateChecker.check(package: package(), client: try client(["version": ""]))
        XCTAssertEqual(badBranch.state, .failed)
        XCTAssertEqual(noVersion.state, .failed)
    }
}
