// Homebrew updater extracted/adapted from Pearcleaner 5.4.3
// HomebrewController.swift, created by Alin Lupascu on 10/01/25.
// Modified for UpPear on 2026-10-13. See LICENSE.md / docs/PROVENANCE.md.
// Retains Cellar/Caskroom metadata, public API checks, actual-app-vs-receipt
// maximum version, bundle tiebreakers, revision-aware Formula comparison and
// static tap version parsing. Removes install/uninstall/cleanup dependencies.
// 2026-10-14: resolve API variations using Homebrew's own current platform tag,
// preserving its exact-tag shallow-merge semantics, without guessed OS names.
import Foundation

struct InstalledPackage: Sendable {
    let name: String
    let displayName: String?
    let version: String
    let isCask: Bool
    let isPinned: Bool
    let tap: String?
    let tapRbPath: String?
    let app: AppInfo?
    let brewExecutable: URL
    var id: String { app?.id ?? "brew:\(brewExecutable.path):\(isCask ? "cask" : "formula"):\(name)" }
    var source: UpdateSource { isCask ? .homebrewCask : .homebrewFormula }
}

struct BrewInventory: Sendable {
    let packages: [InstalledPackage]
    let warnings: [String]
}

enum HomebrewUpdateChecker {
    static var executable: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    static func loadInstalledPackages(apps: [AppInfo], includeFormulae: Bool,
                                      brewExecutable: URL? = executable) -> BrewInventory {
        guard let brewExecutable else { return BrewInventory(packages: [], warnings: ["未安装 Homebrew；其他更新源仍可检查。"]) }
        let prefix = brewExecutable.deletingLastPathComponent().deletingLastPathComponent()
        var packages: [InstalledPackage] = []
        var warnings: [String] = []
        for isCask in includeFormulae ? [true, false] : [true] {
            let room = prefix.appendingPathComponent(isCask ? "Caskroom" : "Cellar", isDirectory: true)
            guard FileManager.default.fileExists(atPath: room.path) else { continue }
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: room.path) where !name.hasPrefix(".") {
                    let directory = room.appendingPathComponent(name, isDirectory: true)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
                       attrs[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                    let metadata = isCask ? directory.appendingPathComponent(".metadata") : directory
                    let versions = (try? FileManager.default.contentsOfDirectory(atPath: metadata.path))?
                        .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".json") } ?? []
                    guard let latestVersion = versions.sorted(by: { PkgVersion($0) < PkgVersion($1) }).last else {
                        warnings.append("无法读取 Homebrew 安装记录：\(name)")
                        continue
                    }
                    let receiptURL = isCask ? metadata.appendingPathComponent("INSTALL_RECEIPT.json")
                        : directory.appendingPathComponent("\(latestVersion)/INSTALL_RECEIPT.json")
                    guard let receipt = jsonDictionary(at: receiptURL) else {
                        warnings.append("Homebrew 安装收据缺失：\(name)")
                        continue
                    }
                    let source = receipt["source"] as? [String: Any]
                    let tap = source?["tap"] as? String ?? receipt["tap"] as? String
                    let fullName = (tap != nil && tap != "homebrew/core" && tap != "homebrew/cask") ? "\(tap!)/\(name)" : name
                    let artifactMatches = isCask ? matchInstalledApp(receipt: receipt, caskDirectory: directory,
                        version: latestVersion, apps: apps) : []
                    // A MAS app can leave stale Caskroom metadata behind. Its
                    // receipt owns the channel, so do not create a second row.
                    if artifactMatches.contains(where: \.isAppStore) { continue }
                    let pinned = !isCask && FileManager.default.fileExists(atPath: prefix.appendingPathComponent("var/homebrew/pinned/\(name)").path)
                    let matched: [AppInfo?] = artifactMatches.isEmpty ? [nil] : artifactMatches.map(Optional.some)
                    for app in matched {
                        packages.append(InstalledPackage(name: fullName, displayName: app?.appName,
                            version: latestVersion, isCask: isCask, isPinned: pinned, tap: tap,
                            tapRbPath: source?["path"] as? String, app: app, brewExecutable: brewExecutable))
                    }
                }
            } catch { warnings.append("无法读取 Homebrew \(room.lastPathComponent)：\(error.localizedDescription)") }
        }
        return BrewInventory(packages: packages, warnings: warnings)
    }

    private static func matchInstalledApp(receipt: [String: Any], caskDirectory: URL,
                                           version: String, apps: [AppInfo]) -> [AppInfo] {
        let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]] ?? []
        var paths: Set<String> = []
        var bundleIDs: Set<String> = []
        for artifact in artifacts {
            for rawPath in artifact["app"] as? [String] ?? [] {
                let path: URL
                if rawPath.hasPrefix("/") { path = URL(fileURLWithPath: rawPath) }
                else {
                    let link = caskDirectory.appendingPathComponent(version).appendingPathComponent(rawPath)
                    if FileManager.default.fileExists(atPath: link.path) { path = link.resolvingSymlinksInPath() }
                    else { continue } // A name alone cannot establish installation ownership.
                }
                paths.insert(path.resolvingSymlinksInPath().standardizedFileURL.path)
            }
            if let ids = artifact["quit"] as? [String] { bundleIDs.formUnion(ids) }
            if let id = artifact["quit"] as? String { bundleIDs.insert(id) }
        }
        return apps.filter { app in
            if paths.contains(app.path.resolvingSymlinksInPath().standardizedFileURL.path) { return true }
            // PKG casks may only carry the installed package's bundle IDs.
            return paths.isEmpty && bundleIDs.contains(app.bundleIdentifier)
                && app.path.path.hasPrefix("/Applications/")
        }
    }

    static func check(package: InstalledPackage, client: any HTTPClient = NetworkClient(),
                      platformTag: String? = nil) async -> UpdateRecord {
        let installedVersion = actualVersion(package: package)
        func record(_ state: CheckState, _ detail: String, available: String? = nil, homepage: URL? = nil) -> UpdateRecord {
            UpdateRecord(app: package.app, source: package.source, state: state, detail: detail,
                id: package.id, name: package.displayName ?? package.name, installedVersion: installedVersion,
                availableVersion: available, packageName: package.name, brewExecutable: package.brewExecutable,
                isPinned: package.isPinned, homepage: homepage)
        }
        if package.version == "latest" {
            return record(.unsupported, "此 Cask 使用 latest，无法仅凭 Homebrew 版本号确认更新。")
        }
        do {
            let isCustomTap = package.tap.map { $0 != "homebrew/core" && $0 != "homebrew/cask" } ?? false
            if isCustomTap {
                guard let rbPath = package.tapRbPath,
                      let rbContent = try? String(contentsOfFile: rbPath, encoding: .utf8),
                      let availableVersion = staticTapVersion(content: rbContent, isCask: package.isCask) else {
                    return record(.unsupported, "此自定义 tap 的版本无法从本地定义可靠读取。请使用 Homebrew 检查。")
                }
                let outdated = PkgVersion(availableVersion) > PkgVersion(installedVersion)
                return record(outdated ? .updateAvailable : .current,
                    "依据本地 tap 定义检查；请先在终端运行 brew update 以刷新自定义 tap。", available: availableVersion)
            }
            let endpoint = package.isCask ? "cask" : "formula"
            var url = URL(string: "https://formulae.brew.sh/api")!
            url.appendPathComponent(endpoint)
            url.appendPathComponent(package.name + ".json")
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
            let data = try await client.fetch(request)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CheckError.invalidResponse }
            if let variations = json["variations"] as? [String: Any], !variations.isEmpty {
                let tag: String
                if let platformTag { tag = platformTag }
                else { tag = try await BrewPlatformTagCache.shared.tag(for: package.brewExecutable) }
                json = try mergePlatformVariation(json, tag: tag)
            }
            let latestVersion: String
            let bundleVersion: String?
            if package.isCask {
                guard let value = json["version"] as? String, !value.isEmpty else { throw CheckError.noMetadata }
                latestVersion = value
                bundleVersion = json["bundle_version"] as? String
            } else {
                guard let value = (json["versions"] as? [String: Any])?["stable"] as? String,
                      !value.isEmpty else { throw CheckError.noMetadata }
                let revision = json["revision"] as? Int ?? 0
                latestVersion = revision > 0 ? "\(value)_\(revision)" : value
                bundleVersion = nil
                if package.version == "HEAD" || package.version.hasPrefix("HEAD-") {
                    return record(.unsupported, "HEAD 安装不能与稳定版直接比较。")
                }
            }
            if latestVersion == "latest" { return record(.unsupported, "更新源使用 latest，无法确认新版本。") }
            let outdated = isOutdated(package: package, actualVersion: installedVersion,
                latestVersion: latestVersion, apiBundleVersion: bundleVersion)
            let detail = package.isPinned ? "此 Formula 已固定版本，UpPear 不会替你解除固定。"
                : (outdated ? (package.app?.feedURL != nil ? "应用自带更新功能，优先在应用内更新。" : "可通过 Homebrew 单项升级。") : "Homebrew 更新源未显示更高版本。")
            return record(outdated ? .updateAvailable : .current, detail, available: latestVersion,
                          homepage: (json["homepage"] as? String).flatMap(URL.init(string:)))
        } catch { return record(.failed, error.localizedDescription) }
    }

    // Pearcleaner's hybrid actual-version rule prevents false updates when an
    // app has already advanced through its own updater since brew installation.
    static func actualVersion(package: InstalledPackage) -> String {
        guard package.isCask, let app = package.app else { return package.version }
        let appVer = Version(versionNumber: app.appVersion, buildNumber: nil)
        let brewVer = Version(versionNumber: package.version.stripBrewRevisionSuffix(), buildNumber: nil)
        return appVer > brewVer ? app.appVersion : package.version
    }

    /// Match Homebrew::API.merge_variations: exact current-tag override, or the
    /// base definition when that tag has no override. Never select a nearby OS
    /// or an Intel branch solely because its version is higher.
    static func mergePlatformVariation(_ json: [String: Any], tag: String) throws -> [String: Any] {
        var result = json
        if let variations = json["variations"] as? [String: Any], let value = variations[tag] {
            guard let override = value as? [String: Any] else { throw CheckError.invalidResponse }
            result.merge(override) { _, platformValue in platformValue }
        }
        result.removeValue(forKey: "variations")
        return result
    }

    static func isOutdated(package: InstalledPackage, actualVersion: String,
                           latestVersion: String, apiBundleVersion: String?) -> Bool {
        if !package.isCask { return PkgVersion(latestVersion) > PkgVersion(actualVersion) }
        let installed = Version(versionNumber: actualVersion.stripBrewRevisionSuffix(), buildNumber: nil)
        let available = Version(versionNumber: latestVersion.stripBrewRevisionSuffix(), buildNumber: nil)
        guard !installed.isEmpty, !available.isEmpty else { return false }
        if available > installed { return true }
        if available == installed, let installedBundle = package.app?.appBuildNumber, let apiBundleVersion {
            return Version(versionNumber: apiBundleVersion, buildNumber: nil) > Version(versionNumber: installedBundle, buildNumber: nil)
        }
        return false
    }

    static func staticTapVersion(content: String, isCask: Bool) -> String? {
        var tapVersion: String?
        var tapRevision = 0
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /^version\s+"([^"]+)"$/) { tapVersion = String(match.1) }
            if let match = trimmed.firstMatch(of: /^revision\s+(\d+)$/) { tapRevision = Int(match.1) ?? 0 }
        }
        guard let tapVersion, tapVersion != "latest" else { return nil }
        return !isCask && tapRevision > 0 ? "\(tapVersion)_\(tapRevision)" : tapVersion
    }

    private static func jsonDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Cache one platform probe per Homebrew installation for this app session.
/// The Ruby expression only reads Homebrew's own platform selection. Setting
/// HOMEBREW_DEVELOPER in the child prevents brew ruby from persisting devcmdrun
/// in the user's git config. Auto-update and analytics are disabled by runner.
private actor BrewPlatformTagCache {
    static let shared = BrewPlatformTagCache()
    private var probes: [URL: Task<String, Error>] = [:]

    func tag(for executable: URL) async throws -> String {
        if let probe = probes[executable] { return try await probe.value }
        let probe = Task<String, Error> {
            let result = try await CommandRunner.run(executable: executable,
                arguments: ["ruby", "-e", "require \"simulate_system\"; puts Homebrew::SimulateSystem.current_tag"],
                timeout: 15, environmentOverrides: ["HOMEBREW_DEVELOPER": "1"])
            let tag = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0,
                  tag.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil else {
                throw BrewPlatformError.unavailable
            }
            return tag
        }
        probes[executable] = probe
        do { return try await probe.value }
        catch { probes[executable] = nil; throw error }
    }
}

private enum BrewPlatformError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "无法读取 Homebrew 的系统与架构信息，请确认 Homebrew 能正常运行后重试。" }
}
