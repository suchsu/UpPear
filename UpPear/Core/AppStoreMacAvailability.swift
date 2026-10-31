import Foundation

public struct AppStoreMacAvailability: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, unavailable, unknown }
    public var status: Status
    public var checkedAt: Date
    public var pageURL: URL
    public var sourceVersion: String?
    public var isCached: Bool?
    public var minimumMacOS: String?
}

enum AppStoreMacChecker {
    static func check(bundleID: String, adamID: UInt64, region: String, client: any HTTPClient,
        version: String? = nil, refresh: Bool = false) async throws -> AppStoreMacAvailability {
        guard region.range(of: #"^[A-Za-z]{2}$"#, options: .regularExpression) != nil else { throw CheckError.invalidResponse }
        let url = URL(string: "https://apps.apple.com/\(region.lowercased())/app/id\(adamID)")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        let context = "compatibility|\(bundleID)|\(region.uppercased())|\(version ?? "")"
        let response = try await AppStoreResource.load(request, client: client, context: context, maxAge: 3600, refresh: refresh)
        let data = try AppStoreResource.requireSuccess(response)
        do {
            let page = try AppStoreProductPage.parse(data, bundleID: bundleID, adamID: adamID, platform: .iOSOnMac, region: region)
            var status = page?.macAvailability ?? .unknown
            if status == .available, page?.platformVerified != true || (version != nil && page?.version != version) { status = .unknown }
            if status == .unknown { await AppStoreResource.invalidate(request, client: client, context: context) }
            return AppStoreMacAvailability(status: status, checkedAt: response.checkedAt, pageURL: url,
                sourceVersion: page?.version, isCached: response.isCached, minimumMacOS: page?.minimumMacOS)
        } catch {
            await AppStoreResource.invalidate(request, client: client, context: context); throw error
        }
    }

    static func parse(_ data: Data, bundleID: String, adamID: UInt64) throws -> AppStoreMacAvailability.Status {
        try AppStoreProductPage.parse(data, bundleID: bundleID, adamID: adamID, platform: .iOSOnMac)?.macAvailability ?? .unknown
    }
}
