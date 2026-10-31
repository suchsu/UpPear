// Derived from Pearcleaner 5.4.3, Alin Lupascu / alienator88.
// UpPear changes: platform-specific metadata, typed failures, official catalog
// fallback, pacing/cache and version-bound iOS-on-Mac installation evidence.
// See LICENSE.md and docs/PROVENANCE.md.
import Foundation

enum AppStoreUpdateChecker {
    static let fallbackRegions = ["CN", "US", "HK", "JP", "KR", "SG"]
    typealias AppStoreInfo = AppStoreCatalogInfo

    static func checkAll(apps: [AppInfo], primaryRegion: String,
        client: any HTTPClient = AppStoreHTTPClient.shared,
        progress: @escaping @Sendable (String) async -> Void = { _ in }) async -> [UpdateRecord] {
        await AppStoreCatalog.prefetch(apps: apps, region: primaryRegion.uppercased(), client: client)
        return await checkInBatches(apps) { app in
            let record = await check(app: app, primaryRegion: primaryRegion, client: client)
            await progress(app.appName); return record
        }
    }

    static func check(app: AppInfo, primaryRegion: String, client: any HTTPClient = AppStoreHTTPClient.shared,
        refresh: Bool = false) async -> UpdateRecord {
        guard app.isAppStore else {
            return UpdateRecord(app: app, source: .appStore, state: .unsupported, detail: "未检测到 App Store 安装收据。")
        }
        let platform = AppStoreInstallation.platform(app)
        var record = UpdateRecord(app: app, source: .appStore, state: .failed, detail: "商店查询失败，请重试。")
        record.appStoreQuery = .init(platform: platform, checkedAt: Date(), isCached: false)
        var stage = AppStoreQueryIssue.Stage.catalog
        do {
            let (info, region) = try await AppStoreCatalog.resolve(app: app, primaryRegion: primaryRegion.uppercased(),
                platform: platform, client: client, refresh: refresh)
            let installed = Version(versionNumber: app.appVersion, buildNumber: nil)
            let available = Version(versionNumber: info.version, buildNumber: nil)
            guard !installed.isEmpty, !available.isEmpty else { throw CheckError.noMetadata }
            record.availableVersion = info.version; record.releaseNotes = info.releaseNotes
            record.releaseDate = info.releaseDate; record.foundInRegion = region; record.adamID = info.adamID
            record.appStoreQuery = .init(platform: platform, checkedAt: Date(), versionCheckedAt: info.checkedAt,
                source: info.source, sourceURL: info.sourceURL, isCached: info.isCached)
            record.state = available > installed ? .updateAvailable : .current; record.detail = ""
            if let minimum = info.minimumMacOS, requiresNewerMacOS(minimum) {
                record.state = .incompatible; record.detail = "需要 macOS \(minimum) 或更高版本。"; return record
            }
            if platform == .iOSOnMac, record.state == .updateAvailable || info.pageAvailability == .unavailable {
                stage = .macAvailability
                let availability: AppStoreMacAvailability
                if let status = info.pageAvailability {
                    availability = .init(status: status, checkedAt: info.checkedAt, pageURL: info.sourceURL,
                        sourceVersion: info.version, isCached: info.isCached, minimumMacOS: info.minimumMacOS)
                } else {
                    availability = try await AppStoreMacChecker.check(bundleID: app.bundleIdentifier, adamID: info.adamID,
                        region: region, client: client, version: info.version, refresh: refresh)
                }
                record.appStoreMac = availability
                switch availability.status {
                case .unavailable:
                    record.state = .incompatible; record.detail = "此应用当前不向 Mac 提供安装。"
                case .unknown:
                    record.state = .unverified; record.detail = "商店安装权限信息不足。"
                    record.appStoreQuery?.issue = .init(kind: .compatibilityUnknown, stage: stage)
                case .available:
                    if let minimum = availability.minimumMacOS, requiresNewerMacOS(minimum) {
                        record.state = .incompatible; record.detail = "需要 macOS \(minimum) 或更高版本。"
                    }
                }
            }
        } catch let error as AppStoreResolutionError {
            record.state = [.identityMismatch, .platformUnknown].contains(error.kind) ? .unverified : .failed
            record.detail = error.kind == .noMatch ? "所查询的商店均未返回此商品，可能已下架或存在地区限制。" : "商店商品或平台信息不足。"
            record.appStoreQuery?.issue = .init(kind: error.kind, stage: stage)
        } catch {
            record.state = .failed
            let issue = AppStoreResource.issue(error, stage: stage)
            record.appStoreQuery?.issue = issue
            switch issue.kind {
            case .rateLimited: record.detail = "商店服务繁忙，请稍后重试。"
            case .serviceUnavailable: record.detail = "商店服务暂时不可用，请稍后重试。"
            case .invalidResponse: record.detail = "无法读取商店信息，请重试。"
            default: record.detail = "无法连接 App Store，请重试。"
            }
        }
        return record
    }

    static func fetchAppStoreInfo(bundleID: String, adamID: UInt64?, region: String, entity: String,
        client: any HTTPClient) async throws -> AppStoreInfo? {
        let request = AppStoreCatalog.lookupRequest(id: adamID, bundleID: bundleID, region: region, entity: entity)
        let response = try await AppStoreResource.load(request, client: client, context: "probe|\(bundleID)")
        return try AppStoreCatalog.parseLookup(AppStoreResource.requireSuccess(response), bundleID: bundleID,
            platform: entity == "desktopSoftware" ? .macOS : .iOSOnMac, expectedID: adamID).info
    }

    private static func requiresNewerMacOS(_ minimum: String) -> Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return Version(versionNumber: minimum, buildNumber: nil) > Version(versionNumber: current, buildNumber: nil)
    }
}
