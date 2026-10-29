import Foundation

public struct AppStoreMacAvailability: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, unavailable, unknown }
    public var status: Status
    public var checkedAt: Date
    public var pageURL: URL
}

enum AppStoreMacChecker {
    static func check(bundleID: String, adamID: UInt64, region: String, client: any HTTPClient) async throws -> AppStoreMacAvailability {
        guard region.range(of: #"^[A-Za-z]{2}$"#, options: .regularExpression) != nil else { throw CheckError.invalidResponse }
        let url = URL(string: "https://apps.apple.com/\(region.lowercased())/app/id\(adamID)")!
        let data = try await client.fetch(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15))
        let status = try parse(data, bundleID: bundleID, adamID: adamID)
        return AppStoreMacAvailability(status: status, checkedAt: Date(), pageURL: url)
    }

    static func parse(_ data: Data, bundleID: String, adamID: UInt64) throws -> AppStoreMacAvailability.Status {
        guard data.count <= 4_000_000, let html = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
        let pattern = #"(?is)<script\b(?=[^>]*\bid\s*=\s*(?:"serialized-server-data"|'serialized-server-data'|serialized-server-data(?:\s|>)))[^>]*>(.*?)</script\s*>"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let object = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any],
              let pages = object["data"] as? [[String: Any]] else { return .unknown }
        // Only the main product lockup is authoritative. Recommendations and
        // editorial shelves on the same page contain unrelated compatibility flags.
        let matching = pages.filter { page in
            guard let intent = page["intent"] as? [String: Any] else { return false }
            return String(describing: intent["id"] ?? "") == String(adamID)
        }
        guard matching.count == 1, let content = matching[0]["data"] as? [String: Any],
              let lockup = content["lockup"] as? [String: Any],
              lockup["bundleId"] as? String == bundleID,
              String(describing: lockup["adamId"] ?? "") == String(adamID),
              let compatible = lockup["isIOSBinaryMacOSCompatible"] as? Bool else { return .unknown }
        return compatible ? .available : .unavailable
    }
}
