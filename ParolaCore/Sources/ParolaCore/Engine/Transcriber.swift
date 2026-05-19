import Foundation

public protocol Transcriber: Sendable {
    static var engineID: EngineID { get }
    static var capabilities: EngineCapabilities { get }

    func load(model: String) async throws
    func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript

    /// Streaming variant. Default forwards to the non-streaming overload.
    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?
    ) async throws -> Transcript

    func unload() async
    func loadedModelName() async -> String?

    /// Aborts any in-flight `transcribe` call. Engines that can interrupt their underlying
    /// pipeline implement this; the default is a no-op since `Task.cancel()` already covers
    /// engines whose work is cooperative.
    func cancelInFlight() async
}

public extension Transcriber {
    func cancelInFlight() async {}

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?
    ) async throws -> Transcript {
        try await transcribe(url: url, options: options)
    }
}
