import AppKit
import Combine
import Observation
import Sparkle

/// Defers installation without interrupting Codex turns or microphone work.
@MainActor final class UpdateInstallationGate {
    private var pending: (() -> Void)?
    var hasPendingInstallation: Bool { pending != nil }

    func deferIfNeeded(isBusy: Bool, install: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        pending = install
        return true
    }

    func resumeIfIdle(isBusy: Bool) {
        guard !isBusy, let install = pending else { return }
        pending = nil
        install()
    }

    func cancel() { pending = nil }
}

@MainActor @Observable final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private(set) var canCheckForUpdates = false
    private(set) var status = "Updates are available in release builds."
    private(set) var isEnabled = false
    var automaticallyChecks = false {
        didSet { if isEnabled, controller?.updater.automaticallyChecksForUpdates != automaticallyChecks { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    var automaticallyDownloads = false {
        didSet { if isEnabled, controller?.updater.automaticallyDownloadsUpdates != automaticallyDownloads { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations = Set<AnyCancellable>()
    @ObservationIgnored private var deferredTimer: Timer?
    @ObservationIgnored private let installation = UpdateInstallationGate()

    init(store: AppStore) { self.store = store; super.init() }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "PipUpdateChannel") as? String == "release" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            automaticallyChecks = controller.updater.automaticallyChecksForUpdates
            automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
            isEnabled = true
            status = "Updates are checked on GitHub Releases."
            controller.updater.publisher(for: \.canCheckForUpdates)
                .sink { [weak self] value in self?.canCheckForUpdates = value }.store(in: &observations)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .sink { [weak self] value in self?.automaticallyChecks = value }.store(in: &observations)
            controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
                .sink { [weak self] value in self?.automaticallyDownloads = value }.store(in: &observations)
        } catch { status = "Could not start updates: \(error.localizedDescription)" }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    private var isBusy: Bool {
        guard let store else { return false }
        return store.busyCount > 0 || store.voiceBusy || store.dictation.isPreparing || !store.requests.isEmpty
    }

    func activityChanged() {
        guard installation.hasPendingInstallation else { return }
        installation.resumeIfIdle(isBusy: isBusy)
        if !installation.hasPendingInstallation { deferredTimer?.invalidate(); deferredTimer = nil }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let deferred = installation.deferIfNeeded(isBusy: isBusy, install: installHandler)
        if deferred {
            status = "Update ready. Pip will restart after the current work finishes."
            deferredTimer?.invalidate()
            deferredTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.activityChanged() }
            }
        }
        return deferred
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { store?.persist() }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installation.cancel()
        deferredTimer?.invalidate(); deferredTimer = nil
        status = error.localizedDescription
    }
}
