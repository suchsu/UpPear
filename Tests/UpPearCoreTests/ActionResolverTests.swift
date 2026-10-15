// Codex 2026-10-14: installation channel invariants. These tests inspect plans;
// they never open applications or run Homebrew.
import XCTest
@testable import UpPearCore

final class ActionResolverTests: XCTestCase {
    private let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    private func record(name: String = "test-tool", source: UpdateSource = .homebrewFormula,
                        pinned: Bool = false, state: CheckState = .updateAvailable,
                        app: AppInfo? = nil) -> UpdateRecord {
        UpdateRecord(app: app, source: source, state: state, detail: "test", name: name,
            packageName: name, brewExecutable: brew, isPinned: pinned)
    }
    func testStoreReceiptPreventsBrewAndSparkleInstallation() {
        let app = AppInfo(path: URL(fileURLWithPath: "/Applications/Store.app"), bundleIdentifier: "test.store",
            appName: "Store", appVersion: "1.0", isAppStore: true, adamID: 42,
            feedURL: URL(string: "https://example.com/feed.xml"))
        guard case .appStore(let url) = ActionResolver.action(for: record(source: .homebrewCask, app: app)) else {
            return XCTFail("A MAS receipt must always open the official store")
        }
        XCTAssertEqual(url.scheme, "macappstore")
        XCTAssertTrue(url.absoluteString.contains("/cn/app/id42"))
    }
    func testSparkleCaskOpensItsOriginalBundle() {
        let app = AppInfo(path: URL(fileURLWithPath: "/Applications/Player.app"), bundleIdentifier: "test.player",
            appName: "Player", appVersion: "1.0", feedURL: URL(string: "https://example.com/feed.xml"))
        guard case .openApplication(let path) = ActionResolver.action(for: record(source: .homebrewCask, app: app)) else {
            return XCTFail("A Sparkle cask must hand off to its own app")
        }
        XCTAssertEqual(path, app.path)
    }
    func testPinnedFormulaAndUnconfirmedResultCannotUpgrade() {
        if case .brewUpgrade = ActionResolver.action(for: record(pinned: true)) { XCTFail("must not unpin or upgrade") }
        if case .brewUpgrade = ActionResolver.action(for: record(state: .failed)) { XCTFail("failed check is not an upgrade") }
        if case .brewUpgrade = ActionResolver.action(for: record(state: .current)) { XCTFail("current package is not an upgrade") }
    }
    func testUpgradePlansHaveExplicitKindAndOnePackage() {
        for (source, kind) in [(UpdateSource.homebrewFormula, "--formula"), (.homebrewCask, "--cask")] {
            guard case .brewUpgrade(let plan) = ActionResolver.action(for: record(name: "owner/tap/tool@2", source: source)) else {
                return XCTFail("expected explicit upgrade plan")
            }
            XCTAssertEqual(plan.executable, brew)
            XCTAssertEqual(plan.arguments, ["upgrade", kind, "owner/tap/tool@2"])
        }
    }
    func testPackageMetadataCannotInjectFlagsShellOrFilePaths() {
        for name in ["--force", "tool;touch /tmp/anything", "/tmp/tool", "$(id)", "owner/tap/tool/extra", "tool\n--force"] {
            if case .brewUpgrade = ActionResolver.action(for: record(name: name)) { XCTFail("unsafe name accepted: \(name)") }
        }
    }
}
