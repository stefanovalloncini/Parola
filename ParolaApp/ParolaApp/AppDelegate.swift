import AppKit
import CoreSpotlight
import Observation
import ParolaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Handed over while the App value is built, so applicationDidFinishLaunching can bind before
    /// any window exists — a menu-bar-only launch that restores none would otherwise be unreachable.
    static weak var launchModel: AppModel?

    private weak var model: AppModel?
    private let provider = ServicesProvider()
    private var dictationSubscription: DictationSubscription?
    private var settingsResetSubscription: (any NSObjectProtocol)?
    private var startRecordingSubscription: (any NSObjectProtocol)?
    private let menuBar = MenuBarController()
    private let dockBadge = DockBadge()
    private let recordingStatusItem = RecordingStatusItem()
    private let recordingPill = RecordingPill()
    private let playbackKeys = PlaybackKeyMonitor()

    func bind(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        provider.model = model
        menuBar.bind(model)
        dockBadge.bind(model)
        recordingStatusItem.bind(model)
        recordingPill.bind(model, appActive: NSApp.isActive)
        playbackKeys.bind(model)
        model.activationPolicyApplier = { NSApp.setActivationPolicy($0) }
        model.applyAppVisibilityMode()
        if dictationSubscription == nil, Self.hearsDictationSignal(model.activeSideEffects) {
            dictationSubscription = DictationSignal.subscribe { [weak self] name in
                Task { @MainActor [weak self] in
                    guard let model = self?.model else { return }
                    switch name {
                    case DictationSignal.startName: model.startDictationFromIntent()
                    case DictationSignal.stopName:  model.stopDictationFromIntent()
                    default: break
                    }
                }
            }
        }
        if settingsResetSubscription == nil {
            settingsResetSubscription = NotificationCenter.default.addObserver(
                forName: .parolaSettingsReset, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.model?.reloadSettings() }
            }
        }
        if let startRecordingSubscription { NotificationCenter.default.removeObserver(startRecordingSubscription) }
        startRecordingSubscription = Self.observeStartRecording(for: model)
    }

    /// The Start Recording intent's signal, heard by the app rather than a window, so a take starts with none open.
    static func observeStartRecording(for model: AppModel, on center: NotificationCenter = .default) -> any NSObjectProtocol {
        center.addObserver(forName: .parolaStartRecording, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.startRecording(source: .microphone) }
        }
    }

    /// The signal reaches every process on the Mac, so only a launch that owns dictation's outside triggers answers it; a test sandbox never does.
    nonisolated static func hearsDictationSignal(_ sideEffects: Set<BootstrapSideEffect>) -> Bool {
        sideEffects.contains(.dictationHotkey)
    }

    /// The test host shares the app's own defaults domain, so only a normal launch rewrites it.
    nonisolated static func prunesStaleWindowKeys(_ sideEffects: Set<BootstrapSideEffect>) -> Bool {
        sideEffects.contains(.staleWindowKeyPrune)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--headless") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let model = AppDelegate.launchModel { bind(model: model) }
        ParolaLog.info(.appLifecycle, "app launched, version \(AppVersionToken())")
        if let model, Self.prunesStaleWindowKeys(model.activeSideEffects) { StaleWindowKeys.pruneInBackground() }
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        if CommandLine.arguments.contains("--headless") {
            for window in NSApp.windows { window.orderOut(nil) }
        } else {
            SparkleUpdater.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminateReply(for: model, ask: Self.presentQuitDuringTakeAlert) { quits in
            sender.reply(toApplicationShouldTerminate: quits)
        }
    }

    /// A take capturing asks first; a quit then waits until every take is in the library, and a second quit meanwhile is refused.
    static func terminateReply(
        for model: AppModel?,
        ask: @MainActor () -> AppModel.QuitDuringTake,
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.quitPending { return .terminateCancel }
        if model.takeInProgress {
            let choice = ask()
            guard choice != .keepRecording else { return .terminateCancel }
            model.quitPending = true
            Task { @MainActor in
                reply(await model.resolveQuitDuringTake(choice))
            }
            return .terminateLater
        }
        guard model.hasPendingTakeWork else { return .terminateNow }
        model.quitPending = true
        Task { @MainActor in
            await model.finishTakeWorkForQuit()
            reply(true)
        }
        return .terminateLater
    }

    static func presentQuitDuringTakeAlert() -> AppModel.QuitDuringTake {
        askAboutTake(discardTitle: String(localized: "Discard"))
    }

    /// The same question for the main window closing; its Discard… asks once more before anything is deleted.
    static func presentCloseDuringTakeAlert() -> AppModel.QuitDuringTake {
        askAboutTake(discardTitle: String(localized: "Discard…"))
    }

    private static func askAboutTake(discardTitle: String) -> AppModel.QuitDuringTake {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "A recording is in progress")
        alert.informativeText = String(localized: "Stop and Save keeps what you've recorded so far in your library.")
        alert.addButton(withTitle: String(localized: "Stop and Save"))
        alert.addButton(withTitle: String(localized: "Keep Recording")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: discardTitle).hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .stopAndSave
        case .alertThirdButtonReturn: return .discard
        default: return .keepRecording
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ParolaLog.info(.appLifecycle, "app terminating in phase \(model?.phase)")
        let diagnostics = DiagnosticsInstaller.current
        diagnostics?.stopPeriodicFlush()
        let pending = model?.cancelAndDrainPendingTranscriptSave()
        let library = model?.library
        let flushBaselines = model?.watchedFolderBaselineFlush()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let library {
                if let pending {
                    try? await library.updateTranscript(pending.transcript, for: pending.id)
                }
                await library.flush()
            }
            await flushBaselines?()
            await diagnostics?.flushForTermination()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.handleAppResignedActive()
        recordingPill.appActiveChanged(false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        recordingPill.appActiveChanged(true)
        model?.refreshLibraryIfChangedElsewhere()
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let url = Self.spotlightOpenURL(from: userActivity), let model else { return false }
        NSApp.activate(ignoringOtherApps: true)
        handleParolaOpen(url, model: model)
        return true
    }

    static func spotlightOpenURL(from userActivity: NSUserActivity) -> URL? {
        guard userActivity.activityType == CSSearchableItemActionType,
              let entryID = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        var components = URLComponents()
        components.scheme = "parola"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "entry", value: entryID)]
        return components.url
    }
}

