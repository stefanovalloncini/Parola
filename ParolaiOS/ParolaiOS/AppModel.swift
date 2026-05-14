import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloadingModel(name: String, progress: Double)
        case loadingModel(name: String)
        case transcribing(file: URL)
        case recording
        case ready
        case failed(message: String)
    }

    @Published var phase: Phase = .idle
    @Published var transcript: Transcript?
    @Published var currentSegmentID: TranscriptSegment.ID?

    @Published var selectedModel: String = "openai_whisper-tiny"
    @Published var selectedLanguage: String?
    @Published var translate: Bool = false
    @Published var wordTimestamps: Bool = false
    @Published var initialPrompt: String = ""

    @Published var liveSegments: [TranscriptSegment] = []
    @Published var livePartialText: String = ""

    @Published var availableModels: [ModelInfo] = []

    private let session = TranscriptionSession()
    private let store = ModelStore.shared
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingTask: Task<Void, Never>?

    init() {
        refreshModelList()
    }

    // MARK: - Model list

    func refreshModelList() {
        availableModels = store.catalog()
        if !availableModels.contains(where: { $0.name == selectedModel }) {
            selectedModel = availableModels.first?.name ?? "openai_whisper-tiny"
        }
    }

    func deleteModel(_ name: String) {
        try? store.delete(variant: name)
        refreshModelList()
    }

    // MARK: - File transcription

    func openFile(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            phase = .failed(message: "Couldn't access \(url.lastPathComponent).")
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-ios-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            url.stopAccessingSecurityScopedResource()
        } catch {
            url.stopAccessingSecurityScopedResource()
            phase = .failed(message: error.localizedDescription)
            return
        }

        Task {
            do {
                phase = .loadingModel(name: selectedModel)
                if !store.isInstalled(selectedModel) {
                    phase = .downloadingModel(name: selectedModel, progress: 0)
                }
                phase = .transcribing(file: destination)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: destination),
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                transcript = result
                phase = .ready
                refreshModelList()
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Live recording

    func toggleRecording() {
        if streamingSession == nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        configureAudioSession()
        liveSegments = []
        livePartialText = ""
        let session = StreamingTranscriptionSession()
        streamingSession = session
        phase = .recording

        streamingTask = Task { @MainActor in
            do {
                let events = try await session.start(
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                phase = .recording
                for await event in events {
                    handleEvent(event)
                }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard let session = streamingSession else { return }
        Task { @MainActor in
            await session.stop()
            streamingSession = nil
            streamingTask?.cancel()
            streamingTask = nil
        }
    }

    private func handleEvent(_ event: StreamingEvent) {
        switch event {
        case .partial(let text):
            if livePartialText != text { livePartialText = text }
        case .confirmed(let segment):
            liveSegments.append(segment)
            if !livePartialText.isEmpty { livePartialText = "" }
        case .voiceActivity:
            break
        case .warning:
            break
        case .failed(let msg):
            phase = .failed(message: msg)
        case .finished(let final):
            transcript = final
            livePartialText = ""
            phase = .ready
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [])
        try? session.setActive(true)
    }

    // MARK: - Options helpers

    private var currentOptions: TranscriptionOptions {
        TranscriptionOptions(
            model: selectedModel,
            language: selectedLanguage,
            task: translate ? .translate : .transcribe,
            wordTimestamps: wordTimestamps,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt
        )
    }

    private func makeDownloadProgressHandler() -> @Sendable (Double) -> Void {
        { [weak self] frac in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phase = .downloadingModel(name: self.selectedModel, progress: frac)
            }
        }
    }
}
