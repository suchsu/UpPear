// Modified for UpPear on 2026-10-13. Derived from Pearcleaner 5.4.3,
// commit c52695d90c43f60abd5cd10c363f2e122c65f191 by Alin Lupascu / alienator88.
// See LICENSE.md and docs/PROVENANCE.md for license and modification details.
// Extracted from Pearcleaner/Logic/Brew/HomebrewController.swift.
import Foundation

extension String {
    /// Strip all Homebrew revision suffixes and metadata from version string
    /// Used for both directory scan and API comparison to ensure consistent version matching
    /// Handles all common patterns: underscores, hyphens, commas, plus signs
    ///
    /// Keeps only alphanumeric characters and periods - strips from first suffix marker onward
    /// Then trims trailing non-alphanumeric characters (periods, etc.)
    ///
    /// Valid characters: digits (0-9), letters (a-z, A-Z), periods (.)
    /// Suffix markers: anything else (comma, plus, underscore, hyphen, etc.)
    ///
    /// Examples:
    ///   - "0.14.1,fc796f5b" → "0.14.1"
    ///   - "4.1.0+8404-main" → "4.1.0"
    ///   - "2.14.1_1" → "2.14.1"
    ///   - "8.27.2-4" → "8.27.2"
    ///   - "141.0.7390.122-1.1" → "141.0.7390.122"
    ///   - "1.0b5" → "1.0b5" (letters preserved)
    ///   - "1.2.3a" → "1.2.3a" (pre-release preserved)
    ///   - "v1.2.3" → "v1.2.3" (prefix preserved)
    ///   - "1.2." → "1.2" (trailing period removed)
    func stripBrewRevisionSuffix() -> String {
        var result = self

        // Find first character that's not alphanumeric or period (suffix marker)
        if let firstSuffixIndex = result.firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "." }) {
            result = String(result[..<firstSuffixIndex])
        }

        // Trim any trailing periods or other non-alphanumeric characters
        while let last = result.last, !last.isLetter && !last.isNumber {
            result.removeLast()
        }

        return result
    }
}

/// Homebrew-style package version combining version + revision
/// Mimics Homebrew's PkgVersion class for accurate formula outdated detection
/// Examples: "12.2.0_1" → (version: "12.2.0", revision: 1), "12.2.0" → (version: "12.2.0", revision: 0)
struct PkgVersion: Sendable, Comparable {
    let version: String   // Base version: "12.2.0"
    let revision: Int     // Revision: 1 (or 0 if none)

    /// Parse version string with optional revision suffix
    /// Examples: "12.2.0_1" → ("12.2.0", 1), "12.2.0" → ("12.2.0", 0)
    init(_ versionString: String) {
        // Regex pattern matches Homebrew's REGEX but with Swift-compatible anchors
        // Group 1: version (non-greedy), Group 2: optional revision after underscore
        // Use ^ and $ instead of Ruby's \A and \z
        let regex = /^(.+?)(?:_(\d+))?$/
        if let match = versionString.firstMatch(of: regex) {
            self.version = String(match.1)
            self.revision = match.2.map { Int($0) ?? 0 } ?? 0
        } else {
            // Fallback: treat entire string as version with revision 0
            self.version = versionString
            self.revision = 0
        }
    }

    /// Initialize with explicit version and revision
    init(version: String, revision: Int) {
        self.version = version
        self.revision = revision
    }

    /// Compare exactly like Homebrew: version first, then revision
    /// Ruby implementation:
    ///   version_comparison = (version <=> other.version)
    ///   return if version_comparison.nil?
    ///   version_comparison.nonzero? || revision <=> other.revision
    static func < (lhs: PkgVersion, rhs: PkgVersion) -> Bool {
        // Use existing Version struct for semantic comparison
        let lhsVer = Version(versionNumber: lhs.version, buildNumber: nil)
        let rhsVer = Version(versionNumber: rhs.version, buildNumber: nil)

        // If versions differ, use version comparison
        if lhsVer != rhsVer {
            return lhsVer < rhsVer
        }

        // Versions equal, compare revisions
        return lhs.revision < rhs.revision
    }

    static func == (lhs: PkgVersion, rhs: PkgVersion) -> Bool {
        let lhsVer = Version(versionNumber: lhs.version, buildNumber: nil)
        let rhsVer = Version(versionNumber: rhs.version, buildNumber: nil)
        return lhsVer == rhsVer && lhs.revision == rhs.revision
    }
}

