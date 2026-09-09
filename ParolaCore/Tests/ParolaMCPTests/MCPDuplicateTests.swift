import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

@Suite("parola_transcribe duplicates")
struct MCPDuplicateTests {

    private func tempLibrary() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-dupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp, extraIndexer: nil), tmp)
    }

    private func makeAudio(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("clip.wav")
        try Data("RIFFmcpduplicate".utf8).write(to: url)
        return url
    }

    private func toolCall(arguments: [String: Any], id: Int) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(id),
            method: "tools/call",
            params: AnyDecodable(["name": "parola_transcribe", "arguments": arguments] as [String: Any])
        )
    }

    private func encode(_ response: JSONRPCResponse?) throws -> [String: Any] {
        let response = try #require(response)
        let data = try JSONEncoder().encode(response)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func textBlocks(from json: [String: Any]) throws -> [String] {
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }
    }

    @Test("skip_duplicates returns the existing entry instead of transcribing")
    func skipDuplicatesShortCircuits() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audio = try makeAudio(in: tmp)
        _ = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "seeded")],
                language: "en",
                modelName: "openai_whisper-tiny"
            ),
            audioSource: audio,
            title: "Weekly sync"
        )
        let server = MCPServer(libraryStore: store, bridge: NullBridge())

        let response = try await server.handle(
            toolCall(arguments: ["path": audio.path, "skip_duplicates": true], id: 700)
        )
        let blocks = try textBlocks(from: try encode(response))
        #expect(blocks.count == 1)
        #expect(blocks[0].hasPrefix("Already in the library as Weekly sync (openai_whisper-tiny, "))
        #expect(blocks[0].hasSuffix("); skipping"))
    }

    @Test("the schema advertises skip_duplicates as an off-by-default boolean")
    func schemaCarriesSkipDuplicates() throws {
        let data = try JSONEncoder().encode(EngineTool.transcribe.mcpTool)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try #require(parsed["inputSchema"] as? [String: Any])
        let props = try #require(schema["properties"] as? [String: Any])
        let flag = try #require(props["skip_duplicates"] as? [String: Any])
        #expect(flag["type"] as? String == "boolean")
        #expect(flag["default"] as? Bool == false)
    }

    @Test("the request defaults skip_duplicates to off and reads it when given")
    func requestParsesSkipDuplicates() throws {
        #expect(try TranscribeRequest(args: ["path": "/tmp/a.wav"]).skipDuplicates == false)
        #expect(try TranscribeRequest(args: ["path": "/tmp/a.wav", "skip_duplicates": true]).skipDuplicates)
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        "{}"
    }
}
