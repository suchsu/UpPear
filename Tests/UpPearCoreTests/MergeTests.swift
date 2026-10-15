// Modified for UpPear on 2026-10-14 by WorkBuddy (接管续作).
// Covers UpdateEngine.merge source routing, priority and de-duplication.
// See docs/HANDOFF.md and docs/STATE.md "接管记录" for provenance.
import XCTest
@testable import UpPearCore

final class MergeTests: XCTestCase {

    private func record(_ id: String, source: UpdateSource, state: CheckState,
                        available: String? = nil, name: String = "App") -> UpdateRecord {
        UpdateRecord(app: nil, source: source, state: state, detail: "",
                     id: id, name: name, installedVersion: "1.0",
                     availableVersion: available)
    }

    /// App Store receipt owns the channel: an appStore record must win over any other source.
    func testAppStoreWinsOverOtherSources() {
        let merged = UpdateEngine.merge(records: [
            record("com.x", source: .sparkle, state: .updateAvailable, available: "9.9"),
            record("com.x", source: .appStore, state: .current),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .appStore)
        XCTAssertEqual(merged.first?.state, .current)
    }

    /// When several non-AppStore sources report an update, the highest version wins.
    func testHighestAvailableVersionWins() {
        let merged = UpdateEngine.merge(records: [
            record("com.x", source: .homebrewCask, state: .updateAvailable, available: "1.5"),
            record("com.x", source: .homebrewFormula, state: .updateAvailable, available: "2.0"),
            record("com.x", source: .sparkle, state: .updateAvailable, available: "1.0"),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.availableVersion, "2.0")
    }

    /// On a version tie, Sparkle is preferred over Homebrew.
    func testSparklePreferredWhenVersionsTie() {
        let merged = UpdateEngine.merge(records: [
            record("com.x", source: .homebrewCask, state: .updateAvailable, available: "2.0"),
            record("com.x", source: .sparkle, state: .updateAvailable, available: "2.0"),
        ])
        XCTAssertEqual(merged.first?.source, .sparkle)
    }

    /// Fallback order when no update is available: current > skipped > failed/other.
    func testFallbackOrderCurrentThenSkippedThenFailed() {
        let current = UpdateEngine.merge(records: [
            record("com.x", source: .sparkle, state: .failed),
            record("com.x", source: .homebrewCask, state: .current),
        ])
        XCTAssertEqual(current.first?.state, .current)

        let skipped = UpdateEngine.merge(records: [
            record("com.x", source: .sparkle, state: .failed),
            record("com.x", source: .homebrewCask, state: .skipped),
        ])
        XCTAssertEqual(skipped.first?.state, .skipped)

        let failed = UpdateEngine.merge(records: [
            record("com.x", source: .sparkle, state: .failed),
            record("com.x", source: .homebrewCask, state: .unsupported),
        ])
        XCTAssertEqual(failed.first?.state, .failed)
    }

    /// Distinct identifiers must stay as separate records.
    func testDistinctIDsAreKeptSeparate() {
        let merged = UpdateEngine.merge(records: [
            record("a", source: .sparkle, state: .updateAvailable, available: "1.1"),
            record("b", source: .homebrewCask, state: .updateAvailable, available: "2.0"),
            record("c", source: .appStore, state: .current),
        ])
        XCTAssertEqual(merged.count, 3)
    }
}
