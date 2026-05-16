import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

@MainActor
final class TranscriptionCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloadingModel(name: String, progress: Double)
        case loadingModel(name: String)
        case transcribing(file: URL)
        case recording
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var livePartialText: String = ""

    var onComplete: (@MainActor (LibraryEntry) -> Void)?

    private let library: LibraryStore
    private let settings: UserSettings
    private let session = TranscriptionSession()
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingTask: Task<Void, Never>?
    private var recordingGeneration: Int = 0
    private var cancelledGeneration: Int = -1
    private var lastProgressPercent: Int = -1

    init(library: LibraryStore, settings: UserSettings) {
        self.library = library
        self.settings = settings
    }

    func reset() {
        phase = .idle
        liveSegments = []
        livePartialText = ""
    }

    func startFileTranscription(at sourceURL: URL) {
        Task {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-ios-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: sourceURL, to: copy)
                }.value
            } catch {
                phase = .failed(message: error.localizedDescription)
                return
            }
            runTranscription(audio: copy)
        }
    }

    func startFileTranscriptionFromTrustedCopy(at copy: URL) {
        runTranscription(audio: copy)
    }

    private func runTranscription(audio: URL) {
        Task {
            do {
                lastProgressPercent = -1
                phase = .loadingModel(name: settings.modelName)
                if !ModelStore.shared.isInstalled(settings.modelName) {
                    phase = .downloadingModel(name: settings.modelName, progress: 0)
                }
                phase = .transcribing(file: audio)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: audio),
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                let entry = try await library.add(transcript: result, audioSource: audio)
                phase = .idle
                onComplete?(entry)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func startRecording() {
        configureAudioSession()
        liveSegments = []
        livePartialText = ""
        recordingGeneration &+= 1
        let generation = recordingGeneration
        let session = StreamingTranscriptionSession()
        streamingSession = session
        phase = .recording

        streamingTask = Task {
            do {
                let events = try await session.start(
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                for await event in events {
                    handleStreamingEvent(event, generation: generation)
                }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard let session = streamingSession else { return }
        streamingSession = nil
        Task {
            await session.stop()
        }
    }

    func cancelRecording() {
        cancelledGeneration = recordingGeneration
        guard let session = streamingSession else { return }
        streamingSession = nil
        Task {
            await session.stop()
        }
    }

    func handleStreamingEvent(_ event: StreamingEvent, generation: Int = 0) {
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
            livePartialText = ""
            if generation == cancelledGeneration {
                phase = .idle
                return
            }
            Task {
                do {
                    let entry = try await library.add(transcript: final, audioSource: nil)
                    phase = .idle
                    onComplete?(entry)
                } catch {
                    phase = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    private var currentOptions: TranscriptionOptions {
        TranscriptionOptions(
            model: settings.modelName,
            language: settings.language,
            task: settings.translate ? .translate : .transcribe,
            wordTimestamps: settings.wordTimestamps,
            initialPrompt: settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
        )
    }

    private func makeDownloadProgressHandler() -> @Sendable (Double) -> Void {
        let modelName = settings.modelName
        return { [weak self] frac in
            let percent = Int(frac * 100)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard percent != self.lastProgressPercent else { return }
                self.lastProgressPercent = percent
                self.phase = .downloadingModel(name: modelName, progress: frac)
            }
        }
    }
}
