import AppKit
import Foundation
import ParolaCore
import SwiftUI

@MainActor
@Observable
final class LiveCaptionsController {
    @ObservationIgnored private static let timestampFormatter = ISO8601DateFormatter()

    var state: LiveCaptionsState = LiveCaptionsState()
    var translateToEnglish: Bool = false

    private var panel: NSPanel?
    private var presenterWindow: NSWindow?
    private var session: (any StreamingTranscriber)?
    private var consumer: Task<Void, Never>?
    private var lastOptions: TranscriptionOptions?
    private var lastDeviceUID: String?

    isolated deinit {
        consumer?.cancel()
    }

    var isPresenterOpen: Bool { presenterWindow != nil }

    var isActive: Bool { state.isActive }

    func toggle(options: TranscriptionOptions, deviceUID: String? = nil) async {
        if state.isActive {
            await stop()
        } else {
            await start(options: optionsWithTranslate(options), deviceUID: deviceUID)
        }
    }

    func setTranslate(_ enabled: Bool) async {
        guard translateToEnglish != enabled else { return }
        translateToEnglish = enabled
        guard state.isActive else { return }
        await stop()
        guard !state.isActive, let current = lastOptions else { return }
        await start(options: optionsWithTranslate(current), deviceUID: lastDeviceUID)
    }

    private func optionsWithTranslate(_ options: TranscriptionOptions) -> TranscriptionOptions {
        var copy = options
        copy.task = translateToEnglish ? .translate : .transcribe
        return copy
    }

    func start(options: TranscriptionOptions, deviceUID: String? = nil) async {
        guard !state.isActive else { return }
        lastOptions = options
        lastDeviceUID = deviceUID
        state.reset()
        state.isActive = true
        state.isLoading = true

        let s = StreamingTranscriberFactory.make(deviceUID: deviceUID)
        session = s
        showWindow()

        consumer = Task { [weak self] in
            do {
                let events = try await s.start(options: options, speakerLabeler: nil, downloadProgress: { _ in })
                self?.state.isLoading = false
                for await event in events {
                    self?.handle(event)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.handleError(error.localizedDescription)
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
        hideWindow()
    }

    private func handle(_ event: StreamingEvent) {
        state.apply(event)
        if case .failed = event {
            hideWindow()
            session = nil
            consumer?.cancel()
            consumer = nil
        }
    }

    private func handleError(_ message: String) {
        state.error = message
        state.isActive = false
        state.isLoading = false
        hideWindow()
        session = nil
    }

    private func showWindow() {
        if panel == nil {
            panel = LiveCaptionsWindow.make { [weak self] in
                if let self {
                    LiveCaptionsView(controller: self)
                } else {
                    EmptyView()
                }
            }
        }
        panel?.center()
        panel?.orderFrontRegardless()
    }

    private func hideWindow() {
        panel?.orderOut(nil)
    }

    func togglePresenter() {
        if presenterWindow != nil {
            closePresenter()
        } else {
            openPresenter()
        }
    }

    var hasHistory: Bool {
        !(state.confirmedLines.isEmpty && state.partial.isEmpty)
    }

    func saveCaptionsHistory() {
        guard hasHistory else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = Self.timestampFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "captions-\(stamp).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var body = state.confirmedLines.joined(separator: "\n")
        if !state.partial.isEmpty {
            if !body.isEmpty { body += "\n" }
            body += state.partial
        }
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
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
