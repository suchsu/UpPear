import Foundation

public struct AppStoreQueryIssue: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case network, rateLimited, serviceUnavailable, invalidResponse, noMatch, identityMismatch, platformUnknown, compatibilityUnknown
    }
    public enum Stage: String, Codable, Sendable { case catalog, macAvailability }
    public var kind: Kind
    public var stage: Stage
    public var httpStatus: Int?
    public var retryAt: Date?

    public var title: String {
        switch kind {
        case .rateLimited, .serviceUnavailable: "服务繁忙"
        case .network: "连接失败"
        case .invalidResponse: "数据异常"
        case .noMatch: "商品不可用"
        case .identityMismatch, .platformUnknown: "版本信息不足"
        case .compatibilityUnknown: "安装权限待确认"
        }
    }
}

public struct AppStoreQueryInfo: Codable, Sendable {
    public enum Platform: String, Codable, Sendable { case macOS, macCatalyst, iOSOnMac }
    public enum Source: String, Codable, Sendable { case lookup, productPage }
    public var platform: Platform
    public var checkedAt: Date
    public var versionCheckedAt: Date?
    public var source: Source?
    public var sourceURL: URL?
    public var isCached: Bool
    public var issue: AppStoreQueryIssue?
}

struct AppStoreRequestError: Error, LocalizedError {
    var status: Int?
    var retryAt: Date?
    var message: String?
    var errorDescription: String? {
        if status == 429 { return "商店服务繁忙，请稍后重试。" }
        if status == 404 { return "未取得商店信息。" }
        return message ?? "商店查询失败，请重试。"
    }
}

struct AppStoreHTTPResponse: Sendable {
    var payload: HTTPPayload
    var checkedAt: Date
    var isCached: Bool
    var retryAt: Date? = nil
}

protocol AppStoreResourceClient: HTTPClient {
    func resource(_ request: URLRequest, context: String, maxAge: TimeInterval, refresh: Bool) async throws -> AppStoreHTTPResponse
    func invalidate(_ request: URLRequest, context: String) async
}

enum AppStoreResource {
    static func load(_ request: URLRequest, client: any HTTPClient, context: String,
        maxAge: TimeInterval = 900, refresh: Bool = false) async throws -> AppStoreHTTPResponse {
        if let client = client as? any AppStoreResourceClient {
            return try await client.resource(request, context: context, maxAge: maxAge, refresh: refresh)
        }
        let payload: HTTPPayload
        if let client = client as? any HTTPResponseClient { payload = try await client.response(request) }
        else { payload = HTTPPayload(data: try await client.fetch(request), status: 200, headers: [:]) }
        return AppStoreHTTPResponse(payload: payload, checkedAt: Date(), isCached: false)
    }
    static func requireSuccess(_ response: AppStoreHTTPResponse) throws -> Data {
        guard (200..<300).contains(response.payload.status) else {
            throw AppStoreRequestError(status: response.payload.status,
                retryAt: response.retryAt ?? AppStoreHTTPClient.retryDate(response.payload.headers["retry-after"], now: response.checkedAt))
        }
        return response.payload.data
    }
    static func invalidate(_ request: URLRequest, client: any HTTPClient, context: String) async {
        await (client as? any AppStoreResourceClient)?.invalidate(request, context: context)
    }
    static func issue(_ error: any Error, stage: AppStoreQueryIssue.Stage) -> AppStoreQueryIssue {
        if let error = error as? AppStoreRequestError {
            return .init(kind: httpIssue(error.status), stage: stage,
                httpStatus: error.status, retryAt: error.retryAt)
        }
        if case CheckError.httpStatus(let status) = error {
            return .init(kind: httpIssue(status), stage: stage, httpStatus: status)
        }
        if error is URLError || error is CancellationError {
            return .init(kind: .network, stage: stage)
        }
        if let error = error as? CheckError, case .timedOut = error { return .init(kind: .network, stage: stage) }
        return .init(kind: .invalidResponse, stage: stage)
    }
    private static func httpIssue(_ status: Int?) -> AppStoreQueryIssue.Kind {
        if status == 429 { return .rateLimited }
        if let status, (500...599).contains(status) { return .serviceUnavailable }
        return .network
    }
}
