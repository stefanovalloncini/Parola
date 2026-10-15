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
    private var voiceOverObservation: NSKeyValueObservation?
    private let menuBar = MenuBarController()
    private let dockBadge = DockBadge()
    private let recordingStatusItem = RecordingStatusItem()
    private let recordingPill = RecordingPill()
    private let takeAnnouncer = TakeAnnouncer()
    private let playbackKeys = PlaybackKeyMonitor()

    private var awaitingOwnReopen = false

    /// Our own reopen comes back through `applicationShouldHandleReopen`; answering it would ask again, forever, with any other window visible.
    func installReopenFallback(on model: AppModel, request: @escaping @MainActor () -> Void = {
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }) {
        self.model = model
        model.bindMainWindowReopenUntilASceneBinds { [weak self] in
            self?.awaitingOwnReopen = true
            request()
        }
    }

    func bind(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        provider.model = model
        menuBar.bind(model)
        dockBadge.bind(model)
        recordingStatusItem.bind(model)
        recordingPill.bind(model, appActive: NSApp.isActive)
        takeAnnouncer.bind(model)
        playbackKeys.bind(model)
        model.activationPolicyApplier = { NSApp.setActivationPolicy($0) }
        model.settingsWindowOpener = { SettingsWindowOpener.open() }
        installReopenFallback(on: model)
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
        if Self.postsMeetingNotifications(model.activeSideEffects) {
            let notifier = MeetingNotifier(
                center: SystemMeetingNotificationCenter(),
                promptInView: { [weak model] in model?.mainWindowIsKey ?? false }
            )
            notifier.bind(model)
        }
        if let startRecordingSubscription { NotificationCenter.default.removeObserver(startRecordingSubscription) }
        startRecordingSubscription = Self.observeStartRecording(for: model)
        voiceOverObservation = Self.followVoiceOver(for: model)
    }

    /// The saved-take toast waits for a VoiceOver user, and goes on its own again as soon as VoiceOver stops.
    static func followVoiceOver(for model: AppModel) -> NSKeyValueObservation {
        model.voiceOverIsRunning = NSWorkspace.shared.isVoiceOverEnabled
        return NSWorkspace.shared.observe(\.isVoiceOverEnabled) { @Sendable [weak model] _, _ in
            Task { @MainActor [weak model] in model?.voiceOverIsRunning = NSWorkspace.shared.isVoiceOverEnabled }
        }
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

    /// Only a launch that watches for meeting apps for real reaches the notification center, so no test host or sandbox asks for permission.
    nonisolated static func postsMeetingNotifications(_ sideEffects: Set<BootstrapSideEffect>) -> Bool {
        sideEffects.contains(.meetingDetector)
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
        if let model = AppDelegate.launchModel {
            bind(model: model)
            Task { await model.openMainWindowIfMissingAfterLaunch() }
        }
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
        NSApp.activate(ignoringOtherApps: true)
        return confirmingDiscard(choice(for: quitAlert().runModal()), ask: TakeRemote.askToDiscard)
    }

    /// ⌘Q only asks once the take captures, so it is never the question for a take still starting.
    static func quitAlert() -> NSAlert {
        let question = closeQuestion(starting: false)
        return takeAlert(message: question.message, detail: question.detail, discard: question.discard)
    }

    /// Discard… asks once more before anything is deleted, as every other Discard in the app does; a no keeps the take recording.
    static func confirmingDiscard(_ choice: AppModel.QuitDuringTake, ask: @MainActor () -> Bool) -> AppModel.QuitDuringTake {
        guard choice == .discard else { return choice }
        return ask() ? .discard : .keepRecording
    }

    /// The same question as a sheet on the window that is closing; its Discard… asks once more before anything is deleted.
    static func askAboutClosing(_ window: NSWindow, take: RecordingSession) async -> AppModel.QuitDuringTake {
        let question = closeQuestion(starting: take.isArming)
        let alert = takeAlert(message: question.message, detail: question.detail, discard: question.discard)
        return choice(for: await alert.beginSheetModal(for: window))
    }

    /// A take still starting has recorded nothing: the question doesn't speak of keeping it, and its Discard asks nothing more.
    nonisolated static func closeQuestion(starting: Bool, bundle: Bundle = .main) -> (message: String, detail: String, discard: String) {
        guard !starting else {
            return (
                String(localized: "A recording is starting", bundle: bundle),
                String(localized: "Nothing has been recorded yet.", bundle: bundle),
                String(localized: "Discard", bundle: bundle)
            )
        }
        return (
            String(localized: "A recording is in progress", bundle: bundle),
            String(localized: "Stop and Save keeps what you've recorded so far in your library.", bundle: bundle),
            String(localized: "Discard…", bundle: bundle)
        )
    }

    private static func takeAlert(message: String, detail: String, discard: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Stop and Save"))
        alert.addButton(withTitle: String(localized: "Keep Recording")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: discard).hasDestructiveAction = true
        return alert
    }

    private static func choice(for response: NSApplication.ModalResponse) -> AppModel.QuitDuringTake {
        switch response {
        case .alertFirstButtonReturn: .stopAndSave
        case .alertThirdButtonReturn: .discard
        default: .keepRecording
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ParolaLog.info(.appLifecycle, "app terminating in phase \(model?.phase)")
        model?.meetingNotifier?.withdraw()
        model?.readAloud.terminate()
        let diagnostics = DiagnosticsInstaller.current
        diagnostics?.stopPeriodicFlush()
        model?.flushWatchedArrivals()
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

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuBar.dockMenu()
    }

    /// SwiftUI reopens the main scene on a Dock click only when nothing is visible; a viewer or Settings alone has to bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let ours = awaitingOwnReopen
        awaitingOwnReopen = false
        guard flag, !ours, let model, model.mainWindow == nil else { return true }
        model.bringMainWindowForward()
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.handleAppResignedActive()
        recordingPill.appActiveChanged(false)
        model?.meetingNotifier?.windowLostSight()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        recordingPill.appActiveChanged(true)
        recordingStatusItem.appBecameActive()
        dockBadge.appBecameActive()
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

/// The Dock badge, kept by the app delegate so it follows a take with no window open; a take that fails, or stops on its own, while Parola is in the background bounces the icon once.
@MainActor
final class DockBadge {
    private weak var model: AppModel?
    private let show: @MainActor (String?) -> Void
    private let appIsActive: @MainActor () -> Bool
    private let requestAttention: @MainActor () -> Void
    private var shown: String??
    private var failure = OutOfSightFailure(includesTranscription: true)
    private var macStopWeighed: Int?

    init(
        show: @escaping @MainActor (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 },
        appIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        requestAttention: @escaping @MainActor () -> Void = { _ = NSApp.requestUserAttention(.informationalRequest) }
    ) {
        self.show = show
        self.appIsActive = appIsActive
        self.requestAttention = requestAttention
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

    /// Parola is in front: an ending held as unseen has been seen, so the next one out of sight asks for a look again.
    func appBecameActive() {
        failure.release()
        if let model { update(model) }
    }

    private func update(_ model: AppModel) {
        let heldBefore = failure.held
        if failure.holds(model.recording, stoppedOnItsOwn: model.takeStoppedOnItsOwn, appActive: appIsActive()), failure.held != heldBefore {
            requestAttention()
        }
        askForALookAtMacAudioStop(model)
        if let take = model.recording, take.isRunning {
            display(Self.recordingBadge(for: take, now: model.takeClockNow(following: take.state == .recording)))
        } else {
            let takeTranscribing = model.recording?.isTranscribing ?? false
            display(Self.badge(for: model.phase, takeTranscribing: takeTranscribing, burnProgress: model.burnJob?.progress))
        }
    }

    /// The Mac audio stopped while your microphone records on: one bounce then, if Parola is in the background, since the meeting goes on with your side only.
    private func askForALookAtMacAudioStop(_ model: AppModel) {
        guard model.takeMacAudioStopped, let take = model.recording, take.isCapturing, macStopWeighed != take.takeID else { return }
        macStopWeighed = take.takeID
        if !appIsActive() { requestAttention() }
    }

    private func display(_ label: String?) {
        guard shown != .some(label) else { return }
        shown = .some(label)
        show(label)
    }

    /// A take still starting has no time to show yet.
    nonisolated static func recordingBadge(for take: RecordingSession, now: Date) -> String {
        guard take.startedAt != nil else { return "…" }
        return AppFormat.elapsed(take.elapsed(at: now))
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
