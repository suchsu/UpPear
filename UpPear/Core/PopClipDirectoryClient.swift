// Added for UpPear 1.1. Read the same JSON data embedded in PopClip's public
// directory. Discover hashed asset names from HTML; never evaluate JavaScript.
import Foundation
import CryptoKit

enum PopClipURLPolicy {
    static func isOfficial(_ url: URL) -> Bool {
        url.scheme == "https" && ["www.popclip.app", "public.popclip.app"].contains(url.host?.lowercased() ?? "") &&
            url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    static func isDownload(_ url: URL) -> Bool {
        isOfficial(url) && url.host == "public.popclip.app" &&
            url.path.range(of: #"^/extensions/[A-Za-z0-9_-]+/file$"#, options: .regularExpression) != nil
    }
}

struct PopClipResource: Codable, Sendable {
    let data: Data
    let checkedAt: Date
    var isCached = false
    var isStale = false
}

actor PopClipResourceCache {
    static let shared = PopClipResourceCache()
    private let root: URL
    private let client: any HTTPClient
    init(root: URL? = nil, client: any HTTPClient = NetworkClient()) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UpPear/PopClip", isDirectory: true)
        self.client = client
    }
    func fetch(_ url: URL, ttl: TimeInterval = 3600) async throws -> PopClipResource {
        guard PopClipURLPolicy.isOfficial(url) else { throw CheckError.invalidResponse }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = root.appendingPathComponent(key + ".json")
        var cached: PopClipResource?
        if let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(PopClipResource.self, from: data) {
            cached = saved
            if Date().timeIntervalSince(saved.checkedAt) >= 0 && Date().timeIntervalSince(saved.checkedAt) < ttl {
                var result = saved; result.isCached = true
                return result
            }
        }
        do {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            request.setValue("UpPear/1.1 (extension update check)", forHTTPHeaderField: "User-Agent")
            let data = try await client.fetch(request)
            try Task.checkCancellation()
            guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw CheckError.invalidResponse }
            let result = PopClipResource(data: data, checkedAt: Date())
            if let encoded = try? JSONEncoder().encode(result) {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try? encoded.write(to: path, options: .atomic)
            }
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if var cached { cached.isCached = true; cached.isStale = true; return cached }
            throw error
        }
    }
}

struct PopClipDirectoryEntry: Decodable, Sendable {
    let identifier: String
    let shortcode: String
    let name: String
}

struct PopClipPreviousRelease: Decodable, Sendable {
    let version: String
    let download: URL
}

struct PopClipRelease: Decodable, Sendable {
    let identifier: String
    let shortcode: String
    let name: String
    let version: String
    let download: URL
    let sourceDate: String?
    let popclipVersion: Int?
    let popclipDisplayVersion: String?
    let macosVersion: String?
    let readme: String?
    let previousVersions: [PopClipPreviousRelease]?
}

struct PopClipDirectoryIndex: Sendable {
    let entries: [PopClipDirectoryEntry]
    let resources: [PopClipResource]
}

struct PopClipDirectoryPage: Sendable {
    let release: PopClipRelease
    let detailURL: URL
    let resources: [PopClipResource]
}

struct PopClipDirectoryClient: Sendable {
    let cache: PopClipResourceCache
    init(cache: PopClipResourceCache = .shared) { self.cache = cache }

