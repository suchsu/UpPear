import Foundation

// Modified for UpPear 1.1: MAU owns its registered application channel;
// extension IDs stay independent from their host application's ignored ID.

public enum UpdateEngine {
    public static func scan(options: CheckOptions,
        progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }) async throws -> ScanSnapshot {
        await progress(ScanProgress("正在读取已安装应用…"))
        let scan = await Task.detached(priority: .utility) { AppScanner.scan() }.value
        try Task.checkCancellation()
        let updater = MicrosoftAutoUpdateChecker.installedUpdater()
        var installedApps = scan.apps
        if let updater, !installedApps.contains(where: { $0.id == updater.id }) { installedApps.append(updater) }
        let allApps = installedApps
        let microsoftConfiguration = await MicrosoftAutoUpdateChecker.readConfiguration(updater: updater)
        try Task.checkCancellation()
        let steam = await Task.detached(priority: .utility) { SteamInventory.scan(apps: allApps) }.value
        let host = allApps.first { $0.bundleIdentifier == "com.pilotmoon.popclip" }
        let extensions = await Task.detached(priority: .utility) {
            host == nil ? PopClipInventory(extensions: [], warnings: []) : PopClipExtensionScanner.scan()
        }.value
        let inventory = await Task.detached(priority: .utility) {
            HomebrewUpdateChecker.loadInstalledPackages(apps: allApps, includeFormulae: options.includeFormulae)
        }.value
        let microsoftIDs = Set(allApps.filter { MicrosoftAutoUpdateChecker.isCandidate($0, configuration: microsoftConfiguration) }.map(\.id))
        let packages = inventory.packages.filter { !options.ignoredIDs.contains($0.id) && !microsoftIDs.contains($0.id) && !steam.ownedApplicationIDs.contains($0.id) }
        let apps = allApps.filter { !options.ignoredIDs.contains($0.id) && !steam.ownedApplicationIDs.contains($0.id) }
        let masApps = apps.filter(\.isAppStore)
        let microsoftApps = apps.filter { microsoftIDs.contains($0.id) }
        let sparkleApps = apps.filter { !$0.isAppStore && !$0.isSetapp && $0.feedURL != nil && !microsoftIDs.contains($0.id) }
        let existingIDs = Set(packages.map(\.id) + masApps.map(\.id) + sparkleApps.map(\.id) + microsoftApps.map(\.id)).union(steam.ownedApplicationIDs)
        let bound = GitHubSourceBinding.resolve(options.githubBindings, apps: allApps)
        var githubTargets: [(AppInfo, GitHubSourceBinding)] = []
        var electronTargets: [(AppInfo, ElectronConfiguration)] = []
        var discoveryErrors: [UpdateRecord] = []
        for app in apps where !existingIDs.contains(app.id) && !app.isSetapp {
            if let binding = bound[app.id] { githubTargets.append((app, binding)); continue }
            if options.githubBindings.contains(where: { $0.installationPath == app.id }) ||
               GitHubSourceBinding.requiresRelinking(options.githubBindings, app: app) {
                discoveryErrors.append(UpdateRecord(app: app, source: .github, state: .unverified,
                    detail: "安装位置或身份已变化，请重新确认 GitHub 来源。"))
                continue
            }
            do {
                if let config = try ElectronConfiguration.read(app: app) {
                    if let repository = config.repository {
                        var binding = GitHubSourceBinding(app: app, repository: repository,
                            evidence: "应用内标准 app-update 配置", manuallySelected: false)
                        binding.tagPrefix = config.tagPrefix
                        if config.channel != "latest" {
                            binding.stream = .includingPrereleases
                            binding.requiredManifestAsset = config.channel + "-mac.yml"
                        }
                        githubTargets.append((app, binding))
                    } else { electronTargets.append((app, config)) }
                } else {
                    let explicit = SourceDiscovery.candidates(for: app).filter(\.isExplicitUpdateSource)
                    if explicit.count == 1, let candidate = explicit.first {
                        var binding = GitHubSourceBinding(app: app, repository: candidate.repository,
                            evidence: candidate.evidence, manuallySelected: false)
                        binding.assetPattern = candidate.assetPattern ?? ""
                        githubTargets.append((app, binding))
                    }
                }
            } catch {
                discoveryErrors.append(UpdateRecord(app: app, source: .electron, state: .unverified,
                    detail: "应用内更新配置暂不能解析：\(error.localizedDescription) 可手动指定 GitHub 来源。"))
            }
        }
        let supportedIDs = existingIDs.union(githubTargets.map { $0.0.id }).union(electronTargets.map { $0.0.id }).union(discoveryErrors.map(\.id))
        var records = allApps.filter {
            !steam.ownedApplicationIDs.contains($0.id) && (options.ignoredIDs.contains($0.id) || !supportedIDs.contains($0.id))
        }.map { app in
            if options.ignoredIDs.contains(app.id) {
                return ignoredRecord(app: app, binding: bound[app.id],
                    package: inventory.packages.first { $0.id == app.id }, microsoft: microsoftIDs.contains(app.id))
            }
            return UpdateRecord(app: app, source: .unsupported, state: .unsupported,
                detail: app.isSetapp ? "由 Setapp 管理。" : "尚未指定更新来源。")
        }
        records += discoveryErrors
        records += steam.records.map { original in
            var record = original
            if options.ignoredIDs.contains(record.id) || record.steam?.launchers.contains(where: { options.ignoredIDs.contains($0.standardizedFileURL.path) }) == true {
                record.state = .skipped; record.detail = "已从自动检查中忽略，可在详情中恢复。"
            }
            return record
        }
        records += inventory.packages.filter { options.ignoredIDs.contains($0.id) && $0.app == nil }.map { package in
            UpdateRecord(app: nil, source: package.source, state: .skipped, detail: "已从自动检查中忽略。",
                id: package.id, name: package.name, installedVersion: package.version,
                packageName: package.name, brewExecutable: package.brewExecutable, isPinned: package.isPinned)
        }
        let total = packages.count + masApps.count + sparkleApps.count + microsoftApps.count + extensions.extensions.count + githubTargets.count + electronTargets.count
        let counter = ProgressCounter(total: total, progress: progress)
        await progress(ScanProgress("正在查询更新源…", total: total))
        async let storeResults = checkInBatches(masApps) { app in
            let result = await AppStoreUpdateChecker.check(app: app, primaryRegion: options.primaryRegion)
            await counter.didCheck(app.appName)
            return result
        }
        async let sparkleResults = checkInBatches(sparkleApps) { app in
            let result = await SparkleUpdateChecker.check(app: app, includePreReleases: options.includePreReleases)
            await counter.didCheck(app.appName)
            return result
        }
        async let brewResults = checkInBatches(packages, size: 8) { package in
            let result = await HomebrewUpdateChecker.check(package: package)
            await counter.didCheck(package.displayName ?? package.name)
            return result
        }
        async let microsoftResults: [UpdateRecord] = {
            let results = await MicrosoftAutoUpdateChecker.check(apps: microsoftApps, updater: updater, configuration: microsoftConfiguration)
            for record in results { await counter.didCheck(record.name) }
            return results
        }()
        async let popClipResults: [UpdateRecord] = {
            guard let host else { return [] }
            return await PopClipUpdateChecker.check(host: host, inventory: extensions, ignoredIDs: options.ignoredIDs) {
                await counter.didCheck("PopClip · \($0)")
            }
        }()
        let githubAPI = GitHubAPI.production()
        async let githubResults = checkInBatches(githubTargets) { app, binding in
            let result = await GitHubUpdateChecker.check(app: app, binding: binding, api: githubAPI)
            await counter.didCheck(app.appName); return result
        }
        async let electronResults = checkInBatches(electronTargets) { app, configuration in
            let result = await ElectronUpdateChecker.check(app: app, configuration: configuration)
            await counter.didCheck(app.appName); return result
        }
        let checked = await (storeResults, sparkleResults, brewResults, microsoftResults, popClipResults, githubResults, electronResults)
        try Task.checkCancellation()
        records += checked.0 + checked.1 + checked.2 + checked.3 + checked.4 + checked.5 + checked.6
        let merged = merge(records: records).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ScanSnapshot(records: merged, warnings: scan.warnings + inventory.warnings + extensions.warnings + steam.warnings)
    }

    static func ignoredRecord(app: AppInfo, binding: GitHubSourceBinding?, package: InstalledPackage?, microsoft: Bool) -> UpdateRecord {
        var record: UpdateRecord
        if app.isAppStore { record = UpdateRecord(app: app, source: .appStore, state: .skipped, detail: "") }
        else if microsoft { record = UpdateRecord(app: app, source: .microsoftAutoUpdate, state: .skipped, detail: "") }
        else if let package {
            record = UpdateRecord(app: app, source: package.source, state: .skipped, detail: "",
                packageName: package.name, brewExecutable: package.brewExecutable, isPinned: package.isPinned)
        } else if app.feedURL != nil { record = UpdateRecord(app: app, source: .sparkle, state: .skipped, detail: "") }
        else if let binding {
            record = UpdateRecord(app: app, source: .github, state: .skipped, detail: "")
            record.github = GitHubUpdateInfo(binding: binding, checkedAt: Date(), identityNote: "用户指定")
        } else { record = SourceDiscovery.pendingRecord(for: app); record.state = .skipped }
        return record
    }

    static func merge(records: [UpdateRecord]) -> [UpdateRecord] {
        let groups = Dictionary(grouping: records, by: \.id)
        return groups.values.compactMap { values in
            if let mas = values.first(where: { $0.source == .appStore }) { return mas }
            if let microsoft = values.first(where: { $0.source == .microsoftAutoUpdate }) { return microsoft }
            let updates = values.filter { $0.state == .updateAvailable }
            if !updates.isEmpty {
                return updates.sorted {
                    let first = Version(versionNumber: $0.availableVersion?.stripBrewRevisionSuffix(), buildNumber: nil)
                    let second = Version(versionNumber: $1.availableVersion?.stripBrewRevisionSuffix(), buildNumber: nil)
                    if first == second { return $0.source == .sparkle && $1.source != .sparkle }
                    return first > second
                }.first
            }
            if let current = values.first(where: { $0.state == .current }) { return current }
            if let skipped = values.first(where: { $0.state == .skipped }) { return skipped }
            return values.first(where: { $0.state == .failed }) ?? values.first
        }
    }
}

private actor ProgressCounter {
    private var completed = 0
    private let total: Int
    private let progress: @Sendable (ScanProgress) async -> Void
    init(total: Int, progress: @escaping @Sendable (ScanProgress) async -> Void) {
        self.total = total
        self.progress = progress
    }
    func didCheck(_ name: String) async {
        completed += 1
        await progress(ScanProgress("已检查 \(name)", completed: completed, total: total))
    }
}
