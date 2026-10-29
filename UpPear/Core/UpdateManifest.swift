import Foundation
import Darwin

// A deliberately limited data-only YAML reader. Supports the structures used
// by electron-builder, including folded scalars; never evaluates tags/anchors.
enum UpdateManifest {
    private struct Line { var indent: Int; var text: String }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2_000_000 else { throw SourceError.invalidManifest }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            guard let dict = json as? [String: Any] else { throw SourceError.invalidManifest }; return dict
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SourceError.invalidManifest }
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            guard !raw.contains("\t") else { throw SourceError.invalidManifest }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" || trimmed == "..." { continue }
            lines.append(Line(indent: raw.prefix(while: { $0 == " " }).count, text: trimmed))
        }
        var index = 0
        let value = try block(lines, index: &index, indent: lines.first?.indent ?? 0, depth: 0)
        guard index == lines.count, let result = value as? [String: Any] else { throw SourceError.invalidManifest }
        return result
    }

    private static func block(_ lines: [Line], index: inout Int, indent: Int, depth: Int) throws -> Any {
        guard depth < 12, index < lines.count else { throw SourceError.invalidManifest }
        if lines[index].text.hasPrefix("- ") {
            var items: [Any] = []
            while index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("- ") {
                let remainder = String(lines[index].text.dropFirst(2)); index += 1
                if let pair = keyValue(remainder) {
                    var item: [String: Any] = [:]
                    item[pair.0] = try value(pair.1, lines: lines, index: &index, parentIndent: indent + 2, depth: depth)
                    if index < lines.count, lines[index].indent > indent {
                        guard let tail = try block(lines, index: &index, indent: lines[index].indent, depth: depth + 1) as? [String: Any],
                              Set(tail.keys).isDisjoint(with: item.keys) else { throw SourceError.invalidManifest }
                        item.merge(tail) { _, new in new }
                    }
                    items.append(item)
                } else { items.append(try scalar(remainder)) }
            }
            return items
        }
        var result: [String: Any] = [:]
        while index < lines.count, lines[index].indent == indent {
            guard let pair = keyValue(lines[index].text), result[pair.0] == nil, pair.0 != "<<" else { throw SourceError.invalidManifest }
            index += 1
            result[pair.0] = try value(pair.1, lines: lines, index: &index, parentIndent: indent, depth: depth)
        }
        return result
    }

    private static func value(_ input: String, lines: [Line], index: inout Int, parentIndent: Int, depth: Int) throws -> Any {
        if [">", ">-", ">+", "|", "|-", "|+"].contains(input) {
            var values: [String] = []
            while index < lines.count, lines[index].indent > parentIndent { values.append(lines[index].text); index += 1 }
            return values.joined(separator: input.hasPrefix(">") ? " " : "\n")
        }
        if input.isEmpty, index < lines.count, lines[index].indent > parentIndent {
            return try block(lines, index: &index, indent: lines[index].indent, depth: depth + 1)
        }
        return try scalar(input)
    }

    private static func keyValue(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard key.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return (key, String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func scalar(_ input: String) throws -> Any {
        if input.hasPrefix("\"") {
            guard let value = try? JSONSerialization.jsonObject(with: Data(input.utf8), options: .fragmentsAllowed) as? String else { throw SourceError.invalidManifest }
            return value
        }
        if input.hasPrefix("'") {
            guard input.hasSuffix("'"), input.count >= 2 else { throw SourceError.invalidManifest }
            return String(input.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard !["&", "*", "!", "[", "{"].contains(where: input.hasPrefix) else { throw SourceError.invalidManifest }
        let value = input.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        if value == "true" { return true }; if value == "false" { return false }
        if let number = Int(value) { return number }
        return value
    }
}

struct UpdatePlatform: Sendable {
    var architecture: String
    var macOS: String
    var darwin: String
    static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var uts = utsname(); uname(&uts)
        let kernel = withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return Self(architecture: architecture, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", darwin: kernel)
    }

    func acceptsAsset(_ name: String, context: String = "", explicitRule: Bool = false) -> Bool {
        let text = name.lowercased(), evidence = (name + " " + context).lowercased()
        guard ["zip", "dmg", "pkg"].contains(URL(fileURLWithPath: text).pathExtension),
              !["windows", "win32", "win64", ".exe", "linux", "appimage", "symbols", "debug", "source", "blockmap"].contains(where: text.contains) else { return false }
        if text.range(of: #"(?:^|[._-])win(?:[._-]|$)"#, options: .regularExpression) != nil { return false }
        let arm = evidence.range(of: #"(?:^|[^a-z0-9])(arm64|aarch64)(?:[^a-z0-9]|$)"#, options: .regularExpression) != nil
        let intel = evidence.range(of: #"(?:^|[^a-z0-9])(x64|x86_64|amd64|intel)(?:[^a-z0-9]|$)"#, options: .regularExpression) != nil
        let universal = evidence.contains("universal") || (arm && intel)
        if !universal, (architecture == "arm64" && intel) || (architecture != "arm64" && arm) { return false }
        return explicitRule || [".dmg", ".pkg", "mac", "darwin", "osx", "universal"].contains(where: evidence.contains)
    }
}
