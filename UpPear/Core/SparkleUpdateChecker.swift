// SparkleUpdateChecker.swift — Pearcleaner
// Created by Alin Lupascu on 10/28/25.
// Modified for UpPear on 2026-10-13. Derived from Pearcleaner 5.4.3,
// c52695d90c43f60abd5cd10c363f2e122c65f191. See LICENSE.md.
// Retains SPUUpdater operations, version/channel/OS selection and no-update
// reasons. Uses Sparkle's probe API, never offers an installation, does not
// cache candidates across differently filtered appcasts, and adds watchdogs.
import Foundation
@preconcurrency import Sparkle

@MainActor
enum SparkleUpdateChecker {
    fileprivate static var activeOperations: [UUID: SparkleCheckerOperation] = [:]

    static func check(app: AppInfo, includePreReleases: Bool) async -> UpdateRecord {
        guard !app.isAppStore, !app.isSetapp, let feedURL = app.feedURL,
              let bundle = Bundle(url: app.bundlePath) else {
            return UpdateRecord(app: app, source: .sparkle, state: .unsupported, detail: "没有可用的 Sparkle 更新源。")
        }
        let key = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let operation = SparkleCheckerOperation(key: key, appInfo: app, bundle: bundle,
                    feedURL: feedURL, includePreReleases: includePreReleases) { result in
                        continuation.resume(returning: result)
                    }
                activeOperations[key] = operation
                if Task.isCancelled { operation.cancel() } else { operation.start() }
            }
        } onCancel: {
            Task { @MainActor in activeOperations[key]?.cancel() }
        }
    }
}

@MainActor
private class SparkleCheckerOperation: NSObject, @preconcurrency SPUUserDriver, @preconcurrency SPUUpdaterDelegate {
    private let key: UUID
    private let appInfo: AppInfo
    private let bundle: Bundle
    private let feedURL: URL
    private let includePreReleases: Bool
    private let completion: (UpdateRecord) -> Void
    private var updater: SPUUpdater?
    private var watchdog: Task<Void, Never>?
    private var finished = false
    private var pendingResult: UpdateRecord?
    private var sawAppcast = false

    init(key: UUID, appInfo: AppInfo, bundle: Bundle, feedURL: URL,
         includePreReleases: Bool, completion: @escaping (UpdateRecord) -> Void) {
        self.key = key
        self.appInfo = appInfo
        self.bundle = bundle
        self.feedURL = feedURL
        self.includePreReleases = includePreReleases
        self.completion = completion
        super.init()
    }

