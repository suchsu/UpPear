import Foundation

public enum UpdateEngine {
    public static func scan(options: CheckOptions,
        progress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }) async throws -> ScanSnapshot {
        await progress(ScanProgress("正在读取已安装应用…"))
        let scan = await Task.detached(priority: .utility) { AppScanner.scan() }.value
        try Task.checkCancellation()
        let inventory = await Task.detached(priority: .utility) {
            HomebrewUpdateChecker.loadInstalledPackages(apps: scan.apps, includeFormulae: options.includeFormulae)
        }.value
        let packages = inventory.packages.filter { !options.ignoredIDs.contains($0.id) }
        let apps = scan.apps.filter { !options.ignoredIDs.contains($0.id) }
        let masApps = apps.filter(\.isAppStore)
        let sparkleApps = apps.filter { !$0.isAppStore && !$0.isSetapp && $0.feedURL != nil }
        let supportedIDs = Set(packages.map(\.id) + masApps.map(\.id) + sparkleApps.map(\.id))
        var records = scan.apps.filter { options.ignoredIDs.contains($0.id) || !supportedIDs.contains($0.id) }.map { app in
            UpdateRecord(app: app, source: app.isAppStore ? .appStore : (app.feedURL == nil ? .unsupported : .sparkle),
                state: options.ignoredIDs.contains(app.id) ? .skipped : .unsupported,
                detail: options.ignoredIDs.contains(app.id) ? "已从自动检查中忽略，可在详情中恢复。"
                    : (app.isSetapp ? "此应用由 Setapp 管理，请通过 Setapp 检查更新。" : "当前未识别到支持的更新来源，请在应用内手动检查。"))
        }
        records += inventory.packages.filter { options.ignoredIDs.contains($0.id) && $0.app == nil }.map { package in
            UpdateRecord(app: nil, source: package.source, state: .skipped, detail: "已从自动检查中忽略。",
                id: package.id, name: package.name, installedVersion: package.version,
                packageName: package.name, brewExecutable: package.brewExecutable, isPinned: package.isPinned)
        }
        let counter = ProgressCounter(total: packages.count + masApps.count + sparkleApps.count, progress: progress)
        await progress(ScanProgress("正在查询更新源…", total: packages.count + masApps.count + sparkleApps.count))
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
        let checked = await (storeResults, sparkleResults, brewResults)
        try Task.checkCancellation()
        records += checked.0 + checked.1 + checked.2
        let merged = merge(records: records).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ScanSnapshot(records: merged, warnings: scan.warnings + inventory.warnings)
    }

    static func merge(records: [UpdateRecord]) -> [UpdateRecord] {
        let groups = Dictionary(grouping: records, by: \.id)
        return groups.values.compactMap { values in
            if let mas = values.first(where: { $0.source == .appStore }) { return mas }
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
