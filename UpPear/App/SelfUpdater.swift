// Added for UpPear: its own Sparkle updater is independent of third-party probes.
import AppKit
import Combine
import Observation
@preconcurrency import Sparkle

@MainActor @Observable
final class SelfUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var isWaitingToRestart = false

    @ObservationIgnored let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate: SelfUpdateDelegate
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var started = false

    init() {
        let delegate = SelfUpdateDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: delegate, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }.store(in: &subscriptions)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }.store(in: &subscriptions)
        delegate.waitingToRestartChanged = { [weak self] in self?.isWaitingToRestart = $0 }
    }

    func start(isUpgradeInProgress: @escaping @MainActor () -> Bool) {
        delegate.isUpgradeInProgress = isUpgradeInProgress
        guard !started else { return }
        started = true
        // Sparkle owns its schedule and persisted preferences. Do not overwrite
        // those preferences or force a background check on every window opening.
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates, !delegate.isUpgradeInProgress() else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

@MainActor
final class SelfUpdateDelegate: NSObject, @preconcurrency SPUUpdaterDelegate {
    var isUpgradeInProgress: @MainActor () -> Bool = { false }
    var waitingToRestartChanged: @MainActor (Bool) -> Void = { _ in }
    private var deferredInstall: (() -> Void)?
    private var resumeTimer: Timer?

    // UpPear's own stable channel is independent of the preference used to
    // inspect other applications' pre-release feeds.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !isUpgradeInProgress() else {
            throw NSError(domain: "org.uppear.SelfUpdate", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "请等待当前软件升级完成后，再检查 UpPear 更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isUpgradeInProgress() else { return false }
        deferRestart(untilInvoking: installHandler)
        return true
    }

    // The operation is rechecked on the main actor before allowing Sparkle to
    // restart. Do not terminate Homebrew or cancel the user's running upgrade.
    func deferRestart(untilInvoking installHandler: @escaping () -> Void) {
        resumeTimer?.invalidate()
        deferredInstall = installHandler
        waitingToRestartChanged(true)
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resumeRestartIfReady() }
        }
    }

    func resumeRestartIfReady() {
        guard !isUpgradeInProgress(), let install = deferredInstall else { return }
        deferredInstall = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        waitingToRestartChanged(false)
        install()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        cancelDeferredRestart()
    }

    func cancelDeferredRestart() {
        guard deferredInstall != nil else { return }
        deferredInstall = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        waitingToRestartChanged(false)
    }
}
