import Foundation

/// Top-level orchestrator. Owns a WhisperKit transcriber, manages model loading,
/// and emits transcription events.
///
/// Idle-unload: after `idleTimeout` seconds of inactivity, the model is released
/// to free memory; the next transcribe call transparently reloads.
public actor TranscriptionSession {
    public let modelStore: ModelStore
    public var idleTimeout: TimeInterval

    private let transcriber: WhisperKitTranscriber
    private let diarizer = DiarizationService()
    private var idleTask: Task<Void, Never>?

    public init(modelStore: ModelStore = .shared, idleTimeout: TimeInterval = 60) {
        self.modelStore = modelStore
        self.idleTimeout = idleTimeout
        self.transcriber = WhisperKitTranscriber(modelStore: modelStore)
    }

    /// Transcribes from an AudioSource. Downloads the requested model on demand.
    /// - Parameters:
    ///   - source: anything conforming to AudioSource (file, mic, system audio)
    ///   - options: language / task / model selection
    ///   - downloadProgress: optional 0–1 callback for model download progress
    /// - Returns: the completed Transcript
    public func transcribe(
        source: any AudioSource,
        options: TranscriptionOptions,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        let modelName = options.model ?? "openai_whisper-tiny"
        try Task.checkCancellation()
        if !modelStore.isInstalled(modelName) {
            _ = try await modelStore.download(variant: modelName, progress: downloadProgress)
        }
        try Task.checkCancellation()
        cancelIdleTimer()
        try await transcriber.load(model: modelName)
        try Task.checkCancellation()
        let audioURL = try await source.prepare()
        try Task.checkCancellation()
        var transcript = try await transcriber.transcribe(url: audioURL, options: options)
        if options.diarize {
            try Task.checkCancellation()
            transcript = try await diarizer.diarize(
                transcript: transcript,
                audioURL: audioURL,
                numberOfSpeakers: options.expectedSpeakers
            )
        }
        scheduleIdleUnload()
        return transcript
    }

    public func unloadModel() async {
        cancelIdleTimer()
        await transcriber.unload()
        await diarizer.unload()
    }

    public func currentModel() async -> String? {
        await transcriber.loadedModelName()
    }

    private func scheduleIdleUnload() {
        cancelIdleTimer()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.transcriber.unload()
        }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }
}
