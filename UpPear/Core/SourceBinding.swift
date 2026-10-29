import Foundation

public struct GitHubRepository: Codable, Hashable, Sendable {
    public let owner: String
    public let name: String
    public var slug: String { owner + "/" + name }
    public var url: URL { URL(string: "https://github.com/\(slug)")! }

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if let url = URL(string: text), url.scheme != nil {
            guard url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil else { throw SourceError.invalidRepository }
            parts = url.pathComponents.filter { $0 != "/" }
        } else { parts = text.components(separatedBy: "/") }
        guard parts.count >= 2, parts[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil else {
            throw SourceError.invalidRepository
        }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard repo != ".", repo != "..", repo.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil else {
            throw SourceError.invalidRepository
        }
        owner = parts[0]; name = repo
    }
}

public enum GitHubReleaseStream: String, Codable, CaseIterable, Sendable {
    case stable, includingPrereleases, prereleasesOnly
    public var title: String {
        switch self {
        case .stable: "正式版"
        case .includingPrereleases: "包含预发布"
        case .prereleasesOnly: "仅预发布"
        }
    }
}

public struct GitHubSourceBinding: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var installationPath: String
    public var bundleIdentifier: String
    public var installationFileID: String?
    public var teamIdentifier: String?
    public var repository: GitHubRepository
    public var repositoryID: Int?
    public var stream: GitHubReleaseStream = .stable
    public var branch: String = ""
    public var tagPrefix: String = ""
    public var pinnedTag: String = ""
    public var requiredManifestAsset: String?
    public var assetPattern: String = ""
    // A user-provided baseline is valid only for the exact installed version/build.
    public var installedReleaseVersion: String = ""
    public var baselineAppVersion: String
    public var baselineAppBuild: String?
    public var evidence: String
    public var selectedAt = Date()
    public var manuallySelected: Bool

    public init(app: AppInfo, repository: GitHubRepository, evidence: String, manuallySelected: Bool = true) {
        installationPath = app.id; bundleIdentifier = app.bundleIdentifier
        installationFileID = app.installationFileID; teamIdentifier = app.teamIdentifier
        self.repository = repository; self.evidence = evidence; self.manuallySelected = manuallySelected
        baselineAppVersion = app.appVersion; baselineAppBuild = app.appBuildNumber
    }

    public func matchesIdentity(_ app: AppInfo) -> Bool {
        app.bundleIdentifier == bundleIdentifier && app.teamIdentifier == teamIdentifier
    }

    public static func resolve(_ bindings: [Self], apps: [AppInfo]) -> [String: Self] {
        var result: [String: Self] = [:]
        for app in apps {
            let exact = bindings.filter { $0.installationPath == app.id && $0.matchesIdentity(app) }
            if exact.count == 1 {
                var binding = exact[0]
                // Updaters replace the bundle directory. Refresh its file ID
                // before a later move, while keeping the user's source rules.
                binding.installationFileID = app.installationFileID
                result[app.id] = binding; continue
            }
            // File identity survives a move. Do not guess by bundle ID: two
            // installations of the same app may intentionally use different forks.
            let moved = bindings.filter {
                $0.installationFileID != nil && $0.installationFileID == app.installationFileID && $0.matchesIdentity(app)
            }
            if moved.count == 1, apps.filter({ $0.installationFileID == app.installationFileID }).count == 1 {
                var binding = moved[0]; binding.installationPath = app.id; result[app.id] = binding
            }
        }
        return result
    }

    static func requiresRelinking(_ bindings: [Self], app: AppInfo) -> Bool {
        bindings.contains {
            $0.matchesIdentity(app) && $0.installationPath != app.id &&
            !FileManager.default.fileExists(atPath: $0.installationPath)
        }
    }

    public func validate() throws {
        for ref in [branch, pinnedTag] where !ref.isEmpty {
            guard ref.utf8.count <= 200, !ref.hasPrefix("-"), !ref.contains(".."),
                  ref.rangeOfCharacter(from: .controlCharacters) == nil else { throw SourceError.invalidRule }
        }
        guard assetPattern.count <= 240, tagPrefix.count <= 100,
              !assetPattern.contains("/"), !assetPattern.contains("\\"),
              installedReleaseVersion.isEmpty || ReleaseVersion.normalized(installedReleaseVersion, prefix: tagPrefix) != nil else {
            throw SourceError.invalidRule
        }
    }
}

public struct GitHubUpdateInfo: Codable, Sendable {
    public var binding: GitHubSourceBinding
    public var releaseTag: String?
    public var assetName: String?
    public var assetURL: URL?
    public var candidateAssets: [String]?
    public var checkedAt: Date
    public var identityNote: String
}

public struct SourceCandidate: Identifiable, Sendable {
    public var id: String { repository.slug.lowercased() }
    public var repository: GitHubRepository
    public var evidence: String
    public var isExplicitUpdateSource: Bool
    public var assetPattern: String?
}

enum SourceError: Error, LocalizedError {
    case invalidRepository, invalidRule, invalidManifest, unsafeURL, ambiguous, noMatchingRelease, authentication, rateLimited
    var errorDescription: String? {
        switch self {
        case .invalidRepository: "请输入 GitHub 仓库、Release、tag 或分支的 HTTPS 链接，或 owner/repo。"
        case .invalidRule: "分支、标签或产物规则无效；版本基线须为可比较的版本。"
        case .invalidManifest: "更新配置格式不受支持或数据不完整，未据此判断最新状态。"
        case .unsafeURL: "更新入口不是有效的 HTTPS 地址。"
        case .ambiguous: "发现多个兼容产物，请指定产物名称规则。"
        case .noMatchingRelease: "所选发布流没有匹配的发行版；已保留绑定，请修改来源或规则。"
        case .authentication: "仓库不存在或需要登录；此版本仅检查公开仓库，请核实访问权限。"
        case .rateLimited: "GitHub 请求限流，稍后重试；本次未确认更新状态。"
        }
    }
}

enum ReleaseVersion {
    static func normalized(_ input: String, prefix: String = "") -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty {
            guard value.hasPrefix(prefix) else { return nil }; value.removeFirst(prefix.count)
        }
        if value.hasPrefix("v") { value.removeFirst() }
        guard value.range(of: #"^\d+(?:\.\d+)*(?:[-+][A-Za-z0-9][A-Za-z0-9.+-]*)?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    static func newer(_ lhs: String, than rhs: String) -> Bool {
        Version(versionNumber: lhs, buildNumber: nil) > Version(versionNumber: rhs, buildNumber: nil)
    }
}

enum SourceURLPolicy {
    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    static func glob(_ pattern: String, matches name: String) -> Bool {
        let regex = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
        return name.range(of: "^" + regex + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
