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
        case finishing
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var liveSegments: [TranscriptSegment] = []
    private(set) var livePartialText: String = ""

    @ObservationIgnored var onComplete: (@MainActor (LibraryEntry) -> Void)?
    /// Read when a result lands, so rules edited mid-run still apply; the pass itself runs off the main actor.
    @ObservationIgnored var postProcessor: (@MainActor () -> TranscriptPostProcessor)?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: UserSettings
    @ObservationIgnored var makeStreamingSession: () -> any StreamingTranscriber = {
        StreamingTranscriptionSession(persistAudio: true)
    }
    @ObservationIgnored var requestMicrophonePermission: () async -> Bool = {
        await AVAudioApplication.requestRecordPermission()
    }
    @ObservationIgnored var onSalvage: (@MainActor () -> Void)?
    @ObservationIgnored private let session = TranscriptionSession(idleTimeout: ModelResidencyPolicy.idleTimeoutSeconds)
    @ObservationIgnored private var streamingSession: (any StreamingTranscriber)?
    @ObservationIgnored private var finishingSession: (any StreamingTranscriber)?
    @ObservationIgnored private(set) var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var transcribeGeneration = 0
    @ObservationIgnored private var recordingGeneration: Int = 0
    @ObservationIgnored private var cancelledGeneration: Int = -1

    init(library: LibraryStore, settings: UserSettings) {
        self.library = library
        self.settings = settings
        Task { await StreamingTranscriberFactory.setIdleTimeout(ModelResidencyPolicy.idleTimeout) }
    }

    func releaseModelsInBackground() async {
        guard ModelResidencyPolicy.releasesOnBackground(phase: phase) else { return }
        await session.unloadModel()
        await StreamingTranscriberFactory.releaseIdleModels()
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
            let copy = Self.importCopyURL(for: sourceURL)
            do {
                try await FileCopier.copy(from: sourceURL, to: copy)
            } catch {
                Self.removeImportCopy(copy)
                phase = .failed(message: FailureText.message(for: error))
                return
            }
            runTranscription(audio: copy)
        }
    }

    /// `copy` comes from `importCopyURL(for:)`; the run removes it once the entry holds its own.
    func startFileTranscriptionFromTrustedCopy(at copy: URL) {
        runTranscription(audio: copy)
    }

    private static let importFolderPrefix = "parola-import-"

    /// A folder of its own per import, so the copy keeps the file's name: the entry is titled with it.
    static func importCopyURL(for source: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(importFolderPrefix)\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
    }

    static func removeImportCopy(_ copy: URL) {
        let folder = copy.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(importFolderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func reportFileImportFailure(_ error: Error) {
        phase = .failed(message: FailureText.message(for: error))
    }

    private func runTranscription(audio: URL) {
        transcribeTask?.cancel()
        transcribeGeneration += 1
        let generation = transcribeGeneration
        transcribeTask = Task {
            defer { Self.removeImportCopy(audio) }
            do {
                phase = .loadingModel(name: settings.modelName)
                if !ModelStore.shared.isInstalled(settings.modelName) {
                    phase = .downloadingModel(name: settings.modelName, progress: 0)
                }
                phase = .transcribing(file: audio)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: audio),
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler(resumingTo: { .transcribing(file: audio) })
                )
                try Task.checkCancellation()
                let entry = try await saveFileResult(result, audio: audio)
                phase = .idle
                onComplete?(entry)
            } catch is CancellationError {
                if generation == transcribeGeneration { phase = .idle }
            } catch {
                if generation == transcribeGeneration { phase = .failed(message: FailureText.message(for: error)) }
            }
        }
    }

    func saveFileResult(_ result: Transcript, audio: URL) async throws -> LibraryEntry {
        let processed = await postProcessed(result)
        // The rules pass runs off the main actor, so a Cancel can land in it; past here the entry is written.
        try Task.checkCancellation()
        return try await library.add(transcript: processed, audioSource: audio, source: .file)
    }

    func postProcessed(_ transcript: Transcript) async -> Transcript {
        guard let postProcessor else { return transcript }
        return await postProcessor().applyOffActor(transcript)
    }

    func cancelFileTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
    }

    func startRecording() {
        guard streamingSession == nil, finishingSession == nil else { return }
        liveSegments = []
        livePartialText = ""
        recordingGeneration &+= 1
        let generation = recordingGeneration
        let session = makeStreamingSession()
        streamingSession = session
        phase = .recording

        streamingTask = Task {
            guard await requestMicrophonePermission() else {
                streamingSession = nil
                phase = .failed(message: "Microphone access is off. Turn it on in Settings to record.")
                return
            }
            do {
                let events = try await session.start(
                    options: currentOptions,
                    speakerLabeler: nil,
                    downloadProgress: makeDownloadProgressHandler(resumingTo: {
                        self.finishingSession == nil ? .recording : .finishing
                    })
                )
                for await event in events {
                    handleStreamingEvent(event, generation: generation)
                }
                if generation == recordingGeneration {
                    finishingSession = nil
                    deactivateAudioSessionIfIdle()
                }
            } catch {
                guard generation == recordingGeneration else { return }
                streamingSession = nil
                finishingSession = nil
                if generation == cancelledGeneration {
                    if let audio = await session.recordingAudioURL() { try? FileManager.default.removeItem(at: audio) }
                    return
                }
                let message = await landInterruptedTake(from: session, reason: FailureText.message(for: error))
                guard generation == recordingGeneration else { return }
                deactivateAudioSessionIfIdle()
                phase = .failed(message: message)
            }
        }
    }

    var isRecordingSessionActive: Bool { streamingSession != nil }

    func stopRecording() {
        guard let session = streamingSession else { return }
        streamingSession = nil
        finishingSession = session
        phase = .finishing
        Task { await session.stop() }
    }

    func cancelRecording() {
        cancelledGeneration = recordingGeneration
        guard let session = streamingSession ?? finishingSession else { return }
        streamingSession = nil
        finishingSession = nil
        streamingTask?.cancel()
        streamingTask = nil
        let generation = recordingGeneration
        Task {
            await session.cancel()
            if generation == recordingGeneration { deactivateAudioSessionIfIdle() }
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
            restoreRecordingPhaseIfDownloadStuck()
            if livePartialText != text { livePartialText = text }
        case .confirmed(let segment):
            restoreRecordingPhaseIfDownloadStuck()
            liveSegments.append(segment)
            if !livePartialText.isEmpty { livePartialText = "" }
        case .voiceActivity:
            restoreRecordingPhaseIfDownloadStuck()
        case .warning:
            break
        case .failed(let msg):
            // The session tore itself down before emitting .failed; keeping the reference
            // would leave startRecording's guard tripped and the Record button dead.
            streamingSession = nil
            finishingSession = nil
            streamingTask = nil
            deactivateAudioSessionIfIdle()
            phase = .failed(message: msg)
        case .finished(let final):
            livePartialText = ""
            if generation == cancelledGeneration {
                if let audio = final.sourceURL { try? FileManager.default.removeItem(at: audio) }
                if generation == recordingGeneration { phase = .idle }
                return
            }
            Task { [generation] in
                let processed = await postProcessed(final)
                // A take stopped before capture came up (say, during the first model download) has nothing to keep.
                guard !processed.segments.isEmpty || final.sourceURL != nil else {
                    if generation == recordingGeneration { phase = .idle }
                    return
                }
                do {
                    let entry = try await library.add(
                        transcript: processed, audioSource: final.sourceURL, source: .microphone
                    )
                    if let audio = final.sourceURL { try? FileManager.default.removeItem(at: audio) }
                    guard generation != cancelledGeneration else {
                        if generation == recordingGeneration { phase = .idle }
                        return
                    }
                    if generation == recordingGeneration { phase = .idle }
                    onComplete?(entry)
                } catch {
                    if generation == recordingGeneration { phase = .failed(message: FailureText.message(for: error)) }
                }
            }
        }
    }

    /// What a take that captured audio before its model failed to load keeps: an entry with the audio and no words.
    private func landInterruptedTake(from session: any StreamingTranscriber, reason: String) async -> String {
        guard let audio = await session.recordingAudioURL() else { return reason }
        let bytes = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > RecordingScratch.emptyTakeBytes else {
            try? FileManager.default.removeItem(at: audio)
            return reason
        }
        let transcript = await StreamingTranscriptionSession.finishedTake(
            segments: [], options: currentOptions, modelName: "", audioURL: audio
        )
        do {
            _ = try await library.add(transcript: transcript, audioSource: audio, source: .microphone)
        } catch {
            return reason
        }
        try? FileManager.default.removeItem(at: audio)
        onSalvage?()
        return reason + " The recording was saved to your library."
    }

    /// A take started since owns the audio session; only an idle coordinator lets it go.
    private func deactivateAudioSessionIfIdle() {
        guard streamingSession == nil, finishingSession == nil else { return }
        deactivateAudioSession()
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

    // A live streaming event means the mic is up even if the download never reported 1.0.
    private func restoreRecordingPhaseIfDownloadStuck() {
        if case .downloadingModel = phase { phase = finishingSession == nil ? .recording : .finishing }
    }

    /// `ModelStore.download` calls the handler once per whole percent, never going backwards.
    func makeDownloadProgressHandler(resumingTo resume: @escaping @MainActor () -> Phase) -> @Sendable (Double) -> Void {
        let modelName = settings.modelName
        return { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if fraction >= 1 {
                    if case .downloadingModel = self.phase { self.phase = resume() }
                    return
                }
                guard self.finishingSession == nil else { return }
                self.phase = .downloadingModel(name: modelName, progress: fraction)
            }
        }
    }
}
