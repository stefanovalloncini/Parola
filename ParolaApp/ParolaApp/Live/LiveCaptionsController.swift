import AppKit
import Foundation
import ParolaCore
import SwiftUI

@MainActor
@Observable
final class LiveCaptionsController {
    @ObservationIgnored private static let timestampFormatter = ISO8601DateFormatter()
    private static let frameName = "LiveCaptions"

    var state: LiveCaptionsState = LiveCaptionsState() {
        didSet {
            if isActive != state.isActive { isActive = state.isActive }
            let history = !(state.history.isEmpty && state.partial.isEmpty)
            if hasHistory != history { hasHistory = history }
        }
    }
    /// Mirrors of `state` the Captions menu reads, so a streaming partial doesn't rebuild the command tree.
    private(set) var isActive: Bool = false
    private(set) var hasHistory: Bool = false
    private(set) var isPanelShown = false
    var translateToEnglish: Bool = false
    /// What the panel's chip names: the session's source, or the one picked since while captions are off.
    private(set) var source: CaptionSource = .microphone(deviceUID: nil)
    /// The privacy pane a failed session needs opened, when its reason is a missing permission.
    private(set) var failurePermission: RecordingSession.Permission?
    /// What the panel's permission pill does; the app routes Screen Recording to the same request as its Allow… button.
    @ObservationIgnored var openPermission: @MainActor (RecordingSession.Permission) -> Void = { $0.openSettings() }
    @ObservationIgnored var appName: (String) -> String = { CaptionAppList.installedName(forBundleID: $0) ?? $0 }

    private(set) var panel: NSPanel?
    @ObservationIgnored private var panelCloseObserver: (any NSObjectProtocol)?
    /// Off in tests, which drive a session without putting a floating panel on screen.
    private let showsPanel: Bool
    private var presenterWindow: NSWindow?
    private var session: (any StreamingTranscriber)?
    private var consumer: Task<Void, Never>?
    private(set) var lastOptions: TranscriptionOptions?
    /// What Retry starts with: the app's current model and language, so a fix made since the failure takes effect.
    @ObservationIgnored var optionsProvider: (@MainActor () -> TranscriptionOptions)?
    @ObservationIgnored var unavailableReason: (@MainActor () -> String?)?

    init(showsPanel: Bool = true) {
        self.showsPanel = showsPanel
    }

    isolated deinit {
        consumer?.cancel()
        if let panelCloseObserver { NotificationCenter.default.removeObserver(panelCloseObserver) }
    }

    var isPresenterOpen: Bool { presenterWindow != nil }

    func toggle(options: TranscriptionOptions, source: CaptionSource = .microphone(deviceUID: nil)) async {
        if state.isActive {
            await stop()
        } else {
            await start(options: optionsWithTranslate(options), source: source)
        }
    }

    /// A running session restarts on the new source and keeps its lines; a stopped or failed one just remembers it, so Retry uses it.
    func setSource(_ newSource: CaptionSource) async {
        guard newSource != source else { return }
        source = newSource
        guard state.isActive else { return }
        await restart {}
    }

    func setTranslate(_ enabled: Bool) async {
        guard translateToEnglish != enabled else { return }
        translateToEnglish = enabled
        guard state.isActive else { return }
        await restart {}
    }

    private func restart(changing change: () -> Void) async {
        await stop()
        // After the stop: it drains the lines still in flight into `state`, and start() resets it.
        let earlier = state
        change()
        guard !state.isActive, let current = lastOptions else { return }
        await start(options: optionsWithTranslate(current), source: source)
        // start() resets state; keep what was already captioned before the restart.
        state.continuing(after: earlier)
    }

    private func optionsWithTranslate(_ options: TranscriptionOptions) -> TranscriptionOptions {
        var copy = options
        copy.task = translateToEnglish ? .translate : .transcribe
        return copy
    }

    func start(options: TranscriptionOptions, source: CaptionSource = .microphone(deviceUID: nil)) async {
        guard !state.isActive else { return }
        lastOptions = options
        self.source = source
        failurePermission = nil
        state.reset()
        state.isActive = true
        state.isLoading = true

        let s = StreamingTranscriberFactory.make(source: source, purpose: .captions)
        session = s
        showWindow()

        consumer = Task { [weak self] in
            do {
                let events = try await s.start(options: options, speakerLabeler: nil, downloadProgress: { fraction in
                    Task { @MainActor in
                        if self?.state.isLoading == true { self?.state.downloadFraction = fraction }
                    }
                })
                self?.state.downloadFraction = nil
                self?.state.isLoading = false
                for await event in events {
                    self?.handle(event)
                    if case .failed = event { break }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.handleError(FailureText.message(for: error))
            }
        }
    }

    func stop() async {
        guard state.isActive else { return }
        state.isActive = false
        state.isLoading = false
        if let s = session {
            await s.stop()
        }
        session = nil
        consumer?.cancel()
        await consumer?.value
        consumer = nil
        state.partial = ""
        hideWindow()
    }

    private func handle(_ event: StreamingEvent) {
        state.apply(event)
        if case .failed(let text) = event {
            failurePermission = CaptionFailure.permission(for: text)
            state.error = CaptionFailure.message(for: text, appName: appName)
            if CaptionFailure.isCaptureEnd(text) { state.partial = "" }
            session = nil
            consumer?.cancel()
            consumer = nil
        }
    }

    private func handleError(_ message: String) {
        state.error = message
        state.isActive = false
        state.isLoading = false
        session = nil
    }

    /// A failed session stays on its panel with the reason; Retry starts it again with the current settings.
    func tryAgain() async {
        guard !state.isActive else { return }
        if let reason = unavailableReason?() {
            failurePermission = nil
            state.error = reason
            return
        }
        guard let options = optionsProvider?() ?? lastOptions else { return }
        let earlier = state
        await start(options: optionsWithTranslate(options), source: source)
        state.continuing(after: earlier)
    }

    func closeFailure() {
        guard !state.isActive else { return }
        hideWindow()
    }

    private func showWindow() {
        isPanelShown = true
        let panel = panel ?? makePanel()
        guard showsPanel else { return }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let made = LiveCaptionsWindow.make { [weak self] in
            if let self {
                LiveCaptionsView(controller: self)
            } else {
                EmptyView()
            }
        }
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: made, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPanelShown = false
                Task { await self.stop() }
            }
        }
        if showsPanel {
            if !made.setFrameUsingName(Self.frameName) { made.center() }
            made.setFrameAutosaveName(Self.frameName)
        }
        panel = made
        return made
    }

    private func hideWindow() {
        isPanelShown = false
        panel?.orderOut(nil)
    }

    func togglePresenter() {
        if presenterWindow != nil {
            closePresenter()
        } else {
            openPresenter()
        }
    }

    func saveCaptionsHistory() {
        guard hasHistory else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = Self.timestampFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "captions-\(stamp).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? state.historyText.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func openPresenter() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .mainMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: PresenterCaptionsView(controller: self) { [weak self] in
            self?.closePresenter()
        })
        presenterWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func closePresenter() {
        presenterWindow?.orderOut(nil)
        presenterWindow = nil
    }
}
