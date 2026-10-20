// Added for UpPear 1.1. Uses Microsoft's installed msupdate tool for checks only.
// Installation, channels and administrator authorization remain owned by MAU.
import Foundation

public struct MicrosoftUpdateInfo: Codable, Sendable {
    public let applicationID: String
    public let updaterURL: URL?
    public let channel: String?
}

struct MicrosoftRegistration: Sendable {
    let path: URL
    let applicationID: String
}

struct MicrosoftConfiguration: Sendable {
    let registrations: [MicrosoftRegistration]
    let channel: String?
}

struct MicrosoftAvailableUpdate: Sendable {
    let applicationID: String
    let version: String
    let path: URL?
}

public enum MicrosoftAutoUpdateChecker {
    public static let standardUpdaterURL = URL(fileURLWithPath:
        "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app", isDirectory: true)
    public static let supportURL = URL(string:
        "https://support.microsoft.com/en-us/office/lifecycle/officeinstall/update-office-for-mac-automatically")!

    // Documented MAU products. Edge and Teams own their update mechanisms.
    // The actual registration/path is still required before calling an app current.
    static let applicationIDs: [String: String] = [
        "com.microsoft.Excel": "XCEL2019", "com.microsoft.Word": "MSWD2019",
        "com.microsoft.Powerpoint": "PPT32019", "com.microsoft.Outlook": "OPIM2019",
        "com.microsoft.onenote.mac": "ONMC2019", "com.microsoft.OneDrive": "ONDR18",
        "com.microsoft.CompanyPortalMac": "IMCP01", "com.microsoft.wdav": "WDAV00",
        "com.microsoft.defender": "WDAVCONSUMER", "com.microsoft.rdc.macos": "MSRD10",
        "com.microsoft.autoupdate2": "MSau04", "com.microsoft.Copilot": "MSCP10",
        "com.microsoft.SkypeForBusiness": "MSFB16", "com.microsoft.remotehelp": "MSRH01",
        "com.microsoft.quickassist": "MSQA01"
    ]

    public static func isCandidate(_ app: AppInfo) -> Bool {
        !app.isAppStore && !app.isSetapp && applicationID(for: app) != nil
    }
    static func applicationID(for app: AppInfo) -> String? {
        applicationIDs.first { $0.key.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame }?.value
    }

    public static func installedUpdater() -> AppInfo? {
        let roots = [standardUpdaterURL, URL(fileURLWithPath: "/Applications/Microsoft AutoUpdate.app")]
        return roots.compactMap { AppScanner.getAppInfo(atPath: $0) }
            .first { $0.bundleIdentifier == "com.microsoft.autoupdate2" }
    }