/// The Dock badge, kept by the app delegate so it follows a take with no window open.
@MainActor
final class DockBadge {
    private weak var model: AppModel?
    private let show: @MainActor (String?) -> Void
    private var shown: String??
    private var tick: Task<Void, Never>?

    init(show: @escaping @MainActor (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }) {
        self.show = show
    }

    func bind(_ model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            update(model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func update(_ model: AppModel) {
        if let take = model.recording, take.isRunning {
            display(Self.recordingBadge(for: take, now: Date()))
            startTick()
        } else {
            stopTick()
            let takeTranscribing = model.recording?.isTranscribing ?? false
            display(Self.badge(for: model.phase, takeTranscribing: takeTranscribing, burnProgress: model.burnJob?.progress))
        }
    }

    private func display(_ label: String?) {
        guard shown != .some(label) else { return }
        shown = .some(label)
        show(label)
    }

    /// Reads the take's own clock each second, turning over with the pane's.
    private func startTick() {
        guard tick == nil else { return }
        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.showTakeClock() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
    }

    private func showTakeClock() -> Double {
        guard let take = model?.recording, take.isRunning else { return 1 }
        let now = Date()
        display(Self.recordingBadge(for: take, now: now))
        return Self.secondsToNextTick(for: take, now: now)
    }

    /// A take still starting has no time to show yet.
    nonisolated static func recordingBadge(for take: RecordingSession, now: Date) -> String {
        guard take.startedAt != nil else { return "…" }
        return AppFormat.elapsed(take.elapsed(at: now))
    }

    nonisolated static func secondsToNextTick(for take: RecordingSession, now: Date) -> Double {
        guard take.startedAt != nil else { return 1 }
        let elapsed = take.elapsed(at: now)
        let next = elapsed.rounded(.down) + 1 - elapsed
        return max(0.05, next)
    }

    /// A burn shows its progress only while nothing in the window reports its own; a take transcribing reports as a file's run does.
    nonisolated static func badge(for phase: AppModel.Phase, takeTranscribing: Bool, burnProgress: Double?) -> String? {
        switch phase {
        case .idle, .ready, .failed:
            if takeTranscribing { return "•" }
            return burnProgress.map { "\(Int($0 * 100))%" }
        case .downloadingModel(_, let progress):
            return "\(Int(progress * 100))%"
        case .loadingModel, .fetchingLink(_, nil):
            return "…"
        case .fetchingLink(_, let progress?):
            return "\(Int(progress * 100))%"
        case .transcribing:
            return "•"
        }
    }
}

@MainActor
final class ServicesProvider: NSObject {
    weak var model: AppModel?

    @objc func transcribeFile(_ pasteboard: NSPasteboard, userData: String?, error errorPtr: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handle(pasteboard: pasteboard, translate: false, errorPtr: errorPtr)
    }

    @objc func translateFile(_ pasteboard: NSPasteboard, userData: String?, error errorPtr: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handle(pasteboard: pasteboard, translate: true, errorPtr: errorPtr)
    }

    private func handle(pasteboard: NSPasteboard, translate: Bool, errorPtr: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            errorPtr?.pointee = "No audio or video file found on the pasteboard." as NSString
            return
        }
        guard let model else {
            errorPtr?.pointee = "Parola is not ready." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        model.receive(urls) { [weak model] in model?.handleIncomingFiles($0, translateOverride: translate) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        if let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
