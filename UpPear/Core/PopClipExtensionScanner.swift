// Added for UpPear 1.1. Read metadata only; never execute extension code or
// write to PopClip's installation, preferences, signatures or licensing files.
import Foundation

public struct PopClipUpdateInfo: Codable, Sendable {
    public let identifier: String?
    public let packageURL: URL
    public let host: AppInfo
    public var latestVersion: String?
    public var compatibleVersion: String?
    public var minimumHostBuild: Int?
    public var minimumHostVersion: String?
    public var minimumMacOS: String?
    public var compatibility: String?
    public var detailURL: URL?
    public var downloadURL: URL?
    public var checkedAt: Date?
    public var isCached = false
    public var isStale = false
}

struct InstalledPopClipExtension: Sendable {
    var id: String { "popclip:" + path.standardizedFileURL.path }
    let path: URL
    let name: String
    let identifier: String?
    // The directory's release number comes from publisher signature metadata,
    // never Config.popclipVersion (which is a minimum host build).
    let version: String?
    let shortcode: String?
    let issue: String?
}

struct PopClipInventory: Sendable {
    let extensions: [InstalledPopClipExtension]
    let warnings: [String]
}

struct PopClipConfigMetadata: Sendable {
    var name: String?
    var identifier: String?
    var minimumBuild: Int?
    var minimumMacOS: String?
    var requirementsReliable = true
    var recognized = false

    static func read(_ data: Data, fileName: String) throws -> Self {
        let dictionary: [String: Any]
        if fileName == "Config.plist" {
            guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CheckError.invalidResponse
            }
            dictionary = value
        } else if fileName == "Config.json" {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CheckError.invalidResponse
            }
            dictionary = value
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
            dictionary = scalarHeader(text, yaml: fileName == "Config.yaml" || fileName == "Config.yml")
        }
        var values: [String: Any] = [:]
        for (key, value) in dictionary { values[normalized(key)] = value }
        var result = Self()
        result.name = localized(values["name"] ?? values["extensionname"])
        result.identifier = (values["identifier"] ?? values["extensionidentifier"]) as? String
        let build = values["popclipversion"] ?? values["requiredsoftwareversion"]
        if let build {
            result.minimumBuild = integer(build)
            result.requirementsReliable = result.minimumBuild != nil
        }
        if let os = values["macosversion"] {
            result.minimumMacOS = string(os)
            result.requirementsReliable = result.requirementsReliable && validOSVersion(result.minimumMacOS)
        }
        result.recognized = result.name != nil || result.identifier != nil
        return result
    }

    static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    static func integer(_ value: Any?) -> Int? {
        guard let text = string(value), let value = Int(text), value > 0 else { return nil }
        return value
    }
    static func validOSVersion(_ value: String?) -> Bool {
        value?.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil
    }
    private static func localized(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let map = value as? [String: String] { return map["zh-Hans"] ?? map["zh_CN"] ?? map["en"] ?? map.values.first }
        return nil
    }

    // Only scalar top-level header fields are needed. No general YAML or JS
    // evaluation: nested action/option identifiers cannot become package IDs.
    private static func scalarHeader(_ text: String, yaml: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        var inBlock = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.replacingOccurrences(of: "\u{feff}", with: "")
            if !yaml {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/*") { inBlock = true; line = String(trimmed.dropFirst(2)) }
                else if trimmed.hasPrefix("//") { line = String(trimmed.dropFirst(2)) }
                else if inBlock { line = trimmed.hasPrefix("* ") ? String(trimmed.dropFirst(2)) : line }
                else if trimmed.isEmpty { continue }
                else { break }
                if line.contains("*/") { line = line.components(separatedBy: "*/")[0]; inBlock = false }
                // A single conventional space after // or * is not YAML indent.
                if line.first == " " { line.removeFirst() }
            }
            guard line.first != " ", line.first != "\t", !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = normalized(String(line[..<colon]))
            guard ["name", "identifier", "popclipversion", "macosversion"].contains(key) else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.first == "\"", let data = value.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) { value = decoded }
            else if value.first == "'", value.last == "'" {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else { value = value.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces) }
            if !value.isEmpty && !value.hasPrefix("{") && !value.hasPrefix("[") { result[key] = value }
        }
        return result
    }
}

enum PopClipExtensionScanner {
    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Application Support/PopClip/Extensions", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.pilotmoon.popclip/Data/Library/Application Support/PopClip/Extensions", isDirectory: true)]
    }
    static let configNames = ["Config.plist", "Config.json", "Config.yaml", "Config.yml", "Config.ts", "Config.js", "Config.applescript", "Config"]

    static func scan(roots: [URL] = defaultRoots) -> PopClipInventory {
        let fm = FileManager.default
        var extensions: [InstalledPopClipExtension] = []
        var warnings: [String] = []
        var seen: Set<String> = []
        for root in roots where fm.fileExists(atPath: root.path) {
            do {
                for path in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)
                    where path.pathExtension.lowercased() == "popclipext" {
                    guard seen.insert(path.resolvingSymlinksInPath().path).inserted else { continue }
                    do { extensions.append(try read(path)) }
                    catch {
                        extensions.append(InstalledPopClipExtension(path: path,
                            name: path.deletingPathExtension().lastPathComponent, identifier: nil, version: nil,
                            shortcode: nil, issue: "扩展元数据无法读取：\(error.localizedDescription)"))
                    }
                }
            } catch { warnings.append("PopClip 扩展目录无法读取：\(error.localizedDescription)") }
        }
        return PopClipInventory(extensions: extensions, warnings: warnings)
    }

    static func read(_ path: URL) throws -> InstalledPopClipExtension {
        guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CheckError.invalidResponse
        }
        var metadata: [PopClipConfigMetadata] = []
        for name in configNames {
            let file = path.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CheckError.invalidResponse }
            let data = try Data(contentsOf: file)
            guard data.count <= 2 * 1024 * 1024 else { throw CheckError.invalidResponse }
            metadata.append(try PopClipConfigMetadata.read(data, fileName: name))
        }
        guard !metadata.isEmpty else { throw CheckError.noMetadata }
        let identifiers = Set(metadata.compactMap(\.identifier))
        guard identifiers.count <= 1 else { throw CheckError.invalidResponse }
        let identifier = identifiers.first
        var release: String?
        var shortcode: String?
        let signature = path.appendingPathComponent("_Signature.plist")
        if FileManager.default.fileExists(atPath: signature.path) {
            guard try signature.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CheckError.invalidResponse }
            let data = try Data(contentsOf: signature)
            guard data.count < 1024 * 1024,
                  let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let meta = dictionary["Metadata"] as? [String: Any],
                  let signedID = meta["identifier"] as? String,
                  signedID == identifier else { throw CheckError.invalidResponse }
            release = PopClipConfigMetadata.string(meta["version"])
            shortcode = meta["shortcode"] as? String
        }
        return InstalledPopClipExtension(path: path,
            name: metadata.compactMap(\.name).first ?? path.deletingPathExtension().lastPathComponent,
            identifier: identifier, version: release, shortcode: shortcode, issue: nil)
    }
}
