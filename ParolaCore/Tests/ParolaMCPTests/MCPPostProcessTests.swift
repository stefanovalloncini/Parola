import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

private struct SilentBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String { "{}" }
}

@Suite("parola_transcribe post-processing")
struct MCPPostProcessTests {
    @Test("an Italian transcript comes back and is saved with the orthography fixed")
    func transcribeAppliesOrthography() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-orthography-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("lezione.wav")
        try Data("RIFFmcporthography".utf8).write(to: audio)

        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [
                TranscriptSegmentSeed(start: 0, end: 1, text: "Non so perchè."),
                TranscriptSegmentSeed(start: 3, end: 4, text: "Ne voglio un pò."),
            ],
            language: "it",
            modelName: "openai_whisper-tiny"
        )
        await registry.register(engineID: .whisperKit, capabilities: .whisperKitDefaults) { _ in
            MockTranscriber.make(response: response, clock: ContinuousClock())
        }
        let modelStore = ModelStore(modelsDirectory: root)
        let installed = modelStore.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: installed.appendingPathComponent("model.bin"))
        let library = LibraryStore(libraryURL: root.appending(path: "Library"), extraIndexer: nil)
        let server = MCPServer(
            session: TranscriptionSession(modelStore: modelStore, registry: registry),
            modelStore: modelStore,
            libraryStore: library,
            bridge: SilentBridge()
        )

        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(1),
            method: "tools/call",
            params: AnyDecodable([
                "name": "parola_transcribe",
                "arguments": ["path": audio.path, "model": "openai_whisper-tiny", "save": true] as [String: Any],
            ] as [String: Any])
        )
        let reply = try #require(try await server.handle(request))
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any]
        )
        let result = try #require(json["result"] as? [String: Any])
        let blocks = try #require(result["content"] as? [[String: Any]]).compactMap { $0["text"] as? String }

        #expect(blocks.first?.contains("Non so perché.") == true)
        #expect(blocks.first?.contains("Ne voglio un po'.") == true)
        let entry = try #require(await library.list().first)
        let saved = try await library.load(entry.id).document.transcript
        #expect(saved.segments.map(\.text) == ["Non so perché.", "Ne voglio un po'."])
    }
}
