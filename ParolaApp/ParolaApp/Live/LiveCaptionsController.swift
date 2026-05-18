import AppKit
import Foundation
import ParolaCore
import SwiftUI

@MainActor
final class LiveCaptionsController: ObservableObject {
    @Published var state: LiveCaptionsState = LiveCaptionsState()
    @Published var translateToEnglish: Bool = false

    private var panel: NSPanel?
    private var presenterWindow: NSWindow?
    private var session: StreamingTranscriptionSession?
    private var consumer: Task<Void, Never>?
    private var lastOptions: TranscriptionOptions?

    deinit {
        consumer?.cancel()
    }

    var isPresenterOpen: Bool { presenterWindow != nil }

    var isActive: Bool { state.isActive }

    func toggle(options: TranscriptionOptions) async {
        if state.isActive {
            await stop()
        } else {
            await start(options: optionsWithTranslate(options))
        }
    }

    func setTranslate(_ enabled: Bool) async {
        guard translateToEnglish != enabled else { return }
        translateToEnglish = enabled
        guard let last = lastOptions, state.isActive else { return }
        await stop()
        await start(options: optionsWithTranslate(last))
    }

    private func optionsWithTranslate(_ options: TranscriptionOptions) -> TranscriptionOptions {
        var copy = options
        copy.task = translateToEnglish ? .translate : .transcribe
        return copy
    }

    func start(options: TranscriptionOptions) async {
        guard !state.isActive else { return }
        lastOptions = options
        state.reset()
        state.isActive = true
        state.isLoading = true

        let s = StreamingTranscriptionSession()
        session = s
        showWindow()

        consumer = Task { [weak self] in
            do {
                let events = try await s.start(options: options, downloadProgress: { _ in })
                self?.state.isLoading = false
                for await event in events {
                    self?.handle(event)
                }
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
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
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
