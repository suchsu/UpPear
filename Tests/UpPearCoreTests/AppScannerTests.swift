// Codex 2026-10-14: synthetic local bundles only, no user application access.
import XCTest
@testable import UpPearCore

final class AppScannerTests: XCTestCase {
    func testMetadataFreeLauncherRemainsVisibleForManualChecking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpPear-scanner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Launcher.app")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let scan = AppScanner.scan(roots: [root])
        XCTAssertEqual(scan.apps.count, 1)
        XCTAssertEqual(scan.apps.first?.path.resolvingSymlinksInPath().path, path.resolvingSymlinksInPath().path)
        XCTAssertEqual(scan.apps.first?.appVersion, "")
        XCTAssertEqual(scan.apps.first?.isAppStore, false)
        XCTAssertNil(scan.apps.first?.feedURL)
        XCTAssertEqual(scan.warnings.count, 1)
    }
    func testStoreReceiptWinsAndNestedHelpersAreNotSeparateApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpPear-scanner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Store.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers/Helper.app"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.store", "CFBundleName": "Store",
            "CFBundleShortVersionString": "1.0", "SUFeedURL": "https://example.com/feed.xml"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("fixture".utf8).write(to: contents.appendingPathComponent("_MASReceipt/receipt"))
        let scan = AppScanner.scan(roots: [root])
        XCTAssertEqual(scan.apps.count, 1)
        XCTAssertEqual(scan.apps.first?.isAppStore, true)
        let record = UpdateRecord(app: scan.apps.first, source: .sparkle, state: .updateAvailable, detail: "test")
        guard case .appStore = ActionResolver.action(for: record) else { return XCTFail("receipt must own the channel") }
    }
}
