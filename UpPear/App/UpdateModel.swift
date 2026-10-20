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
    var primaryRegion: String { didSet { defaults.set(primaryRegion, forKey: "primaryRegion") } }
    var includePreReleases: Bool { didSet { defaults.set(includePreReleases, forKey: "includePreReleases") } }
    var includeFormulae: Bool { didSet { defaults.set(includeFormulae, forKey: "includeFormulae") } }
    var dailyCheck: Bool { didSet { defaults.set(dailyCheck, forKey: "dailyCheck") } }
    var notifyNewUpdates: Bool { didSet { defaults.set(notifyNewUpdates, forKey: "notifyNewUpdates") } }
    var ignoredIDs: Set<String>
    private(set) var skippedVersions: [String: SkippedUpdate]
    var loginEnabled = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    var records: [UpdateRecord] { UpdateSkipPolicy.applying(skippedVersions, to: snapshot?.records ?? []) }
    var updateCount: Int { records.filter { $0.state == .updateAvailable }.count }
    var failureCount: Int { snapshot?.failureCount ?? 0 }
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

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil) {
        self.defaults = defaults
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
                guard let self, self.dailyCheck, self.needsCheck, !self.isChecking, !self.isUpgrading,
                      self.lastAttempt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
                self.checkNow()
            }
        }
    }

    func checkNow() {
        guard !isChecking, !isUpgrading else { return }
        isChecking = true
        errorMessage = nil
        lastAttempt = Date()
        progress = ScanProgress("正在准备检查…")
        let options = CheckOptions(primaryRegion: primaryRegion, includePreReleases: includePreReleases,
                                   includeFormulae: includeFormulae, ignoredIDs: ignoredIDs)
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await UpdateEngine.scan(options: options) { [weak self] progress in
                    await MainActor.run { self?.progress = progress }
                }
                try Task.checkCancellation()
                let previous = self.snapshot
                self.skippedVersions = UpdateSkipPolicy.retaining(self.skippedVersions, after: result.records)
                self.persistSkippedVersions()
                self.snapshot = result
                self.persist(result)
                self.notifyIfNeeded(result, previous: previous)
            } catch is CancellationError {
                self.errorMessage = "检查已取消，上次完成的结果已保留。"
            } catch { self.errorMessage = error.localizedDescription }
            self.isChecking = false
            self.checkTask = nil
        }
    }

    func cancelCheck() { checkTask?.cancel() }

    func toggleIgnored(_ record: UpdateRecord) {
        guard !isChecking, !isUpgrading else { return }
        if ignoredIDs.contains(record.id) { ignoredIDs.remove(record.id) }
        else { ignoredIDs.insert(record.id) }
        skippedVersions.removeValue(forKey: record.id)
        persistSkippedVersions()
        defaults.set(Array(ignoredIDs).sorted(), forKey: "ignoredIDs")
        checkNow()
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
        case .extensionDownload(let url), .officialPage(let url):
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
        let seen = Set(UpdateSkipPolicy.applying(skippedVersions, to: previous?.records ?? [])
            .filter { $0.state == .updateAvailable }.map(fingerprint))
        let newUpdates = UpdateSkipPolicy.applying(skippedVersions, to: result.records)
            .filter { $0.state == .updateAvailable && !seen.contains(fingerprint($0)) }
        guard !newUpdates.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "UpPear 发现 \(newUpdates.count) 个新更新"
        content.body = newUpdates.prefix(3).map(\.name).joined(separator: "、") + (newUpdates.count > 3 ? "等" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "new-updates", content: content, trigger: nil))
    }

}
