import Foundation

public protocol StreamingTranscriber: Sendable {
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent>
    func stop() async
    func currentModel() async -> String?
}

public enum StreamingTranscriberFactory {
    public static func make(
        modelStore: ModelStore = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        deviceUID: String? = nil
    ) -> any StreamingTranscriber {
        if let response = MockStreamingTranscriberRegistry.shared.resolve() {
            return MockStreamingTranscriber(response: response, clock: clock)
        }
        return StreamingTranscriptionSession(modelStore: modelStore, deviceUID: deviceUID)
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
