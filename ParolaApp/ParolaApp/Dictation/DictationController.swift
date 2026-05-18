import AppKit
import Foundation
import ParolaCore
import SwiftUI

@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationCoordinator.State = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var partialText: String = "" {
        didSet { if oldValue.isEmpty != partialText.isEmpty { resizeHUDForPartial() } }
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
        var workflows: [String: DictationWorkflow]
        var postProcessor: any TextPostProcessor
        var pasteDelayMs: Int = 0
    }

    private var coordinator: DictationCoordinator?
    private var hud: NSPanel?
    private var levelTask: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?

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
                let bundleID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                guard let bundleID else { return nil }
                return workflows[bundleID]
            }
        )
        let inserter = PerAppTextInserter(
            paste: ClipboardPasteInserter(preDelayMs: configuration.pasteDelayMs)
        ) { @Sendable in
            let bundleID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
            guard let bundleID, let workflow = workflows[bundleID] else { return .paste }
            return workflow.insertion ?? .paste
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
        switch state {
        case .idle:
            hideHUD()
        case .listening:
            showHUD(state: state)
            startLevelStream()
            startPartialStream()
        case .transcribing:
            showHUD(state: state)
            stopLevelStream()
        case .failed:
            showHUD(state: state)
            stopLevelStream()
            stopPartialStream()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if case .failed = self.state { self.hideHUD() }
            }
        }
    }

    private func startLevelStream() {
        guard let coord = coordinator else { return }
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            let stream = await coord.levels()
            for await level in stream {
                await MainActor.run {
                    guard let self else { return }
                    if abs(self.audioLevel - level) > 0.01 {
                        self.audioLevel = level
                    }
                }
            }
        }
    }

    private func stopLevelStream() {
        levelTask?.cancel()
        levelTask = nil
        audioLevel = 0
    }

    private func startPartialStream() {
        guard let coord = coordinator else { return }
        partialTask?.cancel()
        partialText = ""
        partialTask = Task { [weak self] in
            let stream = await coord.partials()
            for await text in stream {
                await MainActor.run {
                    guard let self else { return }
                    if self.partialText != text {
                        self.partialText = text
                    }
                }
            }
        }
    }

    private func stopPartialStream() {
        partialTask?.cancel()
        partialTask = nil
        partialText = ""
    }

    private func showHUD(state: DictationCoordinator.State) {
        guard let model = appModel else { return }
        if hud == nil {
            hud = DictationHUD.make { [weak self] in
                DictationView(state: self?.state ?? .idle, model: model)
            }
        }
        guard let panel = hud else { return }
        if let host = panel.contentView as? NSHostingView<DictationView> {
            host.rootView = DictationView(state: state, model: model)
        }
        panel.setFrame(preferredHUDFrame(), display: true, animate: false)
        panel.orderFrontRegardless()
    }

    private func resizeHUDForPartial() {
        guard let panel = hud else { return }
        let target = preferredHUDFrame()
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true, animate: true)
    }

    private func preferredHUDFrame() -> NSRect {
        let style = indicatorStyle
        let hasPartial = !partialText.isEmpty
        let size: NSSize
        switch style {
        case .overlay:
            size = NSSize(width: hasPartial ? 332 : 268, height: hasPartial ? 78 : 64)
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
}
