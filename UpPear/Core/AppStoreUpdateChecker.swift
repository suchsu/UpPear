// AppStoreUpdateChecker.swift — Pearcleaner
// Created by Alin Lupascu on 10/13/25.
// Modified for UpPear on 2026-10-13. Derived from Pearcleaner 5.4.3,
// c52695d90c43f60abd5cd10c363f2e122c65f191. See LICENSE.md.
// Retains adamID fast lookup, entity isolation, CN/US/HK/JP/KR/SG fallback
// and version comparison. Changes: injected HTTP, bounded requests, validated
// bundle identity, configurable CN default, and explicit failure/current states.
import Foundation

enum AppStoreUpdateChecker {
    static let fallbackRegions = ["CN", "US", "HK", "JP", "KR", "SG"]

    struct AppStoreInfo: Sendable {
        let adamID: UInt64
        let version: String
        let releaseNotes: String?
        let releaseDate: String?
    }

    static func check(app: AppInfo, primaryRegion: String, client: any HTTPClient = NetworkClient()) async -> UpdateRecord {
        let region = primaryRegion.uppercased()
        guard app.isAppStore else {
            return UpdateRecord(app: app, source: .appStore, state: .unsupported, detail: "未检测到 App Store 安装收据。")
        }
        do {
            let result = try await getAppStoreInfo(app: app, primaryRegion: region, client: client)
            guard let (info, foundRegion) = result else {
                return UpdateRecord(app: app, source: .appStore, state: .unsupported,
                    detail: "在 \(([region] + fallbackRegions.filter { $0 != region }).joined(separator: "、")) 未找到此应用，可能已下架或存在地区限制。")
            }
            let installedVer = Version(versionNumber: app.appVersion, buildNumber: nil)
            let availableVer = Version(versionNumber: info.version, buildNumber: nil)
            guard !installedVer.isEmpty && !availableVer.isEmpty else {
                throw CheckError.noMetadata
            }
            let hasUpdate = availableVer > installedVer
            var detail = hasUpdate ? "请通过 App Store 完成更新。" : "商店元数据未显示更高版本。"
            if foundRegion != region { detail += " 版本信息来自 \(foundRegion)，实际更新取决于你的商店账号地区。" }
            return UpdateRecord(app: app, source: .appStore, state: hasUpdate ? .updateAvailable : .current,
                detail: detail, availableVersion: info.version, releaseNotes: info.releaseNotes,
                releaseDate: info.releaseDate, foundInRegion: foundRegion, adamID: info.adamID)
        } catch {
            return UpdateRecord(app: app, source: .appStore, state: .failed, detail: error.localizedDescription)
        }
    }

    private static func getAppStoreInfo(app: AppInfo, primaryRegion: String, client: any HTTPClient) async throws -> (AppStoreInfo, String)? {
        // Use entity filtering based on app type, as in Pearcleaner. This avoids
        // mixing the iOS version into a native Mac app's installed version.
        let entity = app.wrapped ? "macSoftware" : "desktopSoftware"
        if let adamID = app.adamID {
            if let info = try await fetchAppStoreInfo(bundleID: app.bundleIdentifier, adamID: adamID,
                region: primaryRegion, entity: entity, client: client) {
                return (info, primaryRegion)
            }
        }
        for region in [primaryRegion] + fallbackRegions.filter({ $0 != primaryRegion }) {
            try Task.checkCancellation()
            if let info = try await fetchAppStoreInfo(bundleID: app.bundleIdentifier, adamID: nil,
                region: region, entity: entity, client: client) {
                return (info, region)
            }
        }
        return nil
    }

    static func fetchAppStoreInfo(bundleID: String, adamID: UInt64?, region: String, entity: String,
                                  client: any HTTPClient) async throws -> AppStoreInfo? {
        let endpoint = URL(string: "https://itunes.apple.com/lookup")!
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: adamID == nil ? "bundleId" : "id", value: adamID.map(String.init) ?? bundleID),
            URLQueryItem(name: "country", value: region),
            URLQueryItem(name: "limit", value: "1")
        ]
        queryItems.append(URLQueryItem(name: "entity", value: entity))
        components.queryItems = queryItems
        guard let url = components.url else { throw CheckError.invalidResponse }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        let data = try await client.fetch(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultCount = json["resultCount"] as? Int,
              let results = json["results"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        if resultCount == 0 { return nil }
        // adamID metadata can be stale after an app transfer. Never trust a
        // different bundle ID returned by a successful numerical lookup.
        guard let firstResult = results.first,
              firstResult["bundleId"] as? String == bundleID else { return nil }
        guard let trackId = firstResult["trackId"] as? NSNumber,
              trackId.uint64Value > 0,
              let version = firstResult["version"] as? String, !version.isEmpty else { throw CheckError.noMetadata }
        return AppStoreInfo(adamID: trackId.uint64Value, version: version,
            releaseNotes: firstResult["releaseNotes"] as? String,
            releaseDate: firstResult["currentVersionReleaseDate"] as? String)
    }
}
