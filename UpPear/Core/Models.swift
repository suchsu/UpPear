// UpPear models, 2026. The app/version vocabulary follows Pearcleaner's updater.
import Foundation

public enum UpdateSource: String, Codable, CaseIterable, Sendable {
    case appStore, homebrewCask, homebrewFormula, sparkle, unsupported

    public var title: String {
        switch self {
        case .appStore: "App Store"
        case .homebrewCask: "Homebrew Cask"
        case .homebrewFormula: "Homebrew Formula"
        case .sparkle: "Sparkle"
        case .unsupported: "其他应用"
        }
    }
}

public enum CheckState: String, Codable, Sendable {
    case updateAvailable, current, failed, unsupported, skipped
    public var title: String {
        switch self {
        case .updateAvailable: "有更新"
        case .current: "未发现更新"
        case .failed: "检查失败"
        case .unsupported: "无法自动检查"
        case .skipped: "已忽略"
        }
    }
}

public struct AppInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path.standardizedFileURL.path }
    public let path: URL
    public let bundlePath: URL
    public let bundleIdentifier: String
    public let appName: String
    public let appVersion: String
    public let appBuildNumber: String?
    public let wrapped: Bool
    public let isAppStore: Bool
    public let adamID: UInt64?
    public let feedURL: URL?
    public let isSetapp: Bool

    public init(path: URL, bundlePath: URL? = nil, bundleIdentifier: String,
                appName: String, appVersion: String, appBuildNumber: String? = nil,
                wrapped: Bool = false, isAppStore: Bool = false, adamID: UInt64? = nil,
                feedURL: URL? = nil, isSetapp: Bool = false) {
        self.path = path
        self.bundlePath = bundlePath ?? path
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appVersion = appVersion
        self.appBuildNumber = appBuildNumber
        self.wrapped = wrapped
        self.isAppStore = isAppStore
        self.adamID = adamID
        self.feedURL = feedURL
        self.isSetapp = isSetapp
    }
}

public struct UpdateRecord: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let installedVersion: String
    public let installedBuild: String?
    public var availableVersion: String?
    public var availableBuild: String?
    public let app: AppInfo?
    public let source: UpdateSource
    public var state: CheckState
    public var detail: String
    public var releaseNotes: String?
    public var releaseNotesURL: URL?
    public var releaseDate: String?
    public var foundInRegion: String?
    public var adamID: UInt64?
    public var isPreRelease: Bool
    public var packageName: String?
    public var brewExecutable: URL?
    public var isPinned: Bool
    public var homepage: URL?

    public init(app: AppInfo?, source: UpdateSource, state: CheckState, detail: String,
                id: String? = nil, name: String? = nil, installedVersion: String? = nil,
                availableVersion: String? = nil, availableBuild: String? = nil,
                releaseNotes: String? = nil, releaseNotesURL: URL? = nil,
                releaseDate: String? = nil, foundInRegion: String? = nil,
                adamID: UInt64? = nil, isPreRelease: Bool = false,
                packageName: String? = nil, brewExecutable: URL? = nil,
                isPinned: Bool = false, homepage: URL? = nil) {
        self.app = app
        self.id = id ?? app?.id ?? "\(source.rawValue):\(packageName ?? name ?? "unknown")"
        self.name = name ?? app?.appName ?? packageName ?? "未知应用"
        self.installedVersion = installedVersion ?? app?.appVersion ?? ""
        self.installedBuild = app?.appBuildNumber
        self.source = source
        self.state = state
        self.detail = detail
        self.availableVersion = availableVersion
        self.availableBuild = availableBuild
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.releaseDate = releaseDate
        self.foundInRegion = foundInRegion
        self.adamID = adamID ?? app?.adamID
        self.isPreRelease = isPreRelease
        self.packageName = packageName
        self.brewExecutable = brewExecutable
        self.isPinned = isPinned
        self.homepage = homepage
    }
}

public struct CheckOptions: Sendable {
    public var primaryRegion: String
    public var includePreReleases: Bool
    public var includeFormulae: Bool
    public var ignoredIDs: Set<String>
    public init(primaryRegion: String = "CN", includePreReleases: Bool = false,
                includeFormulae: Bool = true, ignoredIDs: Set<String> = []) {
        self.primaryRegion = primaryRegion
        self.includePreReleases = includePreReleases
        self.includeFormulae = includeFormulae
        self.ignoredIDs = ignoredIDs
    }
}

public struct ScanSnapshot: Codable, Sendable {
    public let completedAt: Date
    public let records: [UpdateRecord]
    public let warnings: [String]
    public var updateCount: Int { records.filter { $0.state == .updateAvailable }.count }
    public var failureCount: Int { records.filter { $0.state == .failed }.count }
    public init(completedAt: Date = Date(), records: [UpdateRecord], warnings: [String] = []) {
        self.completedAt = completedAt
        self.records = records
        self.warnings = warnings
    }
}

public struct ScanProgress: Sendable {
    public let message: String
    public let completed: Int
    public let total: Int
    public init(_ message: String, completed: Int = 0, total: Int = 0) {
        self.message = message
        self.completed = completed
        self.total = total
    }
}
