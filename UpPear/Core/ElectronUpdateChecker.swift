import Foundation

struct ElectronConfiguration: Sendable {
    var provider: String
    var repository: GitHubRepository?
    var baseURL: URL?
    var channel: String
    var tagPrefix: String
    var host: String?

    static func read(app: AppInfo) throws -> Self? {
        guard !app.isAppStore, !app.isSetapp else { return nil }
        for filename in ["app-update.yml", "app-update.yaml", "app-update.json"] {
            let path = app.bundlePath.appendingPathComponent("Contents/Resources/" + filename)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let data = try Data(contentsOf: path)
            return try parse(data)
        }
        return nil
    }

    static func parse(_ data: Data) throws -> Self {
        let dict = try UpdateManifest.dictionary(data)
        guard let provider = dict["provider"] as? String else { throw SourceError.invalidManifest }
        let channel = dict["channel"] as? String ?? "latest"
        guard channel.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,60}$"#, options: .regularExpression) != nil else { throw SourceError.invalidManifest }
        if provider == "github" {
            guard let owner = dict["owner"] as? String, let repo = dict["repo"] as? String,
                  (dict["host"] as? String).map({ ["github.com", "api.github.com"].contains($0.lowercased()) }) ?? true,
                  (dict["private"] as? Bool) != true else { throw SourceError.authentication }
            return Self(provider: provider, repository: try GitHubRepository(owner + "/" + repo), channel: channel,
                tagPrefix: dict["tagNamePrefix"] as? String ?? "", host: dict["host"] as? String)
        }
        guard provider == "generic", let text = dict["url"] as? String, let url = URL(string: text), SourceURLPolicy.isHTTPS(url) else { throw SourceError.invalidManifest }
        return Self(provider: provider, baseURL: url, channel: channel, tagPrefix: "")
    }

    func manifestURL() throws -> URL {
        guard let baseURL else { throw SourceError.invalidManifest }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (components.path.isEmpty ? "" : components.path + "/") + channel + "-mac.yml"
        guard let url = components.url else { throw SourceError.unsafeURL }; return url
    }
}

public struct ElectronUpdateInfo: Codable, Sendable {
    public var feedURL: URL
    public var channel: String
    public var architecture: String
    public var minimumSystemVersion: String?
    public var artifactURL: URL?
    public var checkedAt: Date
}

enum ElectronUpdateChecker {
    static func check(app: AppInfo, configuration: ElectronConfiguration, client: any HTTPClient = NetworkClient(),
                      platform: UpdatePlatform = .current) async -> UpdateRecord {
        var result = UpdateRecord(app: app, source: .electron, state: .unverified, detail: "")
        do {
            let url = try configuration.manifestURL()
            result.electron = ElectronUpdateInfo(feedURL: url, channel: configuration.channel,
                architecture: platform.architecture, checkedAt: Date())
            let data = try await client.fetch(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20))
            let manifest = try UpdateManifest.dictionary(data)
            guard let versionText = manifest["version"] as? String,
                  let version = ReleaseVersion.normalized(versionText) else { throw SourceError.invalidManifest }
            result.availableVersion = version
            result.releaseDate = manifest["releaseDate"] as? String
            result.releaseNotes = manifest["releaseNotes"] as? String
            result.isPreRelease = version.contains("-")
            let minimum = manifest["minimumSystemVersion"] as? String
            result.electron?.minimumSystemVersion = minimum
            // Electron's minimumSystemVersion is the Darwin kernel version,
            // not the user-facing macOS marketing version.
            if let minimum {
                guard ReleaseVersion.normalized(minimum) != nil else { throw SourceError.invalidManifest }
                if ReleaseVersion.newer(minimum, than: platform.darwin) {
                    result.state = .incompatible; result.detail = "所选频道需要更新的 macOS。"; return result
                }
            }
            var files = manifest["files"] as? [[String: Any]] ?? []
            if files.isEmpty, let path = manifest["path"] as? String, let checksum = manifest["sha512"] as? String {
                files = [["url": path, "sha512": checksum]]
            }
            let compatible = files.compactMap { file -> URL? in
                guard let path = file["url"] as? String, let checksum = file["sha512"] as? String,
                      Data(base64Encoded: checksum)?.count == 64,
                      let artifact = URL(string: path, relativeTo: url)?.absoluteURL, SourceURLPolicy.isHTTPS(artifact),
                      platform.acceptsAsset(artifact.lastPathComponent, context: configuration.baseURL?.path ?? "") else { return nil }
                return artifact
            }
            guard let artifact = compatible.first else {
                result.detail = "清单没有可核实的 macOS \(platform.architecture) 安装产物（含 sha512）。请在应用内检查。"; return result
            }
            result.electron?.artifactURL = artifact
            if let rawStaging = manifest["stagingPercentage"] {
                guard let staging = Double(String(describing: rawStaging)), (0...100).contains(staging) else { throw SourceError.invalidManifest }
                if staging < 100 {
                    result.detail = "分批发布中（\(staging.formatted())%），请在应用内确认更新。"; return result
                }
            }
            guard let installed = ReleaseVersion.normalized(app.appVersion) else {
                result.detail = "当前安装版本无法与该频道的版本比较。"; return result
            }
            result.state = ReleaseVersion.newer(version, than: installed) ? .updateAvailable : .current
            result.detail = "依据应用内标准配置检查 \(configuration.channel) 频道；由应用自身验证签名并安装。"
            if ReleaseVersion.newer(installed, than: version) {
                result.state = .unverified; result.detail = "所选频道版本低于当前安装版本，未建议回退；请核实来源或稍后重试。"
            }
        } catch {
            result.state = .failed; result.detail = "Electron 更新检查未完成：\(error.localizedDescription)"
        }
        return result
    }
}