    static func check(apps: [AppInfo], updater: AppInfo?,
        run: (@Sendable ([String]) async throws -> CommandResult)? = nil) async -> [UpdateRecord] {
        let candidates = apps.filter(isCandidate)
        guard !candidates.isEmpty else { return [] }
        func record(_ app: AppInfo, _ state: CheckState, _ detail: String,
                    id: String? = nil, version: String? = nil, channel: String? = nil) -> UpdateRecord {
            var result = UpdateRecord(app: app, source: .microsoftAutoUpdate, state: state,
                detail: detail, availableVersion: version, homepage: supportURL)
            result.microsoft = MicrosoftUpdateInfo(applicationID: id ?? applicationID(for: app) ?? "",
                updaterURL: updater?.path, channel: channel)
            return result
        }
        guard let updater else {
            return candidates.map { record($0, .unsupported, "未找到 Microsoft AutoUpdate，请通过微软官方入口安装或在应用内检查。") }
        }
        let execute: @Sendable ([String]) async throws -> CommandResult = run ?? { arguments in
            try await CommandRunner.run(executable: updater.path.appendingPathComponent("Contents/MacOS/msupdate"),
                arguments: arguments, timeout: 90, environmentOverrides: ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"])
        }
        do {
            let configResult = try await execute(["--config", "--format", "plist"])
            guard configResult.exitCode == 0 else { throw CheckError.invalidResponse }
            let config = try parseConfiguration(configResult.output)
            try Task.checkCancellation()
            let list = try await execute(["--list", "--format", "plist"])
            let updates = try parseUpdates(list)
            try Task.checkCancellation()
            return candidates.map { app in
                let path = app.path.resolvingSymlinksInPath().standardizedFileURL
                guard let registration = config.registrations.first(where: {
                    $0.path.resolvingSymlinksInPath().standardizedFileURL == path
                }) else {
                    return record(app, .unsupported, "此安装未登记在 Microsoft AutoUpdate 中，请打开官方更新器确认。", channel: config.channel)
                }
                let matching = updates.filter {
                    $0.applicationID.caseInsensitiveCompare(registration.applicationID) == .orderedSame &&
                    ($0.path == nil || $0.path?.resolvingSymlinksInPath().standardizedFileURL == path)
                }
                if let update = matching.max(by: {
                    Version(versionNumber: $0.version, buildNumber: nil) < Version(versionNumber: $1.version, buildNumber: nil)
                }) {
                    return record(app, .updateAvailable,
                        "Microsoft AutoUpdate 已确认有更新。打开官方更新器查看说明并安装；更新频道沿用当前设置。",
                        id: registration.applicationID, version: update.version, channel: config.channel)
                }
                return record(app, .current, "Microsoft AutoUpdate 本次未报告此安装的可用更新。",
                    id: registration.applicationID, channel: config.channel)
            }
        } catch {
            let message = Task.isCancelled ? "检查已取消。" : error.localizedDescription
            return candidates.map { record($0, .failed,
                "Microsoft AutoUpdate 检查未完成：\(message) 可打开官方更新器重试。") }
        }
    }

    static func parseConfiguration(_ output: String) throws -> MicrosoftConfiguration {
        let root = try plistDictionary(output)
        guard let applications = root["RegisteredApplications"] as? [String: [String: Any]] else {
            throw CheckError.invalidResponse
        }
        let registrations = applications.compactMap { path, info -> MicrosoftRegistration? in
            guard path.hasPrefix("/"), let id = info["Application ID"] as? String, !id.isEmpty else { return nil }
            return MicrosoftRegistration(path: URL(fileURLWithPath: path), applicationID: id)
        }
        return MicrosoftConfiguration(registrations: registrations, channel: root["ChannelName"] as? String)
    }

    static func parseUpdates(_ result: CommandResult) throws -> [MicrosoftAvailableUpdate] {
        guard result.exitCode == 0 else { throw CheckError.invalidResponse }
        let text = stripTerminalCodes(result.output)
        let combined = (text + "\n" + result.error).lowercased()
        // msupdate can exit zero on an invalid XPC connection. Never turn that
        // or a partial result into a successful empty update list.
        guard !["invalidated", "proxy error", "error reported", "assistant: error", "failed", "denied", "timed out", "cannot connect", "could not"]
            .contains(where: combined.contains) else { throw CheckError.invalidResponse }
        if text.contains("<?xml") || text.contains("<plist") {
            let root = try plistDictionary(text)
            if let code = root["ErrorCode"], String(describing: code) != "0" { throw CheckError.invalidResponse }
            if let error = root["Error"] as? String, !error.isEmpty { throw CheckError.invalidResponse }
            if let errors = root["Errors"] as? [Any], !errors.isEmpty { throw CheckError.invalidResponse }
            if let success = root["Success"] as? Bool, !success { throw CheckError.invalidResponse }
            for key in ["Status", "State", "Result"] {
                if let status = root[key] as? String,
                   ["error", "failed", "cancelled", "denied"].contains(where: status.lowercased().contains) {
                    throw CheckError.invalidResponse
                }
            }
            let items: [[String: Any]]
            if let array = root["Updates"] as? [[String: Any]] { items = array }
            else {
                let values = (root["Updates"] as? [String: Any]) ?? root
                let known = Set(applicationIDs.values.map { $0.uppercased() })
                guard !values.isEmpty, values.keys.allSatisfy({ known.contains($0.uppercased()) }) else {
                    throw CheckError.invalidResponse
                }
                items = try values.map { id, value in
                    guard var item = value as? [String: Any] else { throw CheckError.invalidResponse }
                    item["Application ID"] = id
                    return item
                }
            }
            return try items.map { item in
                guard let id = (item["Application ID"] ?? item["ApplicationID"] ?? item["AppID"]) as? String, !id.isEmpty,
                      let version = (item["Available Version"] ?? item["Version"] ?? item["ToVersion"]) as? String,
                      version.range(of: #"^\d[\dA-Za-z.+_-]*$"#, options: .regularExpression) != nil else {
                    throw CheckError.invalidResponse
                }
                let path = (item["Application Path"] ?? item["Path"]) as? String
                return MicrosoftAvailableUpdate(applicationID: id, version: version,
                    path: path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil })
            }
        }
        // MAU 4.85 emits this terminal message even with --format plist.
        guard !combined.contains("error") else { throw CheckError.invalidResponse }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("No updates available") && !lines.contains("Updates available:") { return [] }
        // Some MAU versions also print updates as product ID + localized title.
        // Accept only a complete row ending in a dotted version, never a date
        // or an application's name alone.
        guard lines.contains("Updates available:") else { throw CheckError.invalidResponse }
        let pattern = #"^([A-Za-z0-9]{4,20})\s+.+?\s(\d+\.\d+(?:\.\d+)*)(?:\s+\(\d+\))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var updates: [MicrosoftAvailableUpdate] = []
        for line in lines {
            if line.isEmpty || line == "Updates available:" || line.hasPrefix("Update Assistant:") || line == "Checking for updates..." { continue }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let id = Range(match.range(at: 1), in: line), let version = Range(match.range(at: 2), in: line) else {
                throw CheckError.invalidResponse
            }
            updates.append(MicrosoftAvailableUpdate(applicationID: String(line[id]), version: String(line[version]), path: nil))
        }
        guard !updates.isEmpty else { throw CheckError.invalidResponse }
        return updates
    }

    static func plistDictionary(_ output: String) throws -> [String: Any] {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<plist"),
              let end = output.range(of: "</plist>", range: start.lowerBound..<output.endIndex),
              let data = String(output[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CheckError.invalidResponse
        }
        return root
    }

    static func stripTerminalCodes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}
