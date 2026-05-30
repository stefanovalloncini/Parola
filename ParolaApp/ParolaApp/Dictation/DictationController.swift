import AppKit
import Combine
import Foundation
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

    private static let recentDictationCharLimit = 600

    private static func capped(_ text: String) -> String {
        guard text.count > recentDictationCharLimit else { return text }
        let tail = text.suffix(recentDictationCharLimit)
        guard let wordStart = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) else {
            return String(tail)
        }
        return "…" + tail[tail.index(after: wordStart)...]
    }

    var indicatorStyle: DictationIndicatorStyle = .overlay {
        didSet {
            guard oldValue != indicatorStyle, let panel = hud else { return }
            panel.setFrame(preferredHUDFrame(), display: true, animate: true)
        }
    }

    var configuration: Configuration?
    weak var appModel: AppModel?

    struct Configuration {
        var modelName: String
        var language: String?
        var deviceUID: String?
        var streamingEnabled: Bool
        var hotkeyKeyCode: Int
        var hotkeyModifiers: NSEvent.ModifierFlags = []
        var mode: DictationMode
        var workflows: [String: [DictationWorkflow]]
        var postProcessor: any TextPostProcessor
        var pasteDelayMs: Int = 0
    }

    private var coordinator: DictationCoordinator?
    private var hud: NSPanel?
    private var levelTask: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?
    private var failedHideTask: Task<Void, Never>?

    isolated deinit {
        levelTask?.cancel()
        partialTask?.cancel()
        failedHideTask?.cancel()
    }

    func start(configuration: Configuration) {
        guard coordinator == nil else { return }
        self.configuration = configuration
        let hotkey = GlobalHotkeyMonitor(keyCode: configuration.hotkeyKeyCode, modifiers: configuration.hotkeyModifiers)
        let workflows = configuration.workflows
        let recorder = MicDictationRecorder(
            model: configuration.modelName,
            language: configuration.language,
            deviceUID: configuration.deviceUID,
            streamingEnabled: configuration.streamingEnabled,
            workflowResolver: { @Sendable in
                await Self.resolveWorkflow(in: workflows)
            }
        )
        let inserter = PerAppTextInserter(
            paste: ClipboardPasteInserter(preDelayMs: configuration.pasteDelayMs)
        ) { @Sendable in
            let workflow = await Self.resolveWorkflow(in: workflows)
            return workflow?.insertion ?? .paste
        }
        let coord = DictationCoordinator(
            hotkey: hotkey,
            recorder: recorder,
            inserter: inserter,
            postProcessor: configuration.postProcessor,
            mode: configuration.mode
        ) { [weak self] state in
            await MainActor.run { self?.handleStateChange(state) }
        }
        coordinator = coord
        Task { await coord.startMonitoring() }
    }

    func stop() {
        guard let coord = coordinator else {
            state = .idle
            hideHUD()
            return
        }
        coordinator = nil
        failedHideTask?.cancel()
        failedHideTask = nil
        Task { await coord.stopMonitoring() }
        stopPartialStream()
        hideHUD()
        state = .idle
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

    var isRunning: Bool { coordinator != nil }

    private func handleStateChange(_ state: DictationCoordinator.State) {
        self.state = state
        appModel?.dictationState = state
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
                DictationView(model: model, controller: self, onStop: { model.stopDictationFromIntent() })
            }
        }
        guard let panel = hud else { return }
        panel.setFrame(preferredHUDFrame(), display: true, animate: false)
        panel.orderFrontRegardless()
    }

    private func resizeHUDForPartial() {
        guard let panel = hud else { return }
        let target = preferredHUDFrame()
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true, animate: false)
    }

    private func preferredHUDFrame() -> NSRect {
        let style = indicatorStyle
        let hasPartial = !partialText.isEmpty
        let size: NSSize
        switch style {
        case .overlay:
            size = NSSize(width: hasPartial ? 380 : 268, height: hasPartial ? 156 : 64)
        case .notch:
            size = NSSize(width: hasPartial ? 372 : 252, height: 36)
        case .minimal:
            size = NSSize(width: 44, height: 44)
        }
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        let frame = screen.visibleFrame
        let origin: NSPoint
        switch style {
        case .overlay:
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 100)
        case .notch:
            let topY = screen.frame.maxY - screen.visibleFrame.maxY > 30
                ? screen.frame.maxY - size.height - 4
                : screen.visibleFrame.maxY - size.height - 8
            origin = NSPoint(x: frame.midX - size.width / 2, y: topY)
        case .minimal:
            origin = NSPoint(x: frame.maxX - size.width - 24, y: frame.minY + 24)
        }
        return NSRect(origin: origin, size: size)
    }

    private func hideHUD() {
        stopLevelStream()
        hud?.orderOut(nil)
    }

    static func resolveWorkflow(in workflows: [String: [DictationWorkflow]]) async -> DictationWorkflow? {
        let bundleID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        guard let bundleID else { return nil }
        let url = await MainActor.run { BrowserURLResolver.shared.currentURL(for: bundleID) }
        return DictationWorkflowMap.select(in: workflows, for: bundleID, url: url)
    }
}
