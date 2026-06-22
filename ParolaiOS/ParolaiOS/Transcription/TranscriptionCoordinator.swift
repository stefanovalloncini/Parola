import Foundation
import SwiftUI
import AVFoundation
import ParolaCore

@MainActor
@Observable
final class TranscriptionCoordinator {
    enum Phase: Equatable {
        case idle
        case downloadingModel(name: String, progress: Double)
        case loadingModel(name: String)
        case transcribing(file: URL)
        case recording
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var liveSegments: [TranscriptSegment] = []
    private(set) var livePartialText: String = ""

    @ObservationIgnored var onComplete: (@MainActor (LibraryEntry) -> Void)?
    @ObservationIgnored var postProcessor: (@MainActor (Transcript) -> Transcript)?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: UserSettings
    @ObservationIgnored private let session = TranscriptionSession()
    @ObservationIgnored private var streamingSession: StreamingTranscriptionSession?
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var recordingGeneration: Int = 0
    @ObservationIgnored private var cancelledGeneration: Int = -1
    @ObservationIgnored private var lastProgressPercent: Int = -1

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
                try await FileCopier.copy(from: sourceURL, to: copy)
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

    func reportFileImportFailure(_ error: Error) {
        phase = .failed(message: error.localizedDescription)
    }

    private func runTranscription(audio: URL) {
        transcribeTask?.cancel()
        transcribeTask = Task {
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
                try Task.checkCancellation()
                let processed = postProcessor?(result) ?? result
                let entry = try await library.add(transcript: processed, audioSource: audio)
                phase = .idle
                onComplete?(entry)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancelFileTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
    }

    func startRecording() {
        guard streamingSession == nil else { return }
        liveSegments = []
        livePartialText = ""
        recordingGeneration &+= 1
        let generation = recordingGeneration
        let session = StreamingTranscriptionSession(persistAudio: true)
        streamingSession = session
        phase = .recording

        streamingTask = Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                streamingSession = nil
                phase = .failed(message: "Microphone access is off. Turn it on in Settings to record.")
                return
            }
            do {
                let events = try await session.start(
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                for await event in events {
                    handleStreamingEvent(event, generation: generation)
                }
            } catch {
                streamingSession = nil
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard let session = streamingSession else { return }
        streamingSession = nil
        Task {
            await session.stop()
            deactivateAudioSession()
        }
    }

    func cancelRecording() {
        cancelledGeneration = recordingGeneration
        guard let session = streamingSession else { return }
        streamingSession = nil
        streamingTask?.cancel()
        streamingTask = nil
        Task {
            await session.stop()
            deactivateAudioSession()
        }
    }

    /// Cancels whatever is in flight — recording or file transcription. Safe to call when idle.
    func cancel() {
        cancelRecording()
        cancelFileTranscription()
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
            let processed = postProcessor?(final) ?? final
            Task { [generation] in
                do {
                    let entry = try await library.add(transcript: processed, audioSource: final.sourceURL)
                    guard generation != cancelledGeneration else {
                        phase = .idle
                        return
                    }
                    phase = .idle
                    onComplete?(entry)
                } catch {
                    phase = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
