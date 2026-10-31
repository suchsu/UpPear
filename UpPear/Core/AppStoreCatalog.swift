import Foundation

struct AppStoreCatalogInfo: Sendable {
    var adamID: UInt64
    var version: String
    var releaseNotes: String?
    var releaseDate: String?
    var minimumMacOS: String?
    var checkedAt: Date
    var source: AppStoreQueryInfo.Source
    var sourceURL: URL
    var isCached: Bool
    var pageAvailability: AppStoreMacAvailability.Status?
}

struct AppStoreResolutionError: Error {
    var kind: AppStoreQueryIssue.Kind
}

enum AppStoreCatalog {
    static func lookupRequest(id: UInt64?, bundleID: String, region: String, entity: String?) -> URLRequest {
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [.init(name: id == nil ? "bundleId" : "id", value: id.map(String.init) ?? bundleID),
            .init(name: "country", value: region), .init(name: "media", value: "software"), .init(name: "limit", value: "200")]
        if let entity { url.queryItems?.append(.init(name: "entity", value: entity)) }
        return URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
    }
    static func context(_ app: AppInfo, platform: AppStoreQueryInfo.Platform) -> String {
        "catalog|\(app.bundleIdentifier)|\(platform.rawValue)"
    }

    static func resolve(app: AppInfo, primaryRegion: String, platform: AppStoreQueryInfo.Platform,
        client: any HTTPClient, refresh: Bool) async throws -> (AppStoreCatalogInfo, String) {
        guard primaryRegion.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil else { throw CheckError.invalidResponse }
        let regions = [primaryRegion] + AppStoreUpdateChecker.fallbackRegions.filter { $0 != primaryRegion }
        let entity = platform == .iOSOnMac ? "software" : "desktopSoftware"
        var firstError: (any Error)?, unknownPlatform = false, identityConflict = false
        let started = ContinuousClock.now
        var pageIDs = Set<UInt64>()
        if let id = app.adamID { pageIDs.insert(id) }
        for region in regions {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(45) else { throw firstError ?? CheckError.timedOut }
            let requests = [app.adamID.map { lookupRequest(id: $0, bundleID: app.bundleIdentifier, region: region, entity: entity) },
                            lookupRequest(id: nil, bundleID: app.bundleIdentifier, region: region, entity: entity)].compactMap { $0 }
            for request in requests {
                guard started.duration(to: .now) < .seconds(45) else { throw firstError ?? CheckError.timedOut }
                do {
                    let response = try await AppStoreResource.load(request, client: client, context: context(app, platform: platform), refresh: refresh)
                    let data = try AppStoreResource.requireSuccess(response)
                    let parsed = try parseLookup(data, bundleID: app.bundleIdentifier, platform: platform,
                        expectedID: request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value }.flatMap(UInt64.init))
                    if let info = parsed.info {
                        return (info.withResponse(response, url: request.url!), region)
                    }
                    unknownPlatform = unknownPlatform || parsed.platformUnknown
                    identityConflict = identityConflict || parsed.identityConflict
                    if parsed.identityConflict,
                       let id = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value }).flatMap(UInt64.init) {
                        pageIDs.remove(id)
                    }
                    pageIDs.formUnion(parsed.pageIDs)
                } catch {
                    try Task.checkCancellation()
                    await AppStoreResource.invalidate(request, client: client, context: context(app, platform: platform))
                    if firstError == nil { firstError = error }
                    if let error = error as? AppStoreRequestError, error.status == 429 { break }
                }
            }
            // Official product-page fallback is separate from the legacy index.
            // It is attempted for exact identity candidates, never a name match.
            if region == primaryRegion {
                if platform != .iOSOnMac {
                    let request = lookupRequest(id: app.adamID, bundleID: app.bundleIdentifier, region: region, entity: nil)
                    do {
                        let response = try await AppStoreResource.load(request, client: client, context: context(app, platform: platform), refresh: refresh)
                        let parsed = try parseLookup(AppStoreResource.requireSuccess(response), bundleID: app.bundleIdentifier, platform: platform, expectedID: app.adamID)
                        if let info = parsed.info { return (info.withResponse(response, url: request.url!), region) }
                        unknownPlatform = unknownPlatform || parsed.platformUnknown
                        pageIDs.formUnion(parsed.pageIDs)
                    } catch {
                        try Task.checkCancellation()
                        await AppStoreResource.invalidate(request, client: client, context: context(app, platform: platform))
                        if firstError == nil { firstError = error }
                    }
                }
                for id in pageIDs.sorted().prefix(3) {
                    do {
                        if let info = try await product(app: app, id: id, region: region, platform: platform, client: client, refresh: refresh) {
                            return (info, region)
                        }
                    } catch {
                        try Task.checkCancellation()
                        if let error = error as? AppStoreRequestError, error.status == 404 { continue }
                        if firstError == nil { firstError = error }
                    }
                }
            }
            // A rate-limited provider must not fan out into more storefronts.
            if let error = firstError as? AppStoreRequestError, error.status == 429 { break }
        }
        // Search discovers candidates when local metadata or a storefront's
        // index is incomplete. Every candidate still needs exact bundle/platform.
        if firstError == nil, started.duration(to: .now) < .seconds(45) {
            do {
                if let info = try await search(app: app, region: primaryRegion, platform: platform, client: client, refresh: refresh) { return (info, primaryRegion) }
            } catch { try Task.checkCancellation(); firstError = error }
        }
        if let firstError { throw firstError }
        if unknownPlatform { throw AppStoreResolutionError(kind: .platformUnknown) }
        if identityConflict { throw AppStoreResolutionError(kind: .identityMismatch) }
        throw AppStoreResolutionError(kind: .noMatch)
    }

    struct Parsed {
        var info: AppStoreCatalogInfo?
        var pageIDs: Set<UInt64> = []
        var platformUnknown = false
        var identityConflict = false
    }
    static func parseLookup(_ data: Data, bundleID: String, platform: AppStoreQueryInfo.Platform, expectedID: UInt64? = nil) throws -> Parsed {
        guard data.count <= 6_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["resultCount"] as? Int, (0...200).contains(count),
              let results = object["results"] as? [[String: Any]], results.count == count else { throw CheckError.invalidResponse }
        var parsed = Parsed(), accepted: [AppStoreCatalogInfo] = []
        for item in results {
            guard let number = item["trackId"] as? NSNumber, number.uint64Value > 0 else { continue }
            let id = number.uint64Value
            if let expectedID, id != expectedID { continue }
            guard item["bundleId"] as? String == bundleID else { parsed.identityConflict = true; continue }
            parsed.pageIDs.insert(id)
            let kind = item["kind"] as? String
            let devices = item["supportedDevices"] as? [String] ?? []
            let isMac = kind == "mac-software" || (kind == "software" && devices == ["MacDesktop-MacDesktop"])
            let isIOS = kind == "software" && !devices.contains("MacDesktop-MacDesktop") &&
                devices.contains(where: { $0.hasPrefix("iPhone") || $0.hasPrefix("iPad") || $0.hasPrefix("iPod") })
            guard platform == .iOSOnMac ? isIOS : isMac else { parsed.platformUnknown = true; continue }
            guard let version = item["version"] as? String,
                  version.range(of: #"^[0-9][0-9A-Za-z._+\-]{0,127}$"#, options: .regularExpression) != nil else { throw CheckError.noMetadata }
            accepted.append(.init(adamID: id, version: version, releaseNotes: item["releaseNotes"] as? String,
                releaseDate: item["currentVersionReleaseDate"] as? String,
                minimumMacOS: isMac ? item["minimumOsVersion"] as? String : nil,
                checkedAt: Date(), source: .lookup, sourceURL: URL(string: "https://itunes.apple.com/lookup")!, isCached: false))
        }
        if accepted.count == 1 { parsed.info = accepted[0] }
        else if accepted.count > 1 { throw AppStoreResolutionError(kind: .identityMismatch) }
        return parsed
    }

    static func product(app: AppInfo, id: UInt64, region: String, platform: AppStoreQueryInfo.Platform,
        client: any HTTPClient, refresh: Bool) async throws -> AppStoreCatalogInfo? {
        let selected = platform == .iOSOnMac ? "iphone" : "mac"
        let url = URL(string: "https://apps.apple.com/\(region.lowercased())/app/id\(id)?platform=\(selected)")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        let scope = "product|\(app.bundleIdentifier)|\(platform.rawValue)"
        let response = try await AppStoreResource.load(request, client: client, context: scope, refresh: refresh)
        let data = try AppStoreResource.requireSuccess(response)
        do {
            guard let page = try AppStoreProductPage.parse(data, bundleID: app.bundleIdentifier, adamID: id, platform: platform, region: region)
            else { throw AppStoreResolutionError(kind: .identityMismatch) }
            guard page.platformVerified else { throw AppStoreResolutionError(kind: .platformUnknown) }
            guard let version = page.version else { throw CheckError.noMetadata }
            return .init(adamID: id, version: version, releaseNotes: page.releaseNotes, minimumMacOS: page.minimumMacOS,
                checkedAt: response.checkedAt, source: .productPage, sourceURL: url, isCached: response.isCached,
                pageAvailability: platform == .iOSOnMac ? page.macAvailability : nil)
        } catch {
            await AppStoreResource.invalidate(request, client: client, context: scope); throw error
        }
    }

    private static func search(app: AppInfo, region: String, platform: AppStoreQueryInfo.Platform,
        client: any HTTPClient, refresh: Bool) async throws -> AppStoreCatalogInfo? {
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [.init(name: "term", value: String(app.appName.prefix(80))), .init(name: "country", value: region),
            .init(name: "media", value: "software"), .init(name: "limit", value: "25"),
            .init(name: "entity", value: platform == .iOSOnMac ? "software" : "desktopSoftware")]
        let request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        let response = try await AppStoreResource.load(request, client: client, context: context(app, platform: platform), refresh: refresh)
        let parsed: Parsed
        do { parsed = try parseLookup(AppStoreResource.requireSuccess(response), bundleID: app.bundleIdentifier, platform: platform) }
        catch {
            await AppStoreResource.invalidate(request, client: client, context: context(app, platform: platform)); throw error
        }
        if let info = parsed.info { return info.withResponse(response, url: request.url!) }
        for id in parsed.pageIDs.sorted().prefix(3) {
            if let info = try await product(app: app, id: id, region: region, platform: platform, client: client, refresh: refresh) { return info }
        }
        return nil
    }

    static func prefetch(apps: [AppInfo], region: String, client: any HTTPClient) async {
        guard let cache = client as? AppStoreHTTPClient,
              region.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil else { return }
        for wrapped in [false, true] {
            let targets = apps.filter { $0.wrapped == wrapped && $0.adamID != nil }
            let ids = Set(targets.compactMap(\.adamID)).sorted()
            guard !ids.isEmpty, ids.count <= 100 else { continue }
            let entity = wrapped ? "software" : "desktopSoftware"
            var url = URLComponents(string: "https://itunes.apple.com/lookup")!
            url.queryItems = [.init(name: "id", value: ids.map(String.init).joined(separator: ",")),
                .init(name: "country", value: region), .init(name: "media", value: "software"),
                .init(name: "limit", value: "200"), .init(name: "entity", value: entity)]
            let request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
            do {
                let response = try await AppStoreResource.load(request, client: client, context: "batch|\(entity)")
                let data = try AppStoreResource.requireSuccess(response)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let count = object["resultCount"] as? Int, (0...200).contains(count),
                      let results = object["results"] as? [[String: Any]], results.count == count else {
                    await cache.invalidate(request, context: "batch|\(entity)"); continue
                }
                for app in targets {
                    let platform = AppStoreInstallation.platform(app)
                    let matches = results.filter { ($0["trackId"] as? NSNumber)?.uint64Value == app.adamID && $0["bundleId"] as? String == app.bundleIdentifier }
                    let single = try JSONSerialization.data(withJSONObject: ["resultCount": matches.count, "results": matches])
                    guard let parsed = try? parseLookup(single, bundleID: app.bundleIdentifier, platform: platform, expectedID: app.adamID),
                          parsed.info != nil else { continue }
                    let individual = lookupRequest(id: app.adamID, bundleID: app.bundleIdentifier, region: region, entity: entity)
                    await cache.seed(individual, context: context(app, platform: platform), data: single, checkedAt: response.checkedAt)
                }
            } catch { if Task.isCancelled { return } }
        }
    }
}

private extension AppStoreCatalogInfo {
    func withResponse(_ response: AppStoreHTTPResponse, url: URL) -> Self {
        var info = self; info.checkedAt = response.checkedAt; info.sourceURL = url; info.isCached = response.isCached; return info
    }
}
