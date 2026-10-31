// Modified for UpPear: fixture models are maintained only in local validation sources.
import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class UpdateModel {
    var snapshot: ScanSnapshot?
    var isChecking = false
    var progress = ScanProgress("准备检查")
    var errorMessage: String?
    var operationOutput: String?
    var isUpgrading = false
    var upgradingName: String?
    var pendingUpgrade: UpdateRecord?
    private(set) var retryingAppStoreIDs: Set<String> = []
    var primaryRegion: String { didSet { defaults.set(primaryRegion, forKey: "primaryRegion") } }
    var includePreReleases: Bool { didSet { defaults.set(includePreReleases, forKey: "includePreReleases") } }
    var includeFormulae: Bool { didSet { defaults.set(includeFormulae, forKey: "includeFormulae") } }
    var dailyCheck: Bool { didSet { defaults.set(dailyCheck, forKey: "dailyCheck") } }
    var notifyNewUpdates: Bool { didSet { defaults.set(notifyNewUpdates, forKey: "notifyNewUpdates") } }
    var ignoredIDs: Set<String>
    private(set) var skippedVersions: [String: SkippedUpdate]
    private(set) var githubBindings: [GitHubSourceBinding]
    var loginEnabled = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private let appStoreChecker: @Sendable (AppInfo, String, Bool) async -> UpdateRecord
    @ObservationIgnored private var appStoreRetries: [String: (UUID, Task<Void, Never>)] = [:]

    private func displayRecords(_ records: [UpdateRecord]) -> [UpdateRecord] {
        let safe = records.map { record in
            var record = AppStoreSnapshotPolicy.display(record, observedAt: snapshot?.completedAt ?? Date())
            if ignoredIDs.contains(record.id) {
                record.state = .skipped
                return record
            }
            // Scans omit ignored targets. Restoring them is a local operation;
            // retain the row and wait for the next explicitly requested check.
            if record.state == .skipped {
                record.state = .unverified
                record.detail = "尚未检查。"
            }
            return record
        }
        return UpdateSkipPolicy.applying(skippedVersions, to: safe)
    }
    var records: [UpdateRecord] { displayRecords(snapshot?.records ?? []) }
    var updateCount: Int { records.filter { $0.state == .updateAvailable }.count }
    var failureCount: Int { records.filter { $0.state == .failed }.count }
    var ignoredCount: Int { ignoredIDs.count }
    var skippedRecords: [UpdateRecord] {
        let byID = Dictionary(grouping: records, by: \.id)
        return skippedVersions.map { id, target in
            byID[id]?.first ?? UpdateRecord(app: nil, source: target.source, state: .versionSkipped,
                detail: "当前检查结果中没有此项目，可在这里移除其跳过设置。", id: id, name: target.name,
                installedVersion: "", availableVersion: target.version, availableBuild: target.build)
        }
    }
    var needsCheck: Bool {
        snapshot.map { $0.schemaVersion != ScanSnapshot.currentSchemaVersion || Date().timeIntervalSince($0.completedAt) >= 86400 } ?? true
    }

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil,
         appStoreChecker: @escaping @Sendable (AppInfo, String, Bool) async -> UpdateRecord = {
             await AppStoreUpdateChecker.check(app: $0, primaryRegion: $1, refresh: $2)
         }) {
        self.defaults = defaults
        self.appStoreChecker = appStoreChecker
        githubBindings = defaults.data(forKey: "githubSourceBindings").flatMap {
            try? JSONDecoder().decode([GitHubSourceBinding].self, from: $0)
        } ?? []
        primaryRegion = defaults.string(forKey: "primaryRegion") ?? "CN"
        includePreReleases = defaults.bool(forKey: "includePreReleases")
        includeFormulae = defaults.object(forKey: "includeFormulae") as? Bool ?? true
        dailyCheck = defaults.object(forKey: "dailyCheck") as? Bool ?? true
        notifyNewUpdates = defaults.bool(forKey: "notifyNewUpdates")
        ignoredIDs = Set(defaults.stringArray(forKey: "ignoredIDs") ?? [])
        skippedVersions = defaults.data(forKey: "skippedVersions").flatMap {
            try? JSONDecoder().decode([String: SkippedUpdate].self, from: $0)
        } ?? [:]
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UpPear/snapshot.json")
        if let data = try? Data(contentsOf: self.cacheURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try? decoder.decode(ScanSnapshot.self, from: data)
        }
        skippedVersions = skippedVersions.filter { !ignoredIDs.contains($0.key) }
        skippedVersions = UpdateSkipPolicy.retaining(skippedVersions, after: snapshot?.records ?? [])
    }

    func start() {
        guard !started else { return }
        started = true
        if needsCheck { checkNow() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dailyCheck, self.needsCheck, !self.isChecking, !self.isUpgrading, self.retryingAppStoreIDs.isEmpty,
                      self.lastAttempt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
                self.checkNow()
            }
        }
    }

    func checkNow() {
        guard !isChecking, !isUpgrading else { return }
        cancelAppStoreRetries()
        isChecking = true
        errorMessage = nil
        lastAttempt = Date()
        progress = ScanProgress("正在准备检查…")
        var options = CheckOptions(primaryRegion: primaryRegion, includePreReleases: includePreReleases,
                                   includeFormulae: includeFormulae, ignoredIDs: ignoredIDs)
        options.githubBindings = githubBindings
        let scanOptions = options
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await UpdateEngine.scan(options: scanOptions) { [weak self] progress in
                    await MainActor.run { self?.progress = progress }
                }
                try Task.checkCancellation()
                let previous = self.snapshot
                self.skippedVersions = UpdateSkipPolicy.retaining(self.skippedVersions, after: result.records)
                self.persistSkippedVersions()
                self.snapshot = result
                for info in result.records.compactMap(\.github) where info.binding.manuallySelected {
                    if let index = self.githubBindings.firstIndex(where: { $0.id == info.binding.id }) {
                        self.githubBindings[index] = info.binding
                    }
                }
                self.persistGitHubBindings()
                self.persist(result)
                self.notifyIfNeeded(result, previous: previous)
            } catch is CancellationError {
                self.errorMessage = "检查已取消，上次完成的结果已保留。"
            } catch { self.errorMessage = error.localizedDescription }
            self.isChecking = false
            self.checkTask = nil
        }
    }

    func cancelCheck() { checkTask?.cancel(); cancelAppStoreRetries() }

    func cancelAppStoreRetry(_ id: String) {
        appStoreRetries.removeValue(forKey: id)?.1.cancel()
        retryingAppStoreIDs.remove(id)
    }

    var failedAppStoreRecords: [UpdateRecord] {
        records.filter { $0.source == .appStore && $0.state == .failed && $0.app != nil }
    }

    func retryFailedAppStore() {
        for record in failedAppStoreRecords { retryAppStore(record) }
    }

    func retryAppStore(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading, record.source == .appStore, let app = record.app,
              !ignoredIDs.contains(record.id), !retryingAppStoreIDs.contains(record.id) else { return }
        let id = record.id, token = UUID(), region = primaryRegion
        retryingAppStoreIDs.insert(id)
        let checker = appStoreChecker
        let task = Task { [weak self] in
            defer {
                if let self, self.appStoreRetries[id]?.0 == token {
                    self.appStoreRetries.removeValue(forKey: id); self.retryingAppStoreIDs.remove(id)
                }
            }
            let result = await checker(app, region, true)
            guard !Task.isCancelled, let self, self.appStoreRetries[id]?.0 == token,
                  !self.isChecking, var updated = self.snapshot,
                  let index = updated.records.firstIndex(where: { $0.id == id }),
                  updated.records[index].app?.bundleIdentifier == app.bundleIdentifier else { return }
            let previous = updated
            var replacement = result
            if replacement.state == .failed, replacement.availableVersion == nil,
               let prior = updated.records[index].availableVersion {
                let old = updated.records[index]
                replacement.availableVersion = prior; replacement.releaseNotes = old.releaseNotes
                replacement.releaseDate = old.releaseDate; replacement.foundInRegion = old.foundInRegion
                replacement.appStoreQuery?.versionCheckedAt = old.appStoreQuery?.versionCheckedAt ?? old.appStoreQuery?.checkedAt ?? updated.completedAt
                replacement.appStoreQuery?.source = old.appStoreQuery?.source
                replacement.appStoreQuery?.sourceURL = old.appStoreQuery?.sourceURL
                replacement.appStoreQuery?.isCached = true
            }
            updated.records[index] = replacement
            self.skippedVersions = UpdateSkipPolicy.retaining(self.skippedVersions, after: updated.records)
            self.persistSkippedVersions(); self.snapshot = updated; self.persist(updated)
            self.notifyIfNeeded(updated, previous: previous)
        }
        appStoreRetries[id] = (token, task)
    }

    private func cancelAppStoreRetries() {
        for (_, task) in appStoreRetries.values { task.cancel() }
        appStoreRetries.removeAll(); retryingAppStoreIDs.removeAll()
    }

    func toggleIgnored(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading else { return }
        if ignoredIDs.contains(record.id) { ignoredIDs.remove(record.id) }
        else {
            ignoredIDs.insert(record.id)
            cancelAppStoreRetry(record.id)
        }
        skippedVersions.removeValue(forKey: record.id)
        persistSkippedVersions()
        defaults.set(Array(ignoredIDs).sorted(), forKey: "ignoredIDs")
    }

    func skipUpdate(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading, !ignoredIDs.contains(record.id),
              let target = SkippedUpdate(record: record) else { return }
        skippedVersions[record.id] = target
        persistSkippedVersions()
    }

    func restoreSkippedUpdate(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading else { return }
        skippedVersions.removeValue(forKey: record.id)
        persistSkippedVersions()
    }

    func performAction(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading else { return }
        switch ActionResolver.action(for: record, primaryRegion: primaryRegion) {
        case .appStore(let url):
            if !NSWorkspace.shared.open(url) { errorMessage = "无法打开 App Store。" }
        case .openApplication(let url), .microsoftAutoUpdate(let url):
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                if let error { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
            }
        case .brewUpgrade:
            pendingUpgrade = record
        case .extensionDownload(let url), .officialPage(let url), .steam(let url):
            if !NSWorkspace.shared.open(url) { errorMessage = "无法打开官方更新入口。" }
        case .manual:
            errorMessage = record.isPinned ? "此 Formula 已固定版本。请在 Homebrew 中自行解除固定后再升级。"
                : "请使用软件或软件包的官方更新工具手动检查。"
        }
    }

    func upgrade(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading,
              case .brewUpgrade(let plan) = ActionResolver.action(for: record, primaryRegion: primaryRegion) else { return }
        if let app = record.app,
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == app.path.resolvingSymlinksInPath() }) {
            errorMessage = "请先退出 \(record.name)，再通过 Homebrew 升级。"
            return
        }
        isUpgrading = true
        upgradingName = record.name
        operationOutput = nil
        Task {
            do {
                let result = try await CommandRunner.run(executable: plan.executable, arguments: plan.arguments,
                    timeout: 1800, allowBrewAutoUpdate: true)
                let output = result.output + (result.error.isEmpty ? "" : "\n" + result.error)
                operationOutput = String(output.suffix(100000))
                if result.exitCode != 0 {
                    errorMessage = "Homebrew 未能完成升级（退出码 \(result.exitCode)）。详情保留在操作记录中；需要管理员验证时可复制命令到终端运行。"
                }
            } catch { errorMessage = error.localizedDescription }
            isUpgrading = false
            upgradingName = nil
            checkNow()
        }
    }

    func copyCommand(_ record: UpdateRecord) {
        guard case .brewUpgrade(let plan) = ActionResolver.action(for: record, primaryRegion: primaryRegion) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plan.displayCommand, forType: .string)
    }

    func githubBinding(for app: AppInfo) -> GitHubSourceBinding? {
        GitHubSourceBinding.resolve(githubBindings, apps: [app])[app.id]
    }

    func saveGitHubBinding(_ binding: GitHubSourceBinding, preview: UpdateRecord? = nil) {
        guard !isChecking, !isUpgrading else { return }
        githubBindings.removeAll { $0.id == binding.id || $0.installationPath == binding.installationPath }
        githubBindings.append(binding)
        persistGitHubBindings()
        if let preview, preview.id == binding.installationPath,
           preview.github?.binding.id == binding.id {
            replaceRecord(preview)
        } else if let app = snapshot?.records.first(where: { $0.id == binding.installationPath })?.app {
            var pending = UpdateRecord(app: app, source: .github, state: .unverified, detail: "尚未检查。")
            pending.github = GitHubUpdateInfo(binding: binding, checkedAt: Date(), identityNote: "用户指定")
            replaceRecord(pending)
        }
    }

    func removeGitHubBinding(for app: AppInfo) {
        guard !isChecking, !isUpgrading else { return }
        let id = githubBinding(for: app)?.id
        githubBindings.removeAll { $0.installationPath == app.id || $0.id == id }
        persistGitHubBindings()
        replaceRecord(SourceDiscovery.pendingRecord(for: app))
    }

    private func replaceRecord(_ record: UpdateRecord) {
        guard var updated = snapshot, let index = updated.records.firstIndex(where: { $0.id == record.id }) else { return }
        updated.records[index] = record
        skippedVersions.removeValue(forKey: record.id)
        persistSkippedVersions()
        snapshot = updated
        persist(updated)
    }

    private func persistGitHubBindings() {
        do { defaults.set(try JSONEncoder().encode(githubBindings), forKey: "githubSourceBindings") }
        catch { errorMessage = "GitHub 来源设置未能保存：\(error.localizedDescription)" }
    }

    func icon(for record: UpdateRecord) -> NSImage {
        if let image = icons[record.id] { return image }
        let image = (record.app ?? record.popClip?.host).map { NSWorkspace.shared.icon(forFile: $0.path.path) }
            ?? NSImage(systemSymbolName: "shippingbox", accessibilityDescription: record.source.title)!
        icons[record.id] = image
        return image
    }

    func setNotifications(_ enabled: Bool) {
        if !enabled { notifyNewUpdates = false; return }
        Task {
            do {
                notifyNewUpdates = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !notifyNewUpdates { errorMessage = "通知尚未获准，可在系统设置中允许 UpPear 通知。" }
            } catch { notifyNewUpdates = false; errorMessage = error.localizedDescription }
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                errorMessage = "请在系统设置的登录项中允许 UpPear。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; errorMessage = error.localizedDescription }
    }

    private func persist(_ snapshot: ScanSnapshot) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: cacheURL, options: .atomic)
        } catch { errorMessage = "检查已完成，但结果未能保存：\(error.localizedDescription)" }
    }

    private func persistSkippedVersions() {
        do { defaults.set(try JSONEncoder().encode(skippedVersions), forKey: "skippedVersions") }
        catch { errorMessage = "跳过设置未能保存：\(error.localizedDescription)" }
    }

    private func notifyIfNeeded(_ result: ScanSnapshot, previous: ScanSnapshot?) {
        guard notifyNewUpdates else { return }
        func fingerprint(_ record: UpdateRecord) -> String { record.id + "@" + (record.availableVersion ?? "") + "+" + (record.availableBuild ?? "") }
        let seen = Set(displayRecords(previous?.records ?? [])
            .filter { $0.state == .updateAvailable }.map(fingerprint))
        let newUpdates = displayRecords(result.records)
            .filter { $0.state == .updateAvailable && !seen.contains(fingerprint($0)) }
        guard !newUpdates.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "UpPear 发现 \(newUpdates.count) 个新更新"
        content.body = newUpdates.prefix(3).map(\.name).joined(separator: "、") + (newUpdates.count > 3 ? "等" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "new-updates", content: content, trigger: nil))
    }

}
