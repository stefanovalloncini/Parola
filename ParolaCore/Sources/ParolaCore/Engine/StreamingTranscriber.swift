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
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> any StreamingTranscriber {
        if let response = await MockStreamingTranscriberRegistry.shared.resolve() {
            return MockStreamingTranscriber(response: response, clock: clock)
        }
        return StreamingTranscriptionSession(modelStore: modelStore)
    }
}
