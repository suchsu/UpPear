import Foundation

/// A local preference for one release, independent of permanent ignore rules.
public struct SkippedUpdate: Codable, Sendable {
    public let name: String
    public let source: UpdateSource
    public let version: String
    public let build: String?

    public init?(record: UpdateRecord) {
        guard record.state == .updateAvailable,
              let version = record.availableVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        self.name = record.name
        self.source = record.source
        self.version = version
        self.build = record.availableBuild
    }

    public var displayVersion: String {
        if let build, build != version { return "\(version) (\(build))" }
        return version
    }

    public func matches(_ record: UpdateRecord) -> Bool {
        guard let version = record.availableVersion else { return false }
        let (saved, candidate) = normalizedPair(version: version, build: record.availableBuild)
        if let savedVersion = saved.versionNumber, let candidateVersion = candidate.versionNumber {
            guard Version(versionNumber: savedVersion, buildNumber: nil) == Version(versionNumber: candidateVersion, buildNumber: nil) else { return false }
        } else if saved.buildNumber == nil || candidate.buildNumber == nil { return false }
        if let build = saved.buildNumber, let candidateBuild = candidate.buildNumber {
            return Version(versionNumber: build, buildNumber: nil) == Version(versionNumber: candidateBuild, buildNumber: nil)
        }
        return true
    }

    // One source may append a build (2.0.100), while another supplies 2.0 (100).
    // Split only when the other source provides that exact build explicitly.
    private func normalizedPair(version: String, build: String?) -> (Version, Version) {
        let saved = Version(versionNumber: self.version, buildNumber: self.build)
        let candidate = Version(versionNumber: version, buildNumber: build)
        return (saved.sanitize(with: candidate), candidate.sanitize(with: saved))
    }

    fileprivate func isOlder(than version: String, build: String?) -> Bool {
        let (saved, candidate) = normalizedPair(version: version, build: build)
        if let savedVersion = saved.versionNumber, let candidateVersion = candidate.versionNumber {
            let installed = Version(versionNumber: savedVersion, buildNumber: nil)
            let available = Version(versionNumber: candidateVersion, buildNumber: nil)
            if available > installed { return true }
            if available < installed { return false }
        }
        if let build = candidate.buildNumber, let savedBuild = saved.buildNumber {
            return Version(versionNumber: build, buildNumber: nil) > Version(versionNumber: savedBuild, buildNumber: nil)
        }
        return false
    }

    fileprivate func isInstalled(in record: UpdateRecord) -> Bool {
        let (saved, candidate) = normalizedPair(version: record.installedVersion, build: record.installedBuild)
        if let installedVersion = candidate.versionNumber, let targetVersion = saved.versionNumber {
            let installed = Version(versionNumber: installedVersion, buildNumber: nil)
            let target = Version(versionNumber: targetVersion, buildNumber: nil)
            if installed > target { return true }
            guard installed == target else { return false }
            if saved.buildNumber == nil { return true }
        }
        guard let build = saved.buildNumber, let installedBuild = candidate.buildNumber else { return false }
        return Version(versionNumber: installedBuild, buildNumber: nil) >= Version(versionNumber: build, buildNumber: nil)
    }
}

public enum UpdateSkipPolicy {
    /// Apply after all providers have merged, so skip rules never stop checks.
    public static func applying(_ skipped: [String: SkippedUpdate], to records: [UpdateRecord]) -> [UpdateRecord] {
        records.map { record in
            guard record.state == .updateAvailable, let target = skipped[record.id], target.matches(record) else { return record }
            var result = record
            result.state = .versionSkipped
            return result
        }
    }

    /// Keep preferences through offline and incompatible checks. Retire them
    /// only after a confirmed newer update or the skipped release is installed.
    public static func retaining(_ skipped: [String: SkippedUpdate], after records: [UpdateRecord]) -> [String: SkippedUpdate] {
        let byID = Dictionary(grouping: records, by: \.id)
        return skipped.filter { id, target in
            guard let record = byID[id]?.first, [.current, .updateAvailable].contains(record.state) else { return true }
            if record.state == .updateAvailable, let version = record.availableVersion,
               target.isOlder(than: version, build: record.availableBuild) { return false }
            return !target.isInstalled(in: record)
        }
    }
}
