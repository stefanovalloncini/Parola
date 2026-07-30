import AppKit
import CoreSpotlight
import ParolaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private let provider = ServicesProvider()
    private var dictationStatusItem: DictationStatusItem?
    private var dictationSubscription: DictationSubscription?
    private var settingsResetSubscription: (any NSObjectProtocol)?
    private let menuBar = MenuBarController()
    private var recordingTickTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private let playbackKeys = PlaybackKeyMonitor()
    private var appearanceObservation: NSKeyValueObservation?

    func bind(model: AppModel) {
        self.model = model
        provider.model = model
        if dictationStatusItem == nil {
            dictationStatusItem = DictationStatusItem(model: model)
        }
        menuBar.bind(model)
        playbackKeys.bind(model)
        if dictationSubscription == nil {
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
        // Covers both the Appearance setting (which assigns NSApp.appearance) and system dark-mode
        // flips, either of which can change which variant a dynamic accent resolves to.
        if appearanceObservation == nil {
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
                Task { @MainActor in DockIcon.refresh() }
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--headless") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        if CommandLine.arguments.contains("--headless") {
            for window in NSApp.windows { window.orderOut(nil) }
        } else {
            SparkleUpdater.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let model else { return }
        let pending = model.cancelAndDrainPendingTranscriptSave()
        let library = model.library
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let pending {
                try? await library.updateTranscript(pending.transcript, for: pending.id)
            }
            await library.flush()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.handleAppResignedActive()
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

    func updateDockBadge(for phase: AppModel.Phase) {
        switch phase {
        case .idle, .ready, .failed:
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = nil
        case .downloadingModel(_, let progress), .exporting(let progress):
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "\(Int(progress * 100))%"
        case .loadingModel:
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "…"
        case .transcribing:
            stopRecordingTick()
            NSApp.dockTile.badgeLabel = "•"
        case .recording:
            startRecordingTick()
        }
    }

    private func startRecordingTick() {
        if recordingTickTask != nil { return }
        recordingStartedAt = Date()
        NSApp.dockTile.badgeLabel = "0:00"
        recordingTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let start = self?.recordingStartedAt else { return }
                let elapsed = Int(Date().timeIntervalSince(start))
                let m = elapsed / 60
                let s = elapsed % 60
                NSApp.dockTile.badgeLabel = String(format: "%d:%02d", m, s)
            }
        }
    }

    private func stopRecordingTick() {
        recordingTickTask?.cancel()
        recordingTickTask = nil
        recordingStartedAt = nil
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
        guard let url = Self.firstFileURL(from: pasteboard) else {
            errorPtr?.pointee = "No audio or video file found on the pasteboard." as NSString
            return
        }
        guard let model else {
            errorPtr?.pointee = "Parola is not ready." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        model.transcribe(fileURL: url, translateOverride: translate)
    }

    static func firstFileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return url
        }
        if let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           let path = names.first {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
