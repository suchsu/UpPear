// Modified for UpPear on 2026-10-14 by WorkBuddy (接管续作).
// Covers App Store identity validation, region fallback and failure/current states
// with an injected HTTP client. See docs/STATE.md "接管记录" for provenance.
import XCTest
@testable import UpPearCore

private func storeJSON(bundleID: String, version: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "resultCount": 1,
        "results": [["bundleId": bundleID, "trackId": 42, "version": version] as [String: Any]]
    ] as [String: Any])
}

private func emptyStoreJSON() -> Data {
    try! JSONSerialization.data(withJSONObject: ["resultCount": 0, "results": [Any]()] as [String: Any])
}

final class AppStoreCheckerTests: XCTestCase {

    private final class MockClient: HTTPClient, @unchecked Sendable {
        // AppStoreUpdateChecker issues requests sequentially, so no lock is required.
        private(set) var regions: [String] = []
        private let responder: @Sendable (String) throws -> Data
        init(responder: @escaping @Sendable (String) throws -> Data) { self.responder = responder }

        func fetch(_ request: URLRequest) async throws -> Data {
            let region = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "country" })?.value ?? ""
            regions.append(region)
            return try responder(region)
        }
    }

    private func app(isAppStore: Bool = true, adamID: UInt64? = 42, version: String = "1.0") -> AppInfo {
        AppInfo(path: URL(fileURLWithPath: "/Applications/Test.app"),
                bundleIdentifier: "com.example.test", appName: "Test",
                appVersion: version, isAppStore: isAppStore, adamID: adamID)
    }

    func testNonAppStoreIsUnsupported() async {
        let data = emptyStoreJSON()
        let client = MockClient { _ in data }
        let record = await AppStoreUpdateChecker.check(app: app(isAppStore: false), primaryRegion: "CN", client: client)
        XCTAssertEqual(record.state, .unsupported)
        XCTAssertTrue(client.regions.isEmpty)
    }

    func testUpdateAvailableWhenRemoteNewer() async {
        let data = storeJSON(bundleID: "com.example.test", version: "2.0")
        let client = MockClient { _ in data }
        let record = await AppStoreUpdateChecker.check(app: app(version: "1.0"), primaryRegion: "CN", client: client)
        XCTAssertEqual(record.state, .updateAvailable)
        XCTAssertEqual(record.availableVersion, "2.0")
    }

    func testCurrentWhenRemoteNotNewer() async {
        let data = storeJSON(bundleID: "com.example.test", version: "1.0")
        let client = MockClient { _ in data }
        let record = await AppStoreUpdateChecker.check(app: app(version: "1.0"), primaryRegion: "CN", client: client)
        XCTAssertEqual(record.state, .current)
    }

    // A numeric (adamID) lookup that returns a different bundle id must be rejected.
    func testBundleIDMismatchIsRejected() async {
        let data = storeJSON(bundleID: "com.other.app", version: "9.9")
        let client = MockClient { _ in data }
        let record = await AppStoreUpdateChecker.check(app: app(), primaryRegion: "CN", client: client)
        XCTAssertEqual(record.state, .unsupported)
    }

    func testRegionFallbackRecordsFoundRegion() async {
        let empty = emptyStoreJSON()
        let hit = storeJSON(bundleID: "com.example.test", version: "3.0")
        let client = MockClient { region in region == "CN" ? empty : hit }
        let record = await AppStoreUpdateChecker.check(app: app(adamID: nil, version: "1.0"), primaryRegion: "CN", client: client)
        XCTAssertEqual(record.state, .updateAvailable)
        XCTAssertEqual(record.foundInRegion, "US")
    }

    func testNetworkErrorIsFailed() async {
        struct Boom: Error {}
        let client = MockClient { _ in throw Boom() }
        let record = await AppStoreUpdateChecker.check(app: app(), primaryRegion: "CN", client: client)
        XCTAssertEqual(record.state, .failed)
    }
}