    func start() {
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            // Public probe API downloads appcast information only. Invoke before
            // Sparkle's scheduled cycle, exactly as required by its API docs.
            updater.checkForUpdateInformation()
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.finish(with: .init(app: self?.appInfo, source: .sparkle, state: .failed,
                                         detail: CheckError.timedOut.localizedDescription))
            }
        } catch {
            finish(with: .init(app: appInfo, source: .sparkle, state: .failed, detail: error.localizedDescription))
        }
    }

    func cancel() {
        finish(with: .init(app: appInfo, source: .sparkle, state: .failed, detail: "检查已取消。"))
    }

    private func finish(with result: UpdateRecord) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        completion(result)
        updater = nil
        SparkleUpdateChecker.activeOperations[key] = nil
    }

    private func createUpdate(from item: SUAppcastItem) -> UpdateRecord {
        let isPreRelease = (item.channel.map { $0.lowercased() != "release" } ?? false)
            || isPreReleaseVersion(item.displayVersionString)
        return UpdateRecord(app: appInfo, source: .sparkle, state: .updateAvailable,
            detail: "请打开应用，使用应用自带的更新功能。", availableVersion: item.displayVersionString,
            availableBuild: item.versionString, releaseNotes: item.itemDescription,
            releaseNotesURL: item.releaseNotesURL ?? item.fullReleaseNotesURL,
            releaseDate: item.dateString, isPreRelease: isPreRelease)
    }

    // MARK: - SPUUpdaterDelegate / probe callbacks
    func feedURLString(for updater: SPUUpdater) -> String? { feedURL.absoluteString }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includePreReleases ? ["beta", "alpha", "nightly", "rc", "dev", "release"] : ["release"]
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updateInformation, !finished else { throw CancellationError() }
    }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) { sawAppcast = true }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingResult = createUpdate(from: item)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let error = error as NSError
        let latestItem = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let rawValue = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value ?? 0
        let reason = SPUNoUpdateFoundReason(rawValue: rawValue) ?? .unknown
        let state: CheckState
        let detail: String
        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion:
            state = .current
            detail = "更新源未显示更高的兼容版本。"
        case .systemIsTooOld, .systemIsTooNew:
            state = .unsupported
            detail = "最新版本不兼容当前 macOS。请在应用内确认。"
        default:
            state = .unsupported
            detail = "更新源没有可确认的稳定兼容版本；被应用跳过的版本也可能被隐藏。"
        }
        pendingResult = .init(app: appInfo, source: .sparkle, state: state, detail: detail,
                             availableVersion: latestItem?.displayVersionString)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if pendingResult == nil {
            pendingResult = .init(app: appInfo, source: .sparkle, state: .failed, detail: error.localizedDescription)
        }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let pendingResult { finish(with: pendingResult); return }
        finish(with: .init(app: appInfo, source: .sparkle,
            state: error == nil && sawAppcast ? .unsupported : .failed,
            detail: error?.localizedDescription ?? "更新源没有提供可比较的版本信息。"))
    }

    // Pearcleaner's candidate selection, retaining display/build comparison.
    // Do not cache across callbacks: Sparkle supplies different filtered sets.
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let installedDisplayVersion = appInfo.appVersion
        let installedBuild = appInfo.appBuildNumber
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentMacOSVersion = Version(versionNumber: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", buildNumber: nil)
        let sortedItems = appcast.items.sorted { item1, item2 in
            let ver1 = Version(versionNumber: item1.displayVersionString, buildNumber: nil)
            let ver2 = Version(versionNumber: item2.displayVersionString, buildNumber: nil)
            if ver1 == ver2 { return item1.versionString.compare(item2.versionString, options: .numeric) == .orderedDescending }
            return ver1 > ver2
        }
        for item in sortedItems {
            if let minOS = item.minimumSystemVersion,
               currentMacOSVersion < Version(versionNumber: minOS, buildNumber: nil) { continue }
            if let maxOS = item.maximumSystemVersion,
               currentMacOSVersion > Version(versionNumber: maxOS, buildNumber: nil) { continue }
            if let channel = item.channel, channel.lowercased() != "release", !includePreReleases { continue }
            if isPreReleaseVersion(item.displayVersionString), !includePreReleases { continue }
            let installedDisplayVer = Version(versionNumber: installedDisplayVersion, buildNumber: nil)
            let availableDisplayVer = Version(versionNumber: item.displayVersionString, buildNumber: nil)
            let displayIsNewer = availableDisplayVer > installedDisplayVer
            let buildIsNewer = installedBuild.map { item.versionString.compare($0, options: .numeric) == .orderedDescending } ?? false
            // Never suggest a marketing-version downgrade because its build is
            // larger. Keep build-only upgrades when marketing versions match.
            if displayIsNewer || ((availableDisplayVer == installedDisplayVer || installedDisplayVer.isEmpty) && buildIsNewer) {
                return item
            }
        }
        return nil
    }

    // Probe mode does not show installation UI. These defensive replies ensure
    // future API changes cannot turn a detection into an unattended update.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { cancellation() }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateInFocus() {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancellation() }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showCanCheck(forUpdates canCheckForUpdates: Bool) {}
    func dismissUserInitiatedUpdateCheck() {}
    func showSendingTerminationSignal() {}
    func dismissUpdateInstallation() {}
}
