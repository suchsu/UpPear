import Foundation

/// A product page is useful only when its main product, storefront and selected
/// platform agree. Recommendation shelves and JSON-LD are never version sources.
struct AppStoreProductPage: Sendable {
    var adamID: UInt64
    var bundleID: String
    var version: String?
    var releaseNotes: String?
    var macAvailability: AppStoreMacAvailability.Status
    var minimumMacOS: String?
    var platformVerified: Bool

    static func parse(_ data: Data, bundleID: String, adamID: UInt64,
        platform: AppStoreQueryInfo.Platform, region: String? = nil) throws -> Self? {
        guard data.count <= 6_000_000, let html = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
        let pattern = #"(?is)<script\b(?=[^>]*\bid\s*=\s*(?:"serialized-server-data"|'serialized-server-data'|serialized-server-data(?:\s|>)))[^>]*>(.*?)</script\s*>"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let object = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any],
              let pages = object["data"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        let matching = pages.filter { String(describing: ($0["intent"] as? [String: Any])?["id"] ?? "") == String(adamID) }
        guard matching.count == 1, let intent = matching[0]["intent"] as? [String: Any],
              let content = matching[0]["data"] as? [String: Any],
              let lockup = content["lockup"] as? [String: Any], lockup["bundleId"] as? String == bundleID,
              String(describing: lockup["adamId"] ?? "") == String(adamID) else { return nil }
        if let region {
            guard let storefront = intent["storefront"] as? String, storefront.lowercased() == region.lowercased() else { return nil }
        }
        let availability: AppStoreMacAvailability.Status
        if let allowed = lockup["isIOSBinaryMacOSCompatible"] as? Bool { availability = allowed ? .available : .unavailable }
        else { availability = .unknown }
        let shelves = content["shelfMapping"] as? [String: Any] ?? [:]
        let recent = shelves["mostRecentVersion"] as? [String: Any] ?? [:]
        let overview = (recent["items"] as? [[String: Any]])?.first
        let action = recent["seeAllAction"] as? [String: Any] ?? [:]
        let pageData = action["pageData"] as? [String: Any] ?? [:]
        let history = (pageData["shelves"] as? [[String: Any]])?.first
        let latest = (history?["items"] as? [[String: Any]])?.first
        let version = versionString(latest?["primarySubtitle"] as? String)
            ?? versionString(overview?["versionString"] as? String)
        let platforms = Set(content["appPlatforms"] as? [String] ?? [])
        let metrics = action["actionMetrics"] as? [String: Any] ?? [:]
        let contexts = Set((metrics["data"] as? [[String: Any]] ?? []).compactMap {
            ($0["fields"] as? [String: Any])?["platformContext"] as? String
        })
        let verified: Bool
        if platform == .iOSOnMac {
            verified = !platforms.isDisjoint(with: ["phone", "pad"]) &&
                ((!contexts.isEmpty && contexts.isSubset(of: ["iphone", "ipad"])) || (contexts.isEmpty && !platforms.contains("mac")))
        } else {
            // A compatible iOS binary is not a native Mac/Catalyst version.
            verified = platforms.contains("mac") && (contexts == ["mac"] || (contexts.isEmpty && platforms == ["mac"]))
        }
        var minimum: String?
        let information = (shelves["information"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        for row in information {
            for item in row["items"] as? [[String: Any]] ?? [] where item["heading"] as? String == "Mac" {
                if let text = item["text"] as? String,
                   let range = text.range(of: #"macOS\s*([0-9]+(?:\.[0-9]+){0,2})"#, options: .regularExpression) {
                    minimum = String(text[range]).replacingOccurrences(of: "macOS", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return Self(adamID: adamID, bundleID: bundleID, version: version, releaseNotes: overview?["text"] as? String,
            macAvailability: availability, minimumMacOS: minimum, platformVerified: verified)
    }

    private static func versionString(_ text: String?) -> String? {
        guard let text, text.range(of: #"^[0-9][0-9A-Za-z._+\-]{0,127}$"#, options: .regularExpression) != nil else { return nil }
        return text
    }
}

enum AppStoreInstallation {
    static func platform(_ app: AppInfo) -> AppStoreQueryInfo.Platform {
        guard !app.wrapped else { return .iOSOnMac }
        let plist = app.bundlePath.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.contains("/"), executable != "..",
              let handle = try? FileHandle(forReadingFrom: app.bundlePath.appendingPathComponent("Contents/MacOS/" + executable)) else { return .macOS }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4096) else { return .macOS }
        var offset = 0
        if prefix.count >= 28, prefix.prefix(4) == Data([0xca, 0xfe, 0xba, 0xbe]) {
            offset = Int(prefix.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).bigEndian })
        } else if prefix.count >= 40, prefix.prefix(4) == Data([0xca, 0xfe, 0xba, 0xbf]) {
            let start = prefix.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self).bigEndian }
            guard start <= UInt64(Int.max) else { return .macOS }
            offset = Int(start)
        }
        guard offset >= 0, (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let header = try? handle.read(upToCount: 32), header.count == 32,
              header.prefix(4) == Data([0xcf, 0xfa, 0xed, 0xfe]) else { return .macOS }
        let size = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self).littleEndian })
        guard size <= 1_000_000, let commands = try? handle.read(upToCount: size), commands.count == size else { return .macOS }
        return platformFromCommands(commands)
    }
    static func platformFromCommands(_ data: Data) -> AppStoreQueryInfo.Platform {
        var offset = 0
        while data.count - offset >= 8 {
            let command = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
            let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian })
            guard size >= 8, size <= data.count - offset else { return .macOS }
            if command == 0x32, size >= 24 {
                let platform = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self).littleEndian }
                if platform == 6 { return .macCatalyst }
            }
            offset += size
        }
        return .macOS
    }
}
