import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

@Suite("MCP timing and library stats")
struct MCPStatsTests {
    private func tempLibrary() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp, extraIndexer: nil), tmp)
    }

    private func toolCall(name: String, id: Int) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(id),
            method: "tools/call",
            params: AnyDecodable(["name": name, "arguments": [String: Any]()] as [String: Any])
        )
    }

    private func encode(_ response: JSONRPCResponse) throws -> [String: Any] {
        let data = try JSONEncoder().encode(response)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func textBlocks(from json: [String: Any]) throws -> [String] {
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }
    }

    @Test("the transcribe result carries the two keys a caller parses")
    func timingNoteCarriesBothKeys() throws {
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 592, text: "hi")],
            language: "en",
            modelName: "tiny",
            durationSeconds: 592
        )
        transcript.transcriptionSeconds = 37
        let note = try #require(TranscribeReport.timingNote(for: transcript))

        #expect(note.contains("transcription_seconds: 37.00"))
        #expect(note.contains("speed_factor: 16.00"))
        #expect(note.hasPrefix("Transcribed in 37 s"))
    }

    @Test("a transcript that never ran through a file gets no timing block")
    func untimedTranscriptHasNoNote() {
        let transcript = Transcript(segments: [], language: "en", modelName: "tiny")
        #expect(TranscribeReport.timingNote(for: transcript) == nil)
    }

    @Test("parola_library_stats is registered under the engine namespace")
    func toolIsRegistered() {
        #expect(ToolRegistry.allToolNames().contains("parola_library_stats"))
    }

    @Test("parola_library_stats reports the library it is pointed at")
    func statsToolReportsTheLibrary() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 600, text: "una prova")],
            language: "it",
            modelName: "openai_whisper-tiny",
            durationSeconds: 600
        )
        transcript.transcriptionSeconds = 37.5
        _ = try await store.add(transcript: transcript, audioSource: nil, title: "Timed")
        let server = MCPServer(libraryStore: store, bridge: NullBridge())

        let response = try #require(try await server.handle(toolCall(name: "parola_library_stats", id: 201)))
        let text = try textBlocks(from: try encode(response)).joined(separator: "\n")

        #expect(text.contains("Transcripts: 1"))
        #expect(text.contains("Timed: 1 of 1"))
        #expect(text.contains("16× real time"))
    }

    @Test("an empty library answers in one line instead of a page of zeroes")
    func statsToolOnAnEmptyLibrary() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let server = MCPServer(libraryStore: store, bridge: NullBridge())

        let response = try #require(try await server.handle(toolCall(name: "parola_library_stats", id: 202)))
        let text = try textBlocks(from: try encode(response)).joined()

        #expect(text == "The library is empty.")
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String { "{}" }
}
