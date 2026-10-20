// Added for UpPear 1.1. Publisher release metadata and explicit requirements
// determine updates; content/hash differences never establish an update.
import Foundation

enum PopClipCompatibility: Equatable, Sendable {
    case compatible, incompatible(String), unknown(String)
    var message: String {
        switch self {
        case .compatible: "兼容当前 PopClip 和 macOS"
        case .incompatible(let reason), .unknown(let reason): reason
        }
    }
}

enum PopClipCompatibilityChecker {
    static func check(minimumBuild: Int?, minimumMacOS: String?, host: AppInfo,
                      systemVersion: String) -> PopClipCompatibility {
        if let minimumBuild {
            guard let build = host.appBuildNumber.flatMap(Int.init), build > 0 else {
                return .unknown("无法读取当前 PopClip 构建号，暂不能确认兼容性。")
            }
            if build < minimumBuild { return .incompatible("需要 PopClip 构建 \(minimumBuild) 或更新，当前构建为 \(build)。") }
        }
        if let minimumMacOS {
            guard PopClipConfigMetadata.validOSVersion(minimumMacOS), PopClipConfigMetadata.validOSVersion(systemVersion) else {
                return .unknown("无法确认 macOS 版本要求。")
            }
            if numericCompare(systemVersion, minimumMacOS) == .orderedAscending {
                return .incompatible("需要 macOS \(minimumMacOS) 或更新。")
            }
        }
        return .compatible
    }
    static func numericCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").compactMap { UInt64($0) }
        let b = rhs.split(separator: ".").compactMap { UInt64($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0; let y = i < b.count ? b[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}

enum PopClipVersionResolver {
    static func compare(installed: String?, available: String) -> ComparisonResult? {
        guard let installed, !installed.isEmpty else { return nil }
        if installed == available { return .orderedSame }
        let pattern = #"^\d+(\.\d+)*$"#
        guard installed.range(of: pattern, options: .regularExpression) != nil,
              available.range(of: pattern, options: .regularExpression) != nil,
              (installed + "." + available).split(separator: ".").allSatisfy({ UInt64($0) != nil }) else { return nil }
        return PopClipCompatibilityChecker.numericCompare(installed, available)
    }
}

enum PopClipUpdateChecker {
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func check(host: AppInfo, inventory: PopClipInventory, ignoredIDs: Set<String>,
        client: PopClipDirectoryClient = PopClipDirectoryClient(),
        systemVersion: String = systemVersion,
        progress: @escaping @Sendable (String) async -> Void = { _ in }) async -> [UpdateRecord] {
        guard !inventory.extensions.isEmpty else { return [] }
        let active = inventory.extensions.filter { !ignoredIDs.contains($0.id) && $0.identifier != nil && $0.issue == nil }
        var index: PopClipDirectoryIndex?
        if !active.isEmpty { index = try? await client.index() }
        let directory = index
        return await checkInBatches(inventory.extensions) { local in
            var result = baseRecord(local, host: host)
            if ignoredIDs.contains(local.id) {
                result.state = .skipped; result.detail = "已忽略此扩展；不影响 PopClip 主程序或其他扩展的检查。"
            } else if let issue = local.issue {
                result.state = .failed; result.detail = issue
            } else if let identifier = local.identifier {
                do {
                    let matches = directory?.entries.filter { $0.identifier == identifier } ?? []
                    guard matches.count <= 1 else { throw CheckError.invalidResponse }
                    let entry: PopClipDirectoryEntry
                    if let match = matches.first { entry = match }
                    else if let shortcode = local.shortcode, PopClipDirectoryClient.validShortcode(shortcode) {
                        // Signed legacy/unlisted extensions can still resolve to
                        // their exact official page when the index is unavailable.
                        entry = PopClipDirectoryEntry(identifier: identifier, shortcode: shortcode, name: local.name)
                    } else {
                        result.state = directory == nil ? .failed : .unsupported
                        result.detail = directory == nil ? "官方目录暂不可用，无法匹配此扩展。" : "官方目录未收录此标识符；保留为自定义或未收录扩展。"
                        await progress(local.name)
                        return result
                    }
                    let page = try await client.page(entry)
                    let resources = (directory?.resources ?? []) + page.resources
                    result = resolve(local: local, host: host, page: page,
                        resources: resources, systemVersion: systemVersion)
                    if result.state == .incompatible,
                       !resources.contains(where: \.isStale),
                       PopClipVersionResolver.compare(installed: local.version, available: page.release.version) == .orderedAscending {
                        let history = (page.release.previousVersions ?? []).filter {
                            PopClipVersionResolver.compare(installed: local.version, available: $0.version) == .orderedAscending
                        }.sorted {
                            PopClipVersionResolver.compare(installed: $0.version, available: $1.version) == .orderedDescending
                        }
                        var verified = false
                        for previous in history.prefix(20) {
                            if Task.isCancelled { break }
                            do {
                                let archived = try await PopClipArchiveMetadata.read(previous.download, identifier: identifier,
                                    version: previous.version, cache: client.cache)
                                guard !archived.resource.isStale else { continue }
                                let compatibility = PopClipCompatibilityChecker.check(minimumBuild: archived.config.minimumBuild,
                                    minimumMacOS: archived.config.minimumMacOS, host: host, systemVersion: systemVersion)
                                if compatibility == .compatible {
                                    result.state = .updateAvailable
                                    result.availableVersion = previous.version
                                    result.detail = "最新版 \(page.release.version) 不兼容当前环境；已核实历史版本 \(previous.version) 可以更新。由 PopClip 确认安装。"
                                    result.popClip?.compatibleVersion = previous.version
                                    result.popClip?.downloadURL = previous.download
                                    result.popClip?.minimumHostBuild = archived.config.minimumBuild
                                    result.popClip?.minimumHostVersion = nil
                                    result.popClip?.minimumMacOS = archived.config.minimumMacOS
                                    result.popClip?.compatibility = "版本 \(previous.version) 兼容；最新版 \(page.release.version) 不兼容。"
                                    result.releaseNotes = nil
                                    result.releaseDate = nil
                                    verified = true
                                    break
                                }
                            } catch { continue }
                        }
                        if !verified { result.detail += " 未找到已核实的兼容更新，可查看官方历史版本。" }
                    }
                } catch {
                    if let directory, !directory.entries.contains(where: { $0.identifier == identifier }),
                       let error = error as? CheckError, case .httpStatus(404) = error {
                        result.state = .unsupported
                        result.detail = "官方目录已不再收录此扩展，旧详情页也已移除；无法自动确认更新。"
                    } else {
                        result.state = .failed
                        result.detail = "官方扩展信息暂不可用：\(error.localizedDescription) 请稍后重新检查。"
                    }
                }
            }
            await progress(local.name)
            return result
        }
    }

    static func baseRecord(_ local: InstalledPopClipExtension, host: AppInfo) -> UpdateRecord {
        var result = UpdateRecord(app: nil, source: .popClip, state: .unsupported,
            detail: "自定义扩展或 Snippet 缺少可匹配的唯一标识符，无法确认官方更新。",
            id: local.id, name: "PopClip · \(local.name)", installedVersion: local.version ?? "")
        result.popClip = PopClipUpdateInfo(identifier: local.identifier, packageURL: local.path, host: host)
        return result
    }

    static func resolve(local: InstalledPopClipExtension, host: AppInfo, page: PopClipDirectoryPage,
                        resources: [PopClipResource], systemVersion: String) -> UpdateRecord {
        var result = baseRecord(local, host: host)
        let release = page.release
        let compatibility = PopClipCompatibilityChecker.check(minimumBuild: release.popclipVersion,
            minimumMacOS: release.macosVersion, host: host, systemVersion: systemVersion)
        result.availableVersion = release.version
        result.releaseNotes = release.readme
        result.releaseNotesURL = page.detailURL
        result.releaseDate = release.sourceDate
        result.homepage = page.detailURL
        result.popClip?.latestVersion = release.version
        result.popClip?.minimumHostBuild = release.popclipVersion
        result.popClip?.minimumHostVersion = release.popclipDisplayVersion
        result.popClip?.minimumMacOS = release.macosVersion
        result.popClip?.compatibility = compatibility.message
        result.popClip?.detailURL = page.detailURL
        result.popClip?.checkedAt = resources.map(\.checkedAt).min()
        result.popClip?.isCached = resources.contains(where: \.isCached)
        result.popClip?.isStale = resources.contains(where: \.isStale)
        guard !resources.contains(where: \.isStale) else {
            result.state = .failed
            result.detail = "官网暂不可用，保留上次版本信息与数据时间；重新核实前不计为可用更新。"
            return result
        }
        let relation = PopClipVersionResolver.compare(installed: local.version, available: release.version)
        if relation == .orderedDescending {
            result.state = .current; result.detail = "已安装发布版本高于官方目录版本，不提供降级。"
        } else if case .incompatible(let reason) = compatibility {
            result.state = .incompatible; result.detail = "官方版本 \(release.version) 不适用于当前环境。\(reason)"
        } else if case .unknown(let reason) = compatibility {
            result.state = .unverified; result.detail = reason
        } else if relation == nil {
            result.state = .unverified
            result.detail = "本地没有可比较的官方发布版本。已匹配官方标识符，但不能确定更新关系。"
        } else if relation == .orderedAscending {
            result.state = .updateAvailable
            result.detail = "官方已发布兼容更新。下载扩展包后打开，由 PopClip 确认安装，再重新检查。"
            result.popClip?.compatibleVersion = release.version
            result.popClip?.downloadURL = release.download
        } else {
            result.state = .current; result.detail = "本地发布版本与官方目录一致。"
        }
        return result
    }
}

enum PopClipArchiveMetadata {
    struct Result: Sendable {
        let config: PopClipConfigMetadata
        let resource: PopClipResource
    }
    static func read(_ url: URL, identifier: String, version: String, cache: PopClipResourceCache) async throws -> Result {
        guard PopClipURLPolicy.isDownload(url) else { throw CheckError.invalidResponse }
        let resource = try await cache.fetch(url, ttl: 7 * 86400)
        let entries = try metadataEntries(resource.data)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("UpPear-PopClip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("extension.zip")
        try resource.data.write(to: archive)
        func extract(_ name: String) async throws -> Data {
            let value = try await CommandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-p", archive.path, name], timeout: 10)
            guard value.exitCode == 0, value.output.utf8.count <= 2 * 1024 * 1024 else { throw CheckError.invalidResponse }
            return Data(value.output.utf8)
        }
        guard let signature = entries.first(where: { $0.hasSuffix("/_Signature.plist") }),
              let dictionary = try PropertyListSerialization.propertyList(from: try await extract(signature), format: nil) as? [String: Any],
              let metadata = dictionary["Metadata"] as? [String: Any], metadata["identifier"] as? String == identifier,
              PopClipConfigMetadata.string(metadata["version"]) == version else { throw CheckError.invalidResponse }
        var configs: [PopClipConfigMetadata] = []
        for entry in entries where PopClipExtensionScanner.configNames.contains(URL(fileURLWithPath: entry).lastPathComponent) {
            configs.append(try PopClipConfigMetadata.read(try await extract(entry), fileName: URL(fileURLWithPath: entry).lastPathComponent))
        }
        guard !configs.isEmpty, configs.allSatisfy({ $0.recognized && $0.requirementsReliable }),
              configs.compactMap(\.identifier).allSatisfy({ $0 == identifier }) else { throw CheckError.invalidResponse }
        var combined = configs[0]
        combined.minimumBuild = configs.compactMap(\.minimumBuild).max()
        combined.minimumMacOS = configs.compactMap(\.minimumMacOS).max {
            PopClipCompatibilityChecker.numericCompare($0, $1) == .orderedAscending
        }
        return Result(config: combined, resource: resource)
    }

    // Inspect central-directory sizes before decompressing metadata. No archive
    // paths are ever extracted to disk, so symlinks/path traversal cannot write
    // into PopClip or elsewhere. Reject duplicates, ZIP64 and large metadata.
    static func metadataEntries(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        func word(_ i: Int) -> UInt32 {
            guard i >= 0, i + 4 <= bytes.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(bytes[i+$1]) << (8*$1) }
        }
        func short(_ i: Int) -> Int { Int(word(i) & 0xffff) }
        guard bytes.count >= 22,
              let eocd = stride(from: bytes.count-22, through: max(0, bytes.count-65557), by: -1)
                .first(where: { word($0) == 0x06054b50 }),
              short(eocd+8) == short(eocd+10), short(eocd+10) < 1024 else { throw CheckError.invalidResponse }
        var cursor = Int(word(eocd+16))
        var result: [String] = []
        var names: Set<String> = []
        var roots: Set<String> = []
        for _ in 0..<short(eocd+10) {
            guard cursor + 46 <= bytes.count, word(cursor) == 0x02014b50 else { throw CheckError.invalidResponse }
            let length = short(cursor+28), extra = short(cursor+30), comment = short(cursor+32)
            guard cursor + 46 + length + extra + comment <= bytes.count,
                  let name = String(bytes: bytes[cursor+46..<cursor+46+length], encoding: .utf8),
                  names.insert(name).inserted else { throw CheckError.invalidResponse }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !components.contains(".."), !name.contains("\\") else { throw CheckError.invalidResponse }
            if components.count == 2,
               components[0].hasSuffix(".popclipext"),
               PopClipExtensionScanner.configNames.contains(String(components[1])) || components[1] == "_Signature.plist" {
                guard word(cursor+24) <= 2 * 1024 * 1024, short(cursor+8) & 1 == 0,
                      !name.contains(where: { "*?[]".contains($0) }),
                      (word(cursor+38) >> 16) & 0xf000 != 0xa000 else { throw CheckError.invalidResponse }
                roots.insert(String(components[0])); result.append(name)
            }
            cursor += 46 + length + extra + comment
        }
        guard roots.count == 1, !result.isEmpty else { throw CheckError.invalidResponse }
        return result
    }
}
