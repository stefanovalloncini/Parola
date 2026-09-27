import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

@Suite("MCP library tools follow the app's writes")
struct MCPLibraryFreshnessTests {
    private struct Library {
        let url: URL
        /// The app's store: the one that writes the library and its index.
        let app: LibraryStore
        let server: MCPServer
    }

    private func makeLibrary() throws -> Library {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Library(
            url: url,
            app: LibraryStore(libraryURL: url, extraIndexer: nil),
            server: MCPServer(
                libraryStore: LibraryStore(libraryURL: url, extraIndexer: nil, role: .reader),
                bridge: NullBridge()
            )
        )
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 60, text: text)],
            language: "en",
            modelName: "openai_whisper-tiny",
            durationSeconds: 60
        )
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(Int.random(in: 1...1_000_000)),
            method: "tools/call",
            params: AnyDecodable(["name": name, "arguments": arguments] as [String: Any])
        )
        let response = try #require(try await server.handle(request))
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @Test("an entry the app saves after the server has read the library shows in the next call")
    func appSaveShows() async throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.url) }
        _ = try await library.app.add(transcript: transcript("alpha minutes"), audioSource: nil, title: "Kickoff")
        await library.app.flush()
        #expect(try await call(library.server, "parola_list_recent") == "- Kickoff")
        #expect(try await call(library.server, "parola_search_library", ["query": "zzyzxmarker"]).isEmpty)

        let saved = try await library.app.add(
            transcript: transcript("zzyzxmarker minutes"), audioSource: nil, title: "Retro"
        )

        // Two entries saved in one second tie on their date, so the order between them is not the point.
        let recent = try await call(library.server, "parola_list_recent").split(separator: "\n")
        #expect(Set(recent) == ["- Retro", "- Kickoff"])
        #expect(try await call(library.server, "parola_search_library", ["query": "zzyzxmarker"]).contains(saved.id))
        #expect(try await call(library.server, "parola_library_stats").contains("Transcripts: 2"))
    }

    @Test("a rename and a delete in the app reach the server's list, stats and search")
    func appRenameAndDeleteShow() async throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.url) }
        let kept = try await library.app.add(transcript: transcript("alpha minutes"), audioSource: nil, title: "Kickoff")
        let doomed = try await library.app.add(transcript: transcript("zzyzxmarker minutes"), audioSource: nil, title: "Retro")
        await library.app.flush()
        #expect(try await call(library.server, "parola_search_library", ["query": "minutes"]).contains(doomed.id))
        #expect(try await call(library.server, "parola_library_stats").contains("Transcripts: 2"))

        try await library.app.renameEntry(kept.id, to: "Quarterly qqxwtitle")
        try await library.app.delete(doomed.id)
        await library.app.flush()

        #expect(try await call(library.server, "parola_list_recent") == "- Quarterly qqxwtitle")
        #expect(try await call(library.server, "parola_library_stats").contains("Transcripts: 1"))
        #expect(try await call(library.server, "parola_search_library", ["query": "zzyzxmarker"]).isEmpty)
        #expect(try await call(library.server, "parola_search_library", ["query": "qqxwtitle"]).contains(kept.id))
    }

    @Test("a file the app imported after the server started is reported as a duplicate")
    func appImportIsADuplicate() async throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.url) }
        let audio = library.url.deletingLastPathComponent()
            .appendingPathComponent("parola-mcp-fresh-\(UUID().uuidString).wav")
        try Data("RIFFfreshness".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        #expect(try await call(library.server, "parola_list_recent").isEmpty)

        _ = try await library.app.add(transcript: transcript("seeded"), audioSource: audio, title: "Weekly sync")

        let text = try await call(library.server, "parola_transcribe", ["path": audio.path, "skip_duplicates": true])
        #expect(text.hasPrefix("Already in the library as Weekly sync"))
    }

    @Test("with nothing changed, a call keeps what the server already read")
    func quietLibraryKeepsCaches() async throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.url) }
        _ = try await library.app.add(transcript: transcript("alpha minutes"), audioSource: nil, title: "Kickoff")
        await library.app.flush()
        let reader = LibraryStore(libraryURL: library.url, extraIndexer: nil, role: .reader)
        _ = await reader.reloadIfChangedElsewhere()
        _ = await reader.list()
        _ = await reader.search("alpha")

        #expect(await !reader.reloadIfChangedElsewhere())
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        "{}"
    }
}
