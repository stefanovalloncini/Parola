import AppKit
import Combine
import Foundation
import os
import ParolaCore
import ParolaDictation
import SwiftUI

@MainActor
@Observable
final class DictationController {
    private(set) var state: DictationCoordinator.State = .idle
    @ObservationIgnored let audioLevel = CurrentValueSubject<Float, Never>(0)
    private(set) var partialText: String = "" {
        didSet {
            recentDictation = Self.capped(partialText)
            if oldValue.isEmpty != partialText.isEmpty { resizeHUDForPartial() }
        }
    }
    private(set) var recentDictation: String = ""

    private(set) var modelDownloadProgress: Double? {
        didSet {
            guard (oldValue == nil) != (modelDownloadProgress == nil), let panel = hud else { return }
            panel.setFrame(preferredHUDFrame(), display: true, animate: false)
        }
    }

    private static let recentDictationCharLimit = 600

    private static func capped(_ text: String) -> String {
        guard text.count > recentDictationCharLimit else { return text }
        let tail = text.suffix(recentDictationCharLimit)
        guard let wordStart = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) else {
            return String(tail)
        }
        return "…" + tail[tail.index(after: wordStart)...]
    }

    var indicatorStyle: DictationIndicatorStyle = .nearField {
        didSet {
            guard oldValue != indicatorStyle, let panel = hud else { return }
            refreshAnchor()
            panel.setFrame(preferredHUDFrame(), display: true, animate: true)
            if panel.isVisible { startRepositionLoop() }
        }
    }

    @ObservationIgnored var transcriptionStopGrace: Duration = .seconds(3)
    @ObservationIgnored var teardownBound: Duration = .seconds(30)

    @ObservationIgnored var anchorProvider: any FieldAnchorProviding = FocusedFieldLocator()
    @ObservationIgnored var hotkeyFactory: ((Int, NSEvent.ModifierFlags) -> any HotkeyMonitor)?
    @ObservationIgnored var recorderFactory: ((Configuration) -> any DictationRecorder)?
    @ObservationIgnored var inserterFactory: (() -> any TextInserter)?
    @ObservationIgnored private var pasteGate = PasteGate()
    private(set) var currentAnchor: FieldAnchor?

    var configuration: Configuration?
    weak var appModel: AppModel?

    struct Configuration {
        var modelName: String
        var language: String?
        var initialPrompt: String? = nil
        var deviceUID: String?
        var streamingEnabled: Bool
        var hotkeyKeyCode: Int
        var hotkeyModifiers: NSEvent.ModifierFlags = []
        /// Off unless the launch owns the dictation hotkey: a test sandbox must not hear keys pressed in other apps.
        var listensForHotkey = false
        var mode: DictationMode
        var workflows: [String: [DictationWorkflow]]
        var postProcessor: any TextPostProcessor
        var pasteDelayMs: Int = 0
        var mediaSession: MediaSession? = nil
        var mediaConfigProvider: (@Sendable () async -> MediaSessionConfig)? = nil
    }

    private var coordinator: DictationCoordinator?
    /// Bumped whenever the live coordinator is replaced or dropped, so a replaced
    /// coordinator's trailing state callbacks can't overwrite the live session's state.
    @ObservationIgnored private var coordinatorGeneration = 0
    private var hud: NSPanel?
    private var levelTask: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?
    private var failedHideTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?
    @ObservationIgnored private(set) var monitorWork: Task<Void, Never>?

    /// The coordinator actor is reentrant, so an unordered stop can complete while a
    /// startMonitoring is still mid-install and orphan live NSEvent monitors. Chaining
    /// every monitor operation behind the previous one keeps teardown and install ordered.
    private func enqueueMonitorWork(_ op: @escaping @Sendable () async -> Void) {
        let previous = monitorWork
        monitorWork = Task {
            await previous?.value
            await op()
        }
    }

    /// Chained like `enqueueMonitorWork`, but the next op waits for this one at most `limit`, and this one is never cancelled.
    private func enqueueMonitorWork(waitingAtMost limit: Duration, _ op: @escaping @Sendable () async -> Void) {
        let previous = monitorWork
        let work = Task {
            await previous?.value
            await op()
        }
        monitorWork = Task { _ = await AsyncTimeout.run(limit) { await work.value } }
    }

    isolated deinit {
        levelTask?.cancel()
        partialTask?.cancel()
        failedHideTask?.cancel()
        repositionTask?.cancel()
    }

    func start(configuration: Configuration) {
        guard coordinator == nil else { return }
        self.configuration = configuration
        let hotkey = hotkeyFactory?(configuration.hotkeyKeyCode, configuration.hotkeyModifiers)
            ?? Self.hotkeyMonitor(for: configuration)
        let workflows = configuration.workflows
        // Own session, not appModel.session: the shared one serializes whole transcribe
        // runs, so a fallback dictation stop would queue for minutes behind a long
        // file/YouTube job. Costs a second loaded model only while both run at once.
        let recorder = recorderFactory?(configuration) ?? MicDictationRecorder(
            model: configuration.modelName,
            language: configuration.language,
            initialPrompt: configuration.initialPrompt,
            deviceUID: configuration.deviceUID,
            streamingEnabled: configuration.streamingEnabled,
            session: nil,
            workflowResolver: { @Sendable in
                await Self.resolveWorkflow(in: workflows)
            },
            downloadProgress: { [weak self] fraction in
                Task { @MainActor in self?.noteModelDownloadProgress(fraction) }
            }
        )
        let inserter: any TextInserter
        if let inserterFactory {
            inserter = inserterFactory()
        } else if appModel?.mode == .test {
            inserter = CapturingTextInserter()
        } else {
            inserter = PerAppTextInserter(
                paste: ClipboardPasteInserter(preDelayMs: configuration.pasteDelayMs)
            ) { @Sendable in
                let workflow = await Self.resolveWorkflow(in: workflows)
                return workflow?.insertion ?? .paste
            }
        }
        coordinatorGeneration += 1
        let generation = coordinatorGeneration
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: GatedTextInserter(base: inserter, gate: pasteGate),
            postProcessor: configuration.postProcessor,
            mode: configuration.mode,
            mediaSession: configuration.mediaSession,
            mediaConfigProvider: configuration.mediaConfigProvider
        ) { [weak self] state in
            await MainActor.run { self?.handleStateChange(state, generation: generation) }
        }
        coordinator = coord
        enqueueMonitorWork { await coord.startMonitoring() }
    }

    /// Without the hotkey the coordinator still arms, so `simulatePress()` and `simulateRelease()` keep working.
    static func hotkeyMonitor(for configuration: Configuration) -> any HotkeyMonitor {
        guard configuration.listensForHotkey else { return SilentHotkeyMonitor() }
        return GlobalHotkeyMonitor(keyCode: configuration.hotkeyKeyCode, modifiers: configuration.hotkeyModifiers)
    }

    func stop() {
        coordinatorGeneration += 1
        guard let coord = coordinator else {
            state = .idle
            appModel?.dictationState = .idle
            modelDownloadProgress = nil
            hideHUD()
            return
        }
        coordinator = nil
        failedHideTask?.cancel()
        failedHideTask = nil
        // A last utterance still lands and is inserted, however long its flush takes; only the next install stops waiting for it.
        enqueueMonitorWork(waitingAtMost: teardownBound) { await coord.stopMonitoring() }
        stopPartialStream()
        modelDownloadProgress = nil
        hideHUD()
        state = .idle
        appModel?.dictationState = .idle
    }

    /// Tears dictation down and DISCARDS any in-flight recording without transcribing
    /// or inserting it. Unlike `stop()` (which flushes the pending utterance) this is the
    /// teardown for a hard reset, so a leaked listening session can't bleed — coordinator,
    /// HUD, and state — into the next test.
    /// Turning dictation off drops what it would still paste, from this session or one a restart left finishing.
    func discardAndStop() {
        pasteGate.close()
        pasteGate = PasteGate()
        abort()
    }

    func abort() {
        coordinatorGeneration += 1
        guard let coord = coordinator else {
            state = .idle
            appModel?.dictationState = .idle
            modelDownloadProgress = nil
            hideHUD()
            return
        }
        coordinator = nil
        failedHideTask?.cancel()
        failedHideTask = nil
        enqueueMonitorWork { await coord.abortMonitoring() }
        stopPartialStream()
        modelDownloadProgress = nil
        hideHUD()
        state = .idle
        appModel?.dictationState = .idle
    }

    func setMode(_ mode: DictationMode) {
        guard let coord = coordinator else { return }
        configuration?.mode = mode
        Task { await coord.setMode(mode) }
    }

    func setPostProcessor(_ processor: any TextPostProcessor) {
        guard let coord = coordinator else { return }
        configuration?.postProcessor = processor
        Task { await coord.setPostProcessor(processor) }
    }

    func simulatePress() {
        guard let coord = coordinator else { return }
        Task { await coord.simulatePress() }
    }

    func simulateRelease() {
        guard let coord = coordinator else { return }
        Task { await coord.simulateRelease() }
    }

    /// Stops in every mode, unlike a simulated release. A final already under way lands and is inserted, unless `giveUpAfter` runs out first.
    func requestStop(giveUpAfter grace: Duration? = nil) {
        guard let coord = coordinator else { return }
        guard case .transcribing = state, let grace else {
            Task { await coord.stopListening() }
            return
        }
        let generation = coordinatorGeneration
        Task { [weak self] in
            guard await coord.giveUpOnTranscription(after: grace) else { return }
            guard let self, generation == self.coordinatorGeneration else { return }
            self.rearm()
        }
    }

    /// The HUD's Cancel: the final under way is dropped at once and nothing is pasted.
    func cancelTranscription() {
        guard let coord = coordinator, case .transcribing = state else { return }
        let generation = coordinatorGeneration
        hideHUD()
        Task { [weak self] in
            guard await coord.abandonTranscription() else { return }
            guard let self, generation == self.coordinatorGeneration else { return }
            self.rearm()
        }
    }

    /// The coordinator that gave up may still be stuck in its recorder, so a fresh pair takes over.
    private func rearm() {
        guard let configuration else { return }
        stop()
        start(configuration: configuration)
    }

    var isRunning: Bool { coordinator != nil }

    /// A first-ever dictation press downloads the model while the coordinator is still `.idle`
    /// and the HUD hidden; showing it here is the only feedback the user gets during that wait.
    func noteModelDownloadProgress(_ fraction: Double) {
        guard isRunning else { return }
        if fraction >= 1 {
            modelDownloadProgress = nil
            return
        }
        let percent = Int(fraction * 100)
        guard percent != modelDownloadProgress.map({ Int($0 * 100) }) else { return }
        modelDownloadProgress = fraction
        showHUD()
    }

    private func handleStateChange(_ state: DictationCoordinator.State, generation: Int) {
        guard generation == coordinatorGeneration else { return }
        self.state = state
        appModel?.dictationState = state
        modelDownloadProgress = nil
        failedHideTask?.cancel()
        failedHideTask = nil
        switch state {
        case .idle:
            hideHUD()
        case .listening:
            showHUD()
            startLevelStream()
            startPartialStream()
        case .transcribing:
            showHUD()
            stopLevelStream()
        case .failed:
            showHUD()
            stopLevelStream()
            stopPartialStream()
            failedHideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                if case .failed = self.state { self.hideHUD() }
            }
        }
    }

    private func startLevelStream() {
        guard let coord = coordinator else { return }
        levelTask?.cancel()
        let subject = audioLevel
        levelTask = Task { @MainActor in
            let stream = await coord.levels()
            for await level in stream {
                if abs(subject.value - level) > 0.05 {
                    subject.send(level)
                }
            }
        }
    }

    private func stopLevelStream() {
        levelTask?.cancel()
        levelTask = nil
        audioLevel.send(0)
    }

    private func startPartialStream() {
        guard let coord = coordinator else { return }
        partialTask?.cancel()
        partialText = ""
        recentDictation = ""
        partialTask = Task { @MainActor [weak self] in
            let stream = await coord.partials()
            for await text in stream {
                guard let self else { return }
                if self.partialText != text {
                    self.partialText = text
                }
            }
        }
    }

    private func stopPartialStream() {
        partialTask?.cancel()
        partialTask = nil
        partialText = ""
        recentDictation = ""
    }

    private func showHUD() {
        guard let model = appModel else { return }
        if hud == nil {
            hud = DictationHUD.make { [self] in
                DictationView(
                    model: model,
                    controller: self,
                    onStop: { model.stopDictationFromIntent() },
                    onCancel: { self.cancelTranscription() }
                )
            }
        }
        guard let panel = hud else { return }
        refreshAnchor()
        panel.setFrame(preferredHUDFrame(), display: true, animate: false)
        panel.orderFrontRegardless()
        startRepositionLoop()
    }

    @discardableResult
    func refreshAnchor() -> Bool {
        let anchor = indicatorStyle == .nearField ? anchorProvider.currentAnchor() : nil
        guard anchor != currentAnchor else { return false }
        currentAnchor = anchor
        return true
    }

    private func startRepositionLoop() {
        repositionTask?.cancel()
        guard indicatorStyle == .nearField else {
            repositionTask = nil
            return
        }
        repositionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                guard let panel = self.hud, panel.isVisible else { continue }
                guard self.refreshAnchor() else { continue }
                let target = self.preferredHUDFrame()
                if panel.frame != target {
                    panel.setFrame(target, display: true, animate: false)
                }
            }
        }
    }

    private func resizeHUDForPartial() {
        guard let panel = hud else { return }
        let target = preferredHUDFrame()
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true, animate: false)
    }

    private func preferredHUDFrame() -> NSRect {
        let listeningCompact: Bool
        if case .listening = state { listeningCompact = true } else { listeningCompact = modelDownloadProgress != nil }
        let failedMessageVisible: Bool
        if case .failed(let message) = state { failedMessageVisible = !message.isEmpty } else { failedMessageVisible = false }
        let screen = NSScreen.main
        return DictationHUDPlacement.frame(DictationHUDPlacement.Context(
            style: indicatorStyle,
            hasPartial: !partialText.isEmpty,
            failedMessageVisible: failedMessageVisible,
            listeningCompact: listeningCompact,
            anchor: currentAnchor,
            screenFrame: screen?.frame ?? .zero,
            screenVisibleFrame: screen?.visibleFrame ?? .zero
        ))
    }

    private func hideHUD() {
        stopLevelStream()
        repositionTask?.cancel()
        repositionTask = nil
        currentAnchor = nil
        hud?.orderOut(nil)
    }

    static func resolveWorkflow(in workflows: [String: [DictationWorkflow]]) async -> DictationWorkflow? {
        let bundleID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        guard let bundleID else { return nil }
        let url: URL?
        if DictationWorkflowMap.hasURLRules(in: workflows, for: bundleID) {
            url = await BrowserURLResolver.shared.currentURL(for: bundleID)
        } else {
            url = nil
        }
        return DictationWorkflowMap.select(in: workflows, for: bundleID, url: url)
    }
}

/// Open while dictation stays on. A final that lands after it closes would paste into whatever app is in front by then.
private final class PasteGate: Sendable {
    private let open = OSAllocatedUnfairLock(initialState: true)

    var isOpen: Bool { open.withLock { $0 } }

    func close() { open.withLock { $0 = false } }
}

private struct GatedTextInserter: TextInserter {
    let base: any TextInserter
    let gate: PasteGate

    func insert(_ text: String) async throws {
        guard gate.isOpen else { return }
        try await base.insert(text)
    }
}
