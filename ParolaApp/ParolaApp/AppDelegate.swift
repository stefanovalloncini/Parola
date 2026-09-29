import AppKit
import CoreSpotlight
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
    private let menuBar = MenuBarController()
    private var recordingTickTask: Task<Void, Never>?
    private let playbackKeys = PlaybackKeyMonitor()

    func bind(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        provider.model = model
        menuBar.bind(model)
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
    }

    /// The signal reaches every process on the Mac, so only a launch that owns dictation's outside triggers answers it; a test sandbox never does.
    nonisolated static func hearsDictationSignal(_ sideEffects: Set<BootstrapSideEffect>) -> Bool {
        sideEffects.contains(.dictationHotkey)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--headless") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let model = AppDelegate.launchModel { bind(model: model) }
        ParolaLog.info(.appLifecycle, "app launched, version \(AppVersionToken())")
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
        let alert = NSAlert()
        alert.messageText = String(localized: "A recording is in progress")
        alert.informativeText = String(localized: "Stop and Save keeps what you've recorded so far in your library.")
        alert.addButton(withTitle: String(localized: "Stop and Save"))
        alert.addButton(withTitle: String(localized: "Keep Recording")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Discard")).hasDestructiveAction = true
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
    }

    func applicationDidBecomeActive(_ notification: Notification) {
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

    /// A burn shows its progress only while nothing in the window reports its own.
    func updateDockBadge(for phase: AppModel.Phase, burnProgress: Double? = nil) {
        switch phase {
        case .idle, .ready, .failed:
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = burnProgress.map { "\(Int($0 * 100))%" }
        case .downloadingModel(_, let progress):
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "\(Int(progress * 100))%"
        case .loadingModel, .fetchingLink(_, nil):
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "…"
        case .fetchingLink(_, let progress?):
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "\(Int(progress * 100))%"
        case .transcribing:
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "•"
        case .recording:
            startRecordingTick()
        }
    }

    /// Reads the take's own clock each second, turning over with the pane's.
    private func startRecordingTick() {
        if recordingTickTask != nil { return }
        recordingTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let startedAt = self?.model?.recordingStartedAt
                NSApp.dockTile.badgeLabel = Self.recordingBadge(startedAt: startedAt, now: Date())
                try? await Task.sleep(for: .seconds(Self.secondsToNextTick(startedAt: startedAt, now: Date())))
            }
        }
    }

    private func stopRecordingTick() {
        recordingTickTask?.cancel()
        recordingTickTask = nil
    }

    /// A take still starting has no time to show yet.
    nonisolated static func recordingBadge(startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "…" }
        return AppFormat.elapsed(now.timeIntervalSince(startedAt))
    }

    nonisolated static func secondsToNextTick(startedAt: Date?, now: Date) -> Double {
        guard let startedAt else { return 1 }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let next = elapsed.rounded(.down) + 1 - elapsed
        return max(0.05, next)
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
