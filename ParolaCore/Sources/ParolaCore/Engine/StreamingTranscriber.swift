import Foundation

public protocol StreamingTranscriber: Sendable {
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent>
    func stop() async
    /// Pauses or resumes the running take; a no-op before capture has launched.
    func setPaused(_ paused: Bool) async
    /// Ends the take without its final decode and deletes any audio it kept: nothing is saved and
    /// no `.finished` arrives.
    func cancel() async
    func currentModel() async -> String?
    /// Written from the capture thread as buffers arrive; a meter reads it when it draws.
    var levelMeter: LevelMeter { get }
    /// The take's on-disk audio, when the transcriber persists one: the in-flight file
    /// while recording, or the file a failure left behind.
    func recordingAudioURL() async -> URL?
    /// True once a stopped take's audio file had a write fail: the file ends early, the transcript doesn't.
    func audioWasCutShort() async -> Bool
}

public extension StreamingTranscriber {
    func recordingAudioURL() async -> URL? { nil }
    func audioWasCutShort() async -> Bool { false }
    var levelMeter: LevelMeter { LevelMeter() }
    func setPaused(_ paused: Bool) async {}
}

public enum StreamingTranscriberFactory {
    public static func make(
        modelStore: ModelStore = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        deviceUID: String? = nil,
        source: CaptionSource? = nil,
        persistAudio: Bool = false,
        waitsForModelOnStop: Bool = false
    ) -> any StreamingTranscriber {
        let source = source ?? .microphone(deviceUID: deviceUID)
        if let response = MockStreamingTranscriberRegistry.shared.resolve() {
            MockStreamingTranscriberRegistry.shared.recordMade(source: source)
            return MockStreamingTranscriber(response: response, clock: clock, source: source)
        }
        return StreamingTranscriptionSession(
            modelStore: modelStore, persistAudio: persistAudio, source: source, waitsForModelOnStop: waitsForModelOnStop
        )
    }

    /// Loads the model into the shared streaming cache so the next session start skips the load;
    /// it unloads again after `ModelResidency.idleTimeout` unless a session borrows it.
    /// Opportunistic: no-ops when a mock transcriber is installed or the model isn't downloaded,
    /// and swallows load failures.
    public static func prewarm(modelName: String, modelStore: ModelStore = .shared) async {
        guard MockStreamingTranscriberRegistry.shared.resolve() == nil else { return }
        guard modelStore.isInstalled(modelName) else { return }
        await StreamingModelCache.shared.warm(modelName, store: modelStore)
    }

    /// Unloads every streaming model no running session holds.
    public static func releaseIdleModels() async {
        await StreamingModelCache.shared.unloadUnleased()
    }

    /// Drops the model from the streaming cache, or, while running sessions hold it, once the last of them ends.
    public static func evict(modelName: String) async {
        await StreamingModelCache.shared.evictWhenReleased(modelName)
    }

    public static func residentModelNames() async -> [String] {
        await StreamingModelCache.shared.residentModelNames()
    }

    /// How long a model nothing holds stays loaded; a test sandbox shortens it to see the unload.
    public static func setIdleTimeout(_ timeout: Duration) async {
        await StreamingModelCache.shared.setIdleTimeout(timeout)
    }
}
