import AppKit
import Foundation
import ParolaCore
import SwiftUI

@MainActor
final class LiveCaptionsController: ObservableObject {
    @Published var state: LiveCaptionsState = LiveCaptionsState()
    @Published var translateToEnglish: Bool = false

    private var panel: NSPanel?
    private var session: StreamingTranscriptionSession?
    private var consumer: Task<Void, Never>?
    private var lastOptions: TranscriptionOptions?

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
        TranscriptionOptions(
            model: options.model,
            language: options.language,
            task: translateToEnglish ? .translate : .transcribe,
            wordTimestamps: options.wordTimestamps,
            verbose: options.verbose,
            initialPrompt: options.initialPrompt,
            diarize: options.diarize,
            expectedSpeakers: options.expectedSpeakers
        )
    }

    func start(options: TranscriptionOptions) async {
        guard !state.isActive else { return }
        lastOptions = options
        state.reset()
        state.isActive = true

        let s = StreamingTranscriptionSession()
        session = s
        showWindow()

        consumer = Task { [weak self] in
            do {
                let events = try await s.start(options: options, downloadProgress: { _ in })
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
}
