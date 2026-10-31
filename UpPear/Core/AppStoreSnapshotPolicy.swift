import Foundation

enum AppStoreSnapshotPolicy {
    /// Legacy display migration is local. It neither starts a scan nor resets
    /// the original snapshot time. New results always carry a typed issue.
    static func display(_ original: UpdateRecord, observedAt: Date, now: Date = Date()) -> UpdateRecord {
        guard original.source == .appStore else { return original }
        var record = original
        if record.appStoreQuery == nil {
            var issue: AppStoreQueryIssue?
            if record.state == .unsupported, record.app?.isAppStore == true {
                issue = .init(kind: .noMatch, stage: .catalog)
                record.state = .failed; record.detail = "所查询的商店均未返回此商品，可能已下架或存在地区限制。"
            } else if record.state == .unverified, record.detail.hasPrefix("无法核实 Mac 可安装性：") {
                let range = record.detail.range(of: #"HTTP [0-9]{3}"#, options: .regularExpression)
                let status = range.flatMap { Int(record.detail[$0].suffix(3)) }
                let kind: AppStoreQueryIssue.Kind = status == 429 ? .rateLimited
                    : status.map { (500...599).contains($0) } == true ? .serviceUnavailable : .network
                issue = .init(kind: kind, stage: .macAvailability, httpStatus: status)
                record.state = .failed
                record.detail = status == 429 ? "商店服务繁忙，请稍后重试。"
                    : kind == .serviceUnavailable ? "商店服务暂时不可用，请稍后重试。" : "无法连接 App Store，请重试。"
            }
            if let issue {
                record.appStoreQuery = .init(platform: record.app?.wrapped == true ? .iOSOnMac : .macOS,
                    checkedAt: observedAt, isCached: true, issue: issue)
            }
        }
        if record.state == .updateAvailable, record.app?.wrapped == true {
            guard let availability = record.appStoreMac, availability.status == .available,
                  availability.sourceVersion == record.availableVersion,
                  (0...3600).contains(now.timeIntervalSince(availability.checkedAt)) else {
                record.state = .unverified; record.detail = "需要重新核实 Mac 安装权限。"
                return record
            }
        }
        return record
    }
}
