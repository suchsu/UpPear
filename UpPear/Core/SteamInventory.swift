import Foundation

public struct SteamUpdateInfo: Codable, Sendable {
    public var appID: String?
    public var buildID: String?
    public var branch: String?
    public var installationConfirmed: Bool
    public var libraryURL: URL?
    public var manifestModifiedAt: Date?
    public var launchers: [URL]
}

struct SteamInventory: Sendable {
    var records: [UpdateRecord]
    var ownedApplicationIDs: Set<String>
    var warnings: [String]

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    }

    static func scan(apps: [AppInfo], root: URL = defaultRoot) -> Self {
        let manager = FileManager.default
        var records: [UpdateRecord] = [], warnings: [String] = []
        var owned = Set<String>()
        let clients = apps.filter { $0.bundleIdentifier == "com.valvesoftware.steam" && !$0.isAppStore }
        for client in clients {
            owned.insert(client.id)
            var record = UpdateRecord(app: client, source: .steam, state: .managed,
                detail: "Steam 客户端由自身更新器管理。打开 Steam 检查客户端及下载队列；没有将本地版本当作已是最新版。")
            record.steam = SteamUpdateInfo(installationConfirmed: true, launchers: [client.path])
            records.append(record)
        }
        let launchers = Dictionary(grouping: apps.compactMap { app -> (String, AppInfo)? in
            guard !app.isAppStore, let id = launcherID(app: app) else { return nil }
            return (id, app)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        launchers.values.flatMap { $0 }.forEach { owned.insert($0.id) }
        var libraries: [URL] = manager.fileExists(atPath: root.path) ? [root] : []
        let folders = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if manager.fileExists(atPath: folders.path) {
            do {
                let data = try boundedData(folders)
                let parsed = try ValveKeyValues.parse(data)
                guard let entries = parsed["libraryfolders"] as? [String: Any] else { throw SourceError.invalidManifest }
                for (index, entry) in entries where index.allSatisfy(\.isNumber) {
                    let path = (entry as? [String: Any])?["path"] as? String ?? entry as? String
                    if let path, path.hasPrefix("/"), !path.contains("\0") { libraries.append(URL(fileURLWithPath: path)) }
                }
            } catch { warnings.append("Steam 库目录无法读取：\(error.localizedDescription)") }
        }
        var games: [String: UpdateRecord] = [:]
        for library in Set(libraries.map { $0.resolvingSymlinksInPath().standardizedFileURL }) {
            let steamapps = library.appendingPathComponent("steamapps")
            guard manager.fileExists(atPath: steamapps.path) else { continue }
            do {
                let manifests = try manager.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
                for manifest in manifests {
                    do {
                        let object = try ValveKeyValues.parse(boundedData(manifest))
                        guard let game = object["AppState"] as? [String: Any],
                              let id = game["appid"] as? String, validID(id),
                              manifest.lastPathComponent == "appmanifest_\(id).acf",
                              let name = game["name"] as? String, !name.isEmpty,
                              let directory = game["installdir"] as? String,
                              !directory.isEmpty, !directory.hasPrefix("/"),
                              !directory.components(separatedBy: "/").contains(".."), !directory.contains("\\") else { throw SourceError.invalidManifest }
                        let common = steamapps.appendingPathComponent("common").resolvingSymlinksInPath().standardizedFileURL
                        let installation = common.appendingPathComponent(directory).resolvingSymlinksInPath().standardizedFileURL
                        var isDirectory: ObjCBool = false
                        let exists = installation.path.hasPrefix(common.path + "/") &&
                            manager.fileExists(atPath: installation.path, isDirectory: &isDirectory) && isDirectory.boolValue
                        let build = game["buildid"] as? String
                        let branch = (game["UserConfig"] as? [String: Any])?["BetaKey"] as? String
                        let shortcuts = launchers[id] ?? []
                        var record = UpdateRecord(app: shortcuts.first, source: .steam, state: exists ? .managed : .unverified,
                            detail: exists ? "已核实 Steam 安装清单及游戏目录。版本使用本地 build ID，更新与分支可用性由 Steam 实时确认；本地 StateFlags 不代表当前远端状态。"
                                : "存在 Steam 清单，但未找到游戏安装目录，安装尚未确认。请在 Steam 中核实。",
                            id: "steam:" + id, name: name, installedVersion: build.map { "build " + $0 } ?? "未知构建")
                        record.steam = SteamUpdateInfo(appID: id, buildID: build, branch: branch ?? "public",
                            installationConfirmed: exists, libraryURL: library,
                            manifestModifiedAt: try? manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                            launchers: shortcuts.map(\.path))
                        if let prior = games[id], prior.steam?.installationConfirmed == true, exists {
                            var conflict = prior; conflict.state = .unverified
                            conflict.detail = "在多个 Steam 库中发现此游戏的安装清单，请在 Steam 中确认实际安装和分支。"
                            games[id] = conflict
                        } else if games[id]?.steam?.installationConfirmed != true { games[id] = record }
                    } catch { warnings.append("无法核实 Steam 清单 \(manifest.lastPathComponent)：\(error.localizedDescription)") }
                }
            } catch { warnings.append("Steam 库读取失败：\(error.localizedDescription)") }
        }
        for (id, shortcuts) in launchers where games[id] == nil {
            var record = UpdateRecord(app: shortcuts.first, source: .steam, state: .unverified,
                detail: "仅发现 Steam 启动入口，没有可核实的安装清单和目录；未计为已安装或最新版。",
                id: "steam:" + id, name: shortcuts.first?.appName, installedVersion: "未确认安装")
            record.steam = SteamUpdateInfo(appID: id, installationConfirmed: false, launchers: shortcuts.map(\.path))
            games[id] = record
        }
        records += games.values
        return Self(records: records, ownedApplicationIDs: owned, warnings: warnings)
    }

    static func launcherID(app: AppInfo) -> String? {
        let plist = app.bundlePath.appendingPathComponent("Contents/Info.plist")
        guard let data = try? boundedData(plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        for key in ["SteamAppId", "SteamAppID"] {
            if let value = info[key], validID(String(describing: value)) { return String(describing: value) }
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              !executable.contains("/"), executable != "..",
              let script = try? boundedData(app.bundlePath.appendingPathComponent("Contents/MacOS/" + executable)),
              script.count < 64_000, let text = String(data: script, encoding: .utf8), text.hasPrefix("#!") else { return nil }
        let regex = try? NSRegularExpression(pattern: #"steam://(?:rungameid|run)/(\d+)"#)
        guard let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)),
              matches.count == 1, let range = Range(matches[0].range(at: 1), in: text), validID(String(text[range])) else { return nil }
        return String(text[range])
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: #"^[1-9][0-9]{0,11}$"#, options: .regularExpression) != nil
    }

    private static func boundedData(_ url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw SourceError.invalidManifest }
        return try Data(contentsOf: url)
    }
}

enum ValveKeyValues {
    static func parse(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { throw SourceError.invalidManifest }
        let characters = Array(text); var index = 0
        func token() throws -> String? {
            while index < characters.count {
                if characters[index].isWhitespace { index += 1; continue }
                if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }; continue
                }
                break
            }
            guard index < characters.count else { return nil }
            if characters[index] == "{" || characters[index] == "}" { defer { index += 1 }; return String(characters[index]) }
            guard characters[index] == "\"" else { throw SourceError.invalidManifest }; index += 1
            var result = ""
            while index < characters.count {
                let char = characters[index]; index += 1
                if char == "\"" { return result }
                if char == "\\" {
                    guard index < characters.count, ["\\", "\""].contains(characters[index]) else { throw SourceError.invalidManifest }
                    result.append(characters[index]); index += 1
                } else { result.append(char) }
            }
            throw SourceError.invalidManifest
        }
        func object(depth: Int, nested: Bool) throws -> [String: Any] {
            guard depth < 16 else { throw SourceError.invalidManifest }
            var result: [String: Any] = [:]
            while let key = try token() {
                if key == "}" { if nested { return result }; throw SourceError.invalidManifest }
                guard key != "{", result[key] == nil, let value = try token(), value != "}" else { throw SourceError.invalidManifest }
                result[key] = value == "{" ? try object(depth: depth + 1, nested: true) : value
            }
            if nested { throw SourceError.invalidManifest }; return result
        }
        return try object(depth: 0, nested: false)
    }
}
