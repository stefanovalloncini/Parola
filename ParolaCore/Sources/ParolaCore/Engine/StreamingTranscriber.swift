import Foundation

public protocol StreamingTranscriber: Sendable {
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent>
    func stop() async
    /// Ends the take without its final decode and deletes any audio it kept: nothing is saved and
    /// no `.finished` arrives.
    func cancel() async
    func currentModel() async -> String?
    /// The take's on-disk audio, when the transcriber persists one: the in-flight file
    /// while recording, or the file a failure left behind.
    func recordingAudioURL() async -> URL?
}

public extension StreamingTranscriber {
    func recordingAudioURL() async -> URL? { nil }
}

public enum StreamingTranscriberFactory {
    public static func make(
        modelStore: ModelStore = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        deviceUID: String? = nil,
        persistAudio: Bool = false
    ) -> any StreamingTranscriber {
        if let response = MockStreamingTranscriberRegistry.shared.resolve() {
            return MockStreamingTranscriber(response: response, clock: clock)
        }
        return StreamingTranscriptionSession(modelStore: modelStore, persistAudio: persistAudio, deviceUID: deviceUID)
    }

    /// Loads the model into the shared streaming cache so the next session start skips the load.
    /// Opportunistic: no-ops when a mock transcriber is installed or the model isn't downloaded,
    /// and swallows load failures.
    public static func prewarm(modelName: String, modelStore: ModelStore = .shared) async {
        guard MockStreamingTranscriberRegistry.shared.resolve() == nil else { return }
        guard modelStore.isInstalled(modelName) else { return }
        _ = try? await StreamingModelCache.shared.borrow(modelName, store: modelStore)
    }
}
