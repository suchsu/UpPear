import Foundation

public enum UpdateAction: Sendable {
    case appStore(URL)
    case openApplication(URL)
    case brewUpgrade(BrewCommandPlan)
    case microsoftAutoUpdate(URL)
    case extensionDownload(URL)
    case officialPage(URL)
    case manual

    public var title: String {
        switch self {
        case .appStore: "打开 App Store"
        case .openApplication: "打开应用"
        case .brewUpgrade: "通过 Homebrew 升级…"
        case .microsoftAutoUpdate: "打开 Microsoft AutoUpdate"
        case .extensionDownload: "下载兼容扩展"
        case .officialPage: "查看官方详情"
        case .manual: "手动检查"
        }
    }
}

public struct BrewCommandPlan: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let packageName: String
    public var displayCommand: String {
        ([executable.path] + arguments).map(Self.shellQuote).joined(separator: " ")
    }
    private static func shellQuote(_ string: String) -> String {
        if string.range(of: #"^[A-Za-z0-9_@+./-]+$"#, options: .regularExpression) != nil { return string }
        return "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public enum ActionResolver {
    public static func action(for record: UpdateRecord, primaryRegion: String = "CN") -> UpdateAction {
        // Source identity outranks detections and any stale Homebrew metadata.
        if record.app?.isAppStore == true || record.source == .appStore {
            if let id = record.adamID {
                let region = (record.foundInRegion ?? primaryRegion).lowercased()
                if region.range(of: "^[a-z]{2}$", options: .regularExpression) != nil,
                   let url = URL(string: "macappstore://itunes.apple.com/\(region)/app/id\(id)") {
                    return .appStore(url)
                }
            }
            return .appStore(URL(string: "macappstore://itunes.apple.com/WebObjects/MZStore.woa/wa/viewSoftwareUpdates")!)
        }
        if record.source == .popClip {
            if record.state == .updateAvailable, let info = record.popClip, !info.isStale,
               info.compatibleVersion == record.availableVersion, let url = info.downloadURL,
               PopClipURLPolicy.isDownload(url) { return .extensionDownload(url) }
            if let url = record.popClip?.detailURL, PopClipURLPolicy.isOfficial(url) { return .officialPage(url) }
            return .officialPage(URL(string: "https://www.popclip.app/extensions/")!)
        }
        if record.source == .microsoftAutoUpdate {
            if let url = record.microsoft?.updaterURL { return .microsoftAutoUpdate(url) }
            // Ignored records can still open the updater without starting a check.
            if let updater = MicrosoftAutoUpdateChecker.installedUpdater() { return .microsoftAutoUpdate(updater.path) }
            return .officialPage(MicrosoftAutoUpdateChecker.supportURL)
        }
        if let app = record.app, app.feedURL != nil || app.isSetapp {
            return .openApplication(app.path)
        }
        if record.state == .updateAvailable, !record.isPinned,
           [.homebrewCask, .homebrewFormula].contains(record.source),
           let executable = record.brewExecutable, let package = record.packageName,
           validPackageName(package) {
            return .brewUpgrade(BrewCommandPlan(executable: executable,
                arguments: ["upgrade", record.source == .homebrewCask ? "--cask" : "--formula", package],
                packageName: package))
        }
        if let app = record.app { return .openApplication(app.path) }
        return .manual
    }

    static func validPackageName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9@+._-]*(/[A-Za-z0-9][A-Za-z0-9@+._-]*){0,2}$"#,
                   options: .regularExpression) != nil
    }
}
