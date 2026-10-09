import Foundation

/// Coarse phase of a transcribe call: `preparingAudio` covers the engine's internal decode and
/// chunking before inference, `transcribing` starts with its first output.
public enum TranscribeStage: Sendable {
    case preparingAudio
    case transcribing
}

/// Observation hooks for a transcribe run. Engines call whichever hooks they can honor;
/// a default-initialized value observes nothing. `onProgress` reports the latest
/// transcribed second of the source audio.
public struct TranscribeHandlers: Sendable {
    public var onPartial: (@Sendable (String) -> Void)?
    public var onProgress: (@Sendable (Double) -> Void)?
    public var onStage: (@Sendable (TranscribeStage) -> Void)?
    /// Window loudness from an engine that already decoded the audio, so the energy pass skips its sweep.
    var onWindowEnergies: (@Sendable ([Double]) -> Void)?

    public init(
        onPartial: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStage: (@Sendable (TranscribeStage) -> Void)? = nil
    ) {
        self.onPartial = onPartial
        self.onProgress = onProgress
        self.onStage = onStage
    }

    public var observesNothing: Bool {
        onPartial == nil && onProgress == nil && onStage == nil
    }
}

public protocol Transcriber: Sendable {
    static var engineID: EngineID { get }
    static var capabilities: EngineCapabilities { get }

    func load(model: String) async throws
    func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript

    func unload() async
    func loadedModelName() async -> String?

    /// Aborts any in-flight `transcribe` call. Engines that can interrupt their underlying
    /// pipeline implement this; the default is a no-op since `Task.cancel()` already covers
    /// engines whose work is cooperative.
    func cancelInFlight() async
}

public extension Transcriber {
    func cancelInFlight() async {}

    func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
        try await transcribe(url: url, options: options, handlers: TranscribeHandlers())
    }
}
