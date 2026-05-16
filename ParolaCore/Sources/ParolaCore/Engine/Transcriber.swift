import Foundation

public protocol Transcriber: Sendable {
    static var engineID: EngineID { get }
    static var capabilities: EngineCapabilities { get }

    func load(model: String) async throws
    func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript
    func unload() async
    func loadedModelName() async -> String?
}
