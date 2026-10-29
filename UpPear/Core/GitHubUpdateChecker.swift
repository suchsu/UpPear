import Foundation
import CryptoKit

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let state: String
    }
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let body: String?
    let assets: [Asset]
}

actor GitHubAPI {
    private struct Entry: Codable, Sendable {
        var data: Data
        var etag: String?
        var modified: String?
        var checkedAt: Date
        var hasNextPage: Bool
    }
    private let client: any HTTPClient
    private let cacheDirectory: URL?
    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<HTTPPayload, Error>] = [:]
    private var retryAfter: Date?

    init(client: any HTTPClient = NetworkClient(), cacheDirectory: URL? = nil) {
        self.client = client; self.cacheDirectory = cacheDirectory
    }

    static func production() -> GitHubAPI {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("UpPear/GitHub", isDirectory: true)
        return GitHubAPI(cacheDirectory: directory)
    }

    private func cacheURL(_ key: String) -> URL? {
        cacheDirectory?.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    func get(_ path: String) async throws -> (Data, Bool) {
        try Task.checkCancellation()
        guard retryAfter.map({ $0 <= Date() }) ?? true else { throw SourceError.rateLimited }
        guard let url = URL(string: "https://api.github.com/repos/" + path) else { throw SourceError.invalidRepository }
        let key = url.absoluteString
        if let entry = memory[key], Date().timeIntervalSince(entry.checkedAt) < 20 { return (entry.data, entry.hasNextPage) }
        let disk = cacheURL(key).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        let cached = memory[key] ?? disk
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("UpPear/1.2.0", forHTTPHeaderField: "User-Agent")
        if let cached {
            if let etag = cached.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = cached.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let task: Task<HTTPPayload, Error>
        if let running = inFlight[key] { task = running }
        else {
            let client = self.client, request = request
            task = Task {
                if let rich = client as? any HTTPResponseClient { return try await rich.response(request) }
                return HTTPPayload(data: try await client.fetch(request), status: 200, headers: [:])
            }
            inFlight[key] = task
        }
        defer { inFlight[key] = nil }
        let payload = try await task.value
        try Task.checkCancellation()
        if payload.status == 403 || payload.status == 429 {
            let delay = payload.headers["retry-after"].flatMap(Double.init).map { Date().addingTimeInterval($0) }
            let reset = payload.headers["x-ratelimit-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            retryAfter = max(delay ?? Date().addingTimeInterval(60), reset ?? Date())
            throw SourceError.rateLimited
        }
        if payload.status == 404 || payload.status == 401 { throw SourceError.authentication }
        var entry: Entry
        if payload.status == 304, var prior = cached { prior.checkedAt = Date(); entry = prior }
        else {
            guard payload.status == 200 else { throw CheckError.httpStatus(payload.status) }
            guard payload.data.count <= 4_000_000 else { throw CheckError.invalidResponse }
            entry = Entry(data: payload.data, etag: payload.headers["etag"], modified: payload.headers["last-modified"],
                checkedAt: Date(), hasNextPage: payload.headers["link"]?.contains("rel=\"next\"") ?? false)
        }
        memory[key] = entry
        if let target = cacheURL(key), let data = try? JSONEncoder().encode(entry) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
        return (entry.data, entry.hasNextPage)
    }

    func repositoryID(_ repository: GitHubRepository) async throws -> Int {
        let (data, _) = try await get(repository.slug)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let slug = object["full_name"] as? String,
              slug.caseInsensitiveCompare(repository.slug) == .orderedSame else { throw SourceError.noMatchingRelease }
        return id
    }

    func releases(_ repository: GitHubRepository) async throws -> [GitHubRelease] {
        var releases: [GitHubRelease] = []
        // Bounded pagination is explicit: an incomplete history cannot establish
        // that an installed build is current for a filtered release stream.
        for page in 1...10 {
            let (data, hasNext) = try await get(repository.slug + "/releases?per_page=30&page=\(page)")
            let batch = try JSONDecoder().decode([GitHubRelease].self, from: data)
            releases += batch
            if !hasNext { return releases }
        }
        throw SourceError.invalidManifest
    }

    func tag(_ tag: String, belongsTo branch: String, repository: GitHubRepository) async throws -> Bool {
        func encode(_ ref: String) throws -> String {
            guard let encoded = ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw SourceError.invalidRule }; return encoded
        }
        // compare(tag...branch): tag must be an ancestor of the selected branch.
        // target_commitish alone is not evidence that an existing tag is on it.
        let path = repository.slug + "/compare/" + (try encode("refs/tags/" + tag)) + "..." + (try encode("refs/heads/" + branch)) + "?per_page=1"
        let (data, _) = try await get(path)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { throw SourceError.invalidManifest }
        return status == "ahead" || status == "identical"
    }
}

enum GitHubUpdateChecker {
    static func check(app: AppInfo, binding: GitHubSourceBinding, api: GitHubAPI,
                      platform: UpdatePlatform = .current) async -> UpdateRecord {
        var result = UpdateRecord(app: app, source: .github, state: .unverified,
            detail: "", homepage: binding.repository.url)
        var effective = binding
        result.github = GitHubUpdateInfo(binding: binding, checkedAt: Date(),
            identityNote: binding.manuallySelected ? "用户指定仓库；未下载或验证发行包的应用身份与签名。" : "来源来自应用内更新配置；安装由原应用验证签名。")
        do {
            try binding.validate()
            let repositoryID = try await api.repositoryID(binding.repository)
            guard binding.repositoryID == nil || binding.repositoryID == repositoryID else {
                result.detail = "仓库身份已变化，请重新确认绑定；没有自动切换来源。"; return result
            }
            effective.repositoryID = repositoryID; result.github?.binding = effective
            let releases = try await api.releases(binding.repository)
            let candidates = releases.filter { release in
                !release.draft &&
                (binding.stream != .stable || !release.prerelease) &&
                (binding.stream != .prereleasesOnly || release.prerelease) &&
                (binding.pinnedTag.isEmpty || release.tag_name == binding.pinnedTag) &&
                (binding.requiredManifestAsset == nil || release.assets.contains { $0.name == binding.requiredManifestAsset }) &&
                (binding.tagPrefix.isEmpty || release.tag_name.hasPrefix(binding.tagPrefix))
            }
            let ranked = candidates.compactMap { release -> (GitHubRelease, String)? in
                guard let version = ReleaseVersion.normalized(release.tag_name, prefix: binding.tagPrefix) else { return nil }
                return (release, version)
            }.sorted { ReleaseVersion.newer($0.1, than: $1.1) }
            guard !ranked.isEmpty else { throw SourceError.noMatchingRelease }
            var chosen: (GitHubRelease, String)?
            // First select the release stream, then check its artifacts. Missing
            // assets on a new release must not silently select an older release.
            for (release, version) in ranked {
                if !binding.branch.isEmpty,
                   !(try await api.tag(release.tag_name, belongsTo: binding.branch, repository: binding.repository)) { continue }
                chosen = (release, version); break
            }
            guard let (release, version) = chosen else { throw SourceError.noMatchingRelease }
            result.availableVersion = version; result.releaseNotes = release.body
            result.releaseDate = release.published_at; result.isPreRelease = release.prerelease
            guard release.html_url.host?.lowercased() == "github.com",
                  release.html_url.path.hasPrefix("/" + binding.repository.slug + "/releases/") else { throw SourceError.unsafeURL }
            result.releaseNotesURL = release.html_url; result.github?.releaseTag = release.tag_name
            let validAssets = release.assets.filter {
                $0.state == "uploaded" && $0.size > 0 && SourceURLPolicy.isHTTPS($0.browser_download_url) &&
                $0.browser_download_url.host?.lowercased() == "github.com" &&
                $0.browser_download_url.path.hasPrefix("/" + binding.repository.slug + "/releases/download/")
            }
            result.github?.candidateAssets = validAssets.filter { platform.acceptsAsset($0.name, explicitRule: true) }.map(\.name)
            let assets = validAssets.filter {
                (binding.assetPattern.isEmpty || SourceURLPolicy.glob(binding.assetPattern, matches: $0.name)) &&
                platform.acceptsAsset($0.name, explicitRule: !binding.assetPattern.isEmpty)
            }
            guard assets.count == 1, let asset = assets.first else {
                result.detail = assets.isEmpty ? "未匹配到 macOS \(platform.architecture) 安装包。" : "请选择安装包。"
                return result
            }
            result.github?.assetName = asset.name; result.github?.assetURL = asset.browser_download_url
            let baseline: String?
            if !binding.installedReleaseVersion.isEmpty {
                baseline = binding.baselineAppVersion == app.appVersion && binding.baselineAppBuild == app.appBuildNumber
                    ? ReleaseVersion.normalized(binding.installedReleaseVersion, prefix: binding.tagPrefix) : nil
            } else { baseline = ReleaseVersion.normalized(app.appVersion) }
            guard let baseline else {
                result.detail = "请填写当前安装对应的发行版本。"; return result
            }
            if ReleaseVersion.newer(baseline, than: version) {
                result.detail = "来源版本低于已安装版本，请核实发布流。"; return result
            }
            result.state = ReleaseVersion.newer(version, than: baseline) ? .updateAvailable : .current
            result.detail = "已检查 \(binding.repository.slug) 的\(binding.stream.title)\(binding.branch.isEmpty ? "" : " · 分支 " + binding.branch)。产物为 \(asset.name)；请在发行页面核实系统要求和签名后安装。"
        } catch {
            result.state = error is SourceError ? .unverified : .failed
            if case SourceError.rateLimited = error { result.state = .failed }
            result.detail = "GitHub 检查未完成：\(error.localizedDescription) 原绑定已保留。"
        }
        return result
    }
}
