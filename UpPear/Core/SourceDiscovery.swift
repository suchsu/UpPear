import Foundation
import Security
import Darwin

enum SourceDiscovery {
    static func pendingRecord(for app: AppInfo) -> UpdateRecord {
        if let configuration = try? ElectronConfiguration.read(app: app) {
            if let repository = configuration.repository {
                let binding = GitHubSourceBinding(app: app, repository: repository,
                    evidence: "应用内标准 app-update 配置", manuallySelected: false)
                var record = UpdateRecord(app: app, source: .github, state: .unverified, detail: "尚未检查。")
                record.github = GitHubUpdateInfo(binding: binding, checkedAt: Date(), identityNote: "应用内配置")
                return record
            }
            return UpdateRecord(app: app, source: .electron, state: .unverified, detail: "尚未检查。")
        }
        let sources = candidates(for: app).filter(\.isExplicitUpdateSource)
        if sources.count == 1, let source = sources.first {
            var binding = GitHubSourceBinding(app: app, repository: source.repository,
                evidence: source.evidence, manuallySelected: false)
            binding.assetPattern = source.assetPattern ?? ""
            var record = UpdateRecord(app: app, source: .github, state: .unverified, detail: "尚未检查。")
            record.github = GitHubUpdateInfo(binding: binding, checkedAt: Date(), identityNote: "应用内配置")
            return record
        }
        return UpdateRecord(app: app, source: .unsupported, state: .unsupported, detail: "尚未指定更新来源。")
    }
    static func identify(_ input: AppInfo) -> AppInfo {
        var app = input
        var attributes = stat()
        if stat(app.path.resolvingSymlinksInPath().path, &attributes) == 0 {
            app.installationFileID = "\(attributes.st_dev):\(attributes.st_ino)"
        }
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(app.bundlePath as CFURL, [], &code) == errSecSuccess, let code {
            var information: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
               let dict = information as? [String: Any] {
                app.teamIdentifier = dict[kSecCodeInfoTeamIdentifier as String] as? String
            }
        }
        return app
    }

    static func candidates(for app: AppInfo) -> [SourceCandidate] {
        if let config = try? ElectronConfiguration.read(app: app), let repo = config.repository {
            return [SourceCandidate(repository: repo, evidence: "应用内标准 app-update 配置", isExplicitUpdateSource: true)]
        }
        var candidates: [SourceCandidate] = []
        func append(_ text: String, evidence: String, explicit: Bool) {
            guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+(?:/releases)?"#) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let repository = try? GitHubRepository(String(text[range])) else { continue }
                candidates.append(SourceCandidate(repository: repository, evidence: evidence, isExplicitUpdateSource: explicit))
            }
        }
        let plist = app.bundlePath.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in ["ReleasePage", "GitHubRepository", "RepositoryURL", "Homepage", "SUReleaseNotesURL"] {
                if let value = info[key] as? String { append(value, evidence: "应用元数据 \(key)", explicit: key == "ReleasePage") }
            }
        }
        let resources = app.bundlePath.appendingPathComponent("Contents/Resources")
        let support = resources.appendingPathComponent("SupportPath.plist")
        if let data = try? Data(contentsOf: support), data.count < 200_000,
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let page = info["ReleasePage"] as? String, let repo = try? GitHubRepository(page) {
            var pattern: String?
            if let latest = info["LatestZIP"] as? String, let url = URL(string: latest), url.host == "github.com",
               url.path.hasPrefix("/" + repo.slug + "/releases/download/"), url.pathComponents.count >= 7 {
                let tag = url.pathComponents[5]
                if ReleaseVersion.normalized(tag) != nil, url.lastPathComponent.contains(tag) {
                    pattern = url.lastPathComponent.replacingOccurrences(of: tag, with: "*")
                }
            }
            candidates.append(SourceCandidate(repository: repo, evidence: "应用内 SupportPath.plist 的 ReleasePage 与发行产物系列", isExplicitUpdateSource: true, assetPattern: pattern))
        }
        for relative in ["Credits.rtf", "Credits.html", "en.lproj/Credits.rtf", "SupportPath"] {
            let url = resources.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: url), data.count < 200_000, let text = String(data: data, encoding: .utf8) {
                append(text, evidence: "应用内 \(relative) 项目链接（需选择确认）", explicit: false)
            }
        }
        return Dictionary(grouping: candidates, by: \.id).values.compactMap { values in
            values.first(where: \.isExplicitUpdateSource) ?? values.first
        }.sorted { $0.repository.slug < $1.repository.slug }
    }
}
