import Foundation

struct SteamProduct: Sendable {
    struct Branch: Sendable {
        var buildID: String
        var passwordRequired: Bool
        var updatedAt: String?
    }
    struct Depot: Sendable {
        var manifests: [String: String]
        var platforms: Set<String>
        var language: String?
        var architecture: String?
        var dlcID: String?
        var sharedAppID: String?
        var optional: Bool

        var supportsMac: Bool { platforms.isEmpty || platforms.contains("macos") }
    }
    var appID: String
    var branches: [String: Branch]
    var depots: [String: Depot]
    var publicOnly: Bool

    static func parse(_ data: Data, appID: String, publicOnly: Bool = false) throws -> Self {
        let root = try ValveKeyValues.parse(data)
        guard let info = root["appinfo"] as? [String: Any], info["appid"] as? String == appID else {
            throw CheckError.invalidResponse
        }
        let values = info["depots"] as? [String: Any] ?? [:]
        var branches: [String: Branch] = [:], depots: [String: Depot] = [:]
        for (name, value) in values["branches"] as? [String: Any] ?? [:] {
            guard let branch = value as? [String: Any], let build = branch["buildid"] as? String,
                  UInt64(build).map({ $0 > 0 }) == true else { continue }
            branches[name] = Branch(buildID: build, passwordRequired: branch["pwdrequired"] as? String == "1",
                updatedAt: branch["timeupdated"] as? String)
        }
        for (id, value) in values where UInt32(id).map({ $0 > 0 }) == true {
            guard let depot = value as? [String: Any] else { continue }
            let config = depot["config"] as? [String: Any] ?? [:]
            var manifests: [String: String] = [:]
            for (branch, value) in depot["manifests"] as? [String: Any] ?? [:] {
                let gid = value as? String ?? (value as? [String: Any])?["gid"] as? String
                if let gid, UInt64(gid).map({ $0 > 0 }) == true { manifests[branch] = gid }
            }
            depots[id] = Depot(manifests: manifests,
                platforms: Set((config["oslist"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }),
                language: config["language"] as? String, architecture: config["osarch"] as? String,
                dlcID: depot["dlcappid"] as? String, sharedAppID: depot["depotfromapp"] as? String,
                optional: depot["optional"] as? String == "1")
        }
        return Self(appID: appID, branches: branches, depots: depots, publicOnly: publicOnly)
    }
}

enum SteamUpdateChecker {
    static func isCheckable(_ record: UpdateRecord) -> Bool {
        record.state != .skipped && record.steam?.appID != nil &&
            record.steam?.installationConfirmed == true && record.steam?.ambiguousInstallation != true
    }

    static func check(records: [UpdateRecord], catalog: any SteamCatalogFetching = SteamCatalogClient(),
        progress: @escaping @Sendable (String) async -> Void = { _ in }) async -> [UpdateRecord] {
        let indices = records.indices.filter { isCheckable(records[$0]) }
        let targets = indices.map { records[$0] }
        guard !targets.isEmpty else { return records }
        do {
            let ids = Set(targets.compactMap { $0.steam?.appID })
            var products = try await catalog.products(appIDs: ids)
            // Some games share depots with another app. Fetch those public
            // catalog records too; do not guess a missing manifest or branch.
            let sharedIDs = Set(targets.flatMap { record -> [String] in
                guard let info = record.steam, let id = info.appID else { return [] }
                return (info.installedDepots ?? [:]).keys.compactMap { products[id]?.depots[$0]?.sharedAppID }
            }).subtracting(ids)
            if !sharedIDs.isEmpty, sharedIDs.count <= 200,
               let shared = try? await catalog.products(appIDs: sharedIDs) {
                products.merge(shared) { original, _ in original }
            }
            var results = records
            for index in indices {
                results[index] = evaluate(results[index], products: products)
                await progress(results[index].name)
            }
            return results
        } catch {
            var results = records
            for index in indices {
                results[index].state = .failed
                results[index].availableVersion = nil; results[index].availableBuild = nil
                results[index].detail = "无法连接 Steam 版本服务：\(error.localizedDescription)"
                results[index].steam?.checkedAt = Date()
                await progress(results[index].name)
            }
            return results
        }
    }

    static func evaluate(_ original: UpdateRecord, products: [String: SteamProduct], checkedAt: Date = Date()) -> UpdateRecord {
        var record = original
        record.state = .unverified
        record.availableVersion = nil; record.availableBuild = nil
        record.steam?.checkedAt = checkedAt
        guard let info = record.steam, let id = info.appID, info.installationConfirmed,
              info.ambiguousInstallation != true else { return record }
        guard let product = products[id] else { record.detail = "Steam 暂未提供此游戏的版本信息。"; return record }
        let branchName = info.branch ?? "public"
        guard let branch = product.branches[branchName], !branch.passwordRequired,
              !(product.publicOnly && branchName != "public") else {
            record.detail = "Steam 未公开当前分支 \(branchName) 的版本信息。"; return record
        }
        if let mounted = info.mountedBranch, mounted != branchName {
            record.detail = "Steam 尚未完成分支切换。"; return record
        }
        // StateFlags describes local work only. It never proves the remote
        // version is current. An incomplete installation cannot establish
        // current status, even when its last recorded manifests still match.
        let incomplete = info.stateFlags.map { $0 & 0x00ff_ffb8 != 0 } ?? false
        record.availableVersion = "build " + branch.buildID
        if let seconds = branch.updatedAt.flatMap(TimeInterval.init) {
            record.releaseDate = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        guard let installed = info.installedDepots, !installed.isEmpty else {
            if info.buildID == branch.buildID && !incomplete {
                record.state = .current; record.detail = ""
            } else {
                record.detail = "缺少本地文件清单，暂不能确认 Mac 版本。"
            }
            return record
        }
        var compared = 0, changed = false, unknown = false
        for (depotID, manifest) in installed {
            guard let depot = product.depots[depotID] else { unknown = true; continue }
            guard depot.supportsMac else { continue }
            let expected: String?
            if let sharedID = depot.sharedAppID {
                // Steam shared depots follow their owning app's public branch.
                expected = products[sharedID]?.depots[depotID]?.manifests["public"]
            } else { expected = depot.manifests[branchName] }
            guard let expected else { unknown = true; continue }
            compared += 1
            if manifest != expected { changed = true }
        }
        // A newly added base/language depot is also an update. Do not offer
        // unowned DLC, optional content, 32-bit, or other-platform depots.
        for (depotID, depot) in product.depots where compared > 0 && installed[depotID] == nil && depot.supportsMac &&
            depot.dlcID == nil && !depot.optional && depot.sharedAppID == nil && depot.architecture != "32" {
            if let language = depot.language, !language.isEmpty, language != info.language { continue }
            if depot.manifests[branchName] != nil { changed = true }
        }
        if changed {
            record.state = .updateAvailable; record.detail = ""
        } else if incomplete {
            record.detail = "Steam 安装正在变更或需要修复，请完成后重新检查。"
        } else if compared > 0 && !unknown {
            record.state = .current; record.detail = ""
        } else { record.detail = "当前分支的部分 Mac 文件清单暂不可用。" }
        return record
    }
}