    func index() async throws -> PopClipDirectoryIndex {
        let url = URL(string: "https://www.popclip.app/extensions/")!
        let html = try await cache.fetch(url)
        let text = String(decoding: html.data, as: UTF8.self)
        guard let path = Self.capture(#"(/assets/chunks/extensions\.data\.[A-Za-z0-9_-]+\.js)"#, in: text),
              let asset = URL(string: path, relativeTo: url)?.absoluteURL else { throw CheckError.invalidResponse }
        let data = try await cache.fetch(asset, ttl: 86400)
        let entries = try JSONDecoder().decode([PopClipDirectoryEntry].self, from: EmbeddedJSON.read(data.data))
        guard !entries.isEmpty, entries.allSatisfy({ Self.validShortcode($0.shortcode) }) else { throw CheckError.invalidResponse }
        return PopClipDirectoryIndex(entries: entries, resources: [html, data])
    }

    func page(_ entry: PopClipDirectoryEntry) async throws -> PopClipDirectoryPage {
        guard Self.validShortcode(entry.shortcode) else { throw CheckError.invalidResponse }
        let url = URL(string: "https://www.popclip.app/extensions/x/\(entry.shortcode)")!
        let html = try await cache.fetch(url)
        let pattern = "(/assets/extensions_x_" + entry.shortcode + #"\.md\.[A-Za-z0-9_-]+\.(?:lean\.)?js)"#
        guard let path = Self.capture(pattern, in: String(decoding: html.data, as: UTF8.self)),
              let asset = URL(string: path, relativeTo: url)?.absoluteURL else { throw CheckError.invalidResponse }
        let data = try await cache.fetch(asset, ttl: 86400)
        struct Envelope: Decodable { let params: PopClipRelease }
        let release = try JSONDecoder().decode(Envelope.self, from: EmbeddedJSON.read(data.data)).params
        guard release.identifier == entry.identifier, release.shortcode == entry.shortcode,
              !release.version.isEmpty, PopClipURLPolicy.isDownload(release.download),
              release.popclipVersion.map({ $0 > 0 }) ?? true,
              release.macosVersion.map({ PopClipConfigMetadata.validOSVersion($0) }) ?? true else {
            throw CheckError.invalidResponse
        }
        return PopClipDirectoryPage(release: release, detailURL: url, resources: [html, data])
    }

    static func validShortcode(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]{6}$"#, options: .regularExpression) != nil
    }
    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum EmbeddedJSON {
    // Decode only the literal argument of JSON.parse. No imports, expressions,
    // template interpolation or downloaded JavaScript can execute in UpPear.
    static func read(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), let start = text.range(of: "JSON.parse(") else {
            throw CheckError.invalidResponse
        }
        let chars = Array(text[start.upperBound...].drop(while: { $0.isWhitespace }))
        guard let delimiter = chars.first, ["'", "\"", "`"].contains(delimiter) else { throw CheckError.invalidResponse }
        var output = ""
        var i = 1
        while i < chars.count {
            let char = chars[i]; i += 1
            if char == delimiter {
                guard let data = output.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else { throw CheckError.invalidResponse }
                return data
            }
            if char == "$", delimiter == "`", i < chars.count, chars[i] == "{" { throw CheckError.invalidResponse }
            guard char == "\\" else { output.append(char); continue }
            guard i < chars.count else { throw CheckError.invalidResponse }
            let escaped = chars[i]; i += 1
            switch escaped {
            case "'", "\"", "`", "\\", "/", "$": output.append(escaped)
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "b": output.append("\u{8}")
            case "f": output.append("\u{c}")
            case "\n": break
            case "u":
                guard i + 4 <= chars.count, var value = UInt32(String(chars[i..<i+4]), radix: 16) else { throw CheckError.invalidResponse }
                i += 4
                if (0xD800...0xDBFF).contains(value) {
                    guard i + 6 <= chars.count, chars[i] == "\\", chars[i+1] == "u",
                          let low = UInt32(String(chars[i+2..<i+6]), radix: 16), (0xDC00...0xDFFF).contains(low) else {
                        throw CheckError.invalidResponse
                    }
                    value = 0x10000 + ((value - 0xD800) << 10) + low - 0xDC00; i += 6
                }
                guard let scalar = UnicodeScalar(value) else { throw CheckError.invalidResponse }
                output.unicodeScalars.append(scalar)
            default: throw CheckError.invalidResponse
            }
        }
        throw CheckError.invalidResponse
    }
}
