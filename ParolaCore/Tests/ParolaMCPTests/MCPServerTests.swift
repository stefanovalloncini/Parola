import Foundation
import Testing
import ParolaCore
@testable import ParolaMCP

@Suite("MCPServer JSON-RPC dispatch")
struct MCPServerTests {
    private func makeServer() -> MCPServer {
        MCPServer(libraryStore: scratchLibraryStore(), bridge: NullBridge())
    }

    private func makeServer(libraryStore: LibraryStore, bridge: any BridgeProtocol = NullBridge()) -> MCPServer {
        MCPServer(libraryStore: libraryStore, bridge: bridge)
    }

    private func tempLibrary() throws -> (LibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (LibraryStore(libraryURL: tmp, extraIndexer: nil), tmp)
    }

    private func toolCall(name: String, arguments: [String: Any] = [:], id: Int) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(id),
            method: "tools/call",
            params: AnyDecodable([
                "name": name,
                "arguments": arguments,
            ] as [String: Any])
        )
    }

    private func textBlock(from json: [String: Any]) throws -> String {
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let block = try #require(content.first)
        return try #require(block["text"] as? String)
    }

    @Test("initialize echoes a supported protocolVersion when the client asks for one")
    func initializeEchoesSupported() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(1),
            method: "initialize",
            params: AnyDecodable(["protocolVersion": "2025-03-26"])
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "parola")
    }

    @Test("initialize falls back to the preferred version when the client asks for an unsupported one")
    func initializeFallsBack() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(2),
            method: "initialize",
            params: AnyDecodable(["protocolVersion": "1999-01-01"])
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.preferredProtocolVersion)
    }

    @Test("initialize echoes the latest supported protocol version when requested")
    func initializeEchoesLatest() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(1),
            method: "initialize",
            params: AnyDecodable(["protocolVersion": "2025-06-18"])
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    @Test("initialize result carries a non-empty instructions string")
    func initializeCarriesInstructions() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(1),
            method: "initialize",
            params: AnyDecodable(["protocolVersion": "2025-06-18"])
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        let instructions = try #require(result["instructions"] as? String)
        #expect(!instructions.isEmpty)
    }

    @Test("ping returns an empty object result and no error")
    func pingReturnsEmptyResult() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(9),
            method: "ping",
            params: nil
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result.isEmpty)
        #expect(json["error"] == nil)
    }

    @Test("a tool-internal CancellationError is contained as isError, not thrown")
    func toolInternalCancellationContained() async throws {
        let server = MCPServer(libraryStore: scratchLibraryStore(), bridge: CancellingBridge())
        let response = try await server.handle(
            toolCall(name: "parola_select_model", arguments: ["name": "openai_whisper-tiny"], id: 200)
        )
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test("notifications/initialized returns no response")
    func notificationsInitializedHasNoResponse() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: nil,
            method: "notifications/initialized",
            params: nil
        )
        let response = try await server.handle(request)
        #expect(response == nil)
    }

    @Test("tools/list returns every tool in the registry")
    func toolsListEnumeratesEverything() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(3),
            method: "tools/list",
            params: nil
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == Set(ToolRegistry.allToolNames()))
    }

    @Test("unknown method returns methodNotFound")
    func unknownMethodReturnsMethodNotFound() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(4),
            method: "nonsense/method",
            params: nil
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? Int == RPCErrorCode.methodNotFound)
    }

    @Test("unknown notification (no id) gets no response, per JSON-RPC")
    func unknownNotificationHasNoResponse() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: nil,
            method: "notifications/cancelled",
            params: nil
        )
        let response = try await server.handle(request)
        #expect(response == nil)
    }

    @Test("tools/call with missing name returns invalidParams")
    func toolsCallMissingNameReturnsInvalidParams() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(5),
            method: "tools/call",
            params: AnyDecodable([String: Any]())
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? Int == RPCErrorCode.invalidParams)
    }

    @Test("tools/call against an unknown tool wraps the failure in isError content")
    func toolsCallUnknownToolWrappedInIsError() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(6),
            method: "tools/call",
            params: AnyDecodable([
                "name": "parola_nothing_here",
                "arguments": [:],
            ] as [String: Any])
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        let firstBlock = try #require(content.first)
        #expect(firstBlock["type"] as? String == "text")
        #expect((firstBlock["text"] as? String)?.contains("parola_nothing_here") == true)
    }

    @Test("tools/call wraps tool errors as isError content rather than an envelope error")
    func toolsCallToolErrorWrappedInContent() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(7),
            method: "tools/call",
            params: AnyDecodable([
                "name": "parola_transcribe",
                "arguments": [:],
            ] as [String: Any])
        )
        let response = try await server.handle(request)
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        let firstBlock = try #require(content.first)
        #expect(firstBlock["type"] as? String == "text")
        #expect((firstBlock["text"] as? String)?.contains("path") == true)
    }

    @Test("shutdown returns an empty object and flips the exit flag")
    func shutdownFlipsExitFlag() async throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(8),
            method: "shutdown",
            params: nil
        )
        let response = try await server.handle(request)
        #expect(response != nil)
        let exit = await server.shouldExit
        #expect(exit == true)
    }

    @Test("parola_list_models renders categories and known model ids")
    func listModelsRendersCategoriesAndIDs() async throws {
        let server = makeServer()
        let response = try await server.handle(toolCall(name: "parola_list_models", id: 100))
        let json = try encode(response)
        let text = try textBlock(from: json)
        #expect(text.contains("## "), "list_models output should include category headings")
        #expect(text.contains("openai_whisper-tiny"), "list_models output should include known model ids")
    }

    @Test("parola_list_models hides Parakeet v2 unless installed")
    func listModelsHidesUninstalledV2() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let server = MCPServer(modelStore: ModelStore(modelsDirectory: tmp), libraryStore: scratchLibraryStore(), bridge: NullBridge())
        let response = try await server.handle(toolCall(name: "parola_list_models", id: 102))
        let json = try encode(response)
        let text = try textBlock(from: json)
        #expect(!text.contains("nvidia_parakeet-tdt-0.6b-v2"), "v2 should not be listed when not installed")
        #expect(text.contains("nvidia_parakeet-tdt-0.6b-v3"), "v3 should be listed")
    }

    @Test("parola_list_engines lists every registered engine after bootstrap")
    func listEnginesAfterBootstrap() async throws {
        let server = makeServer()
        let response = try await server.handle(toolCall(name: "parola_list_engines", id: 101))
        let json = try encode(response)
        let text = try textBlock(from: json)
        #expect(text.contains("whisperkit"), "list_engines should include the bootstrapped whisperkit engine")
    }

    @Test("parola_list_recent on an empty library returns an empty content block")
    func listRecentEmptyLibrary() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let server = makeServer(libraryStore: store)

        let response = try await server.handle(toolCall(name: "parola_list_recent", id: 102))
        let json = try encode(response)
        let text = try textBlock(from: json)
        #expect(text.isEmpty)
    }

    @Test("parola_list_recent renders each entry on its own line and respects the limit")
    func listRecentRendersEntriesAndLimits() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for index in 0..<3 {
            _ = try await store.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi-\(index)")],
                    language: "en",
                    modelName: "tiny"
                ),
                audioSource: nil,
                title: "Entry \(index)"
            )
        }
        let server = makeServer(libraryStore: store)

        let allResponse = try await server.handle(toolCall(name: "parola_list_recent", id: 103))
        let allText = try textBlock(from: try encode(allResponse))
        #expect(allText.split(separator: "\n").count == 3)

        let limitedResponse = try await server.handle(
            toolCall(name: "parola_list_recent", arguments: ["limit": 2], id: 104)
        )
        let limitedText = try textBlock(from: try encode(limitedResponse))
        #expect(limitedText.split(separator: "\n").count == 2)
    }

    @Test("parola_search_library returns matching entries with score, time and snippet")
    func searchLibraryReturnsMatches() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 60, text: "opening remarks"),
                TranscriptSegment(id: 1, start: 74, end: 90, text: "sprint planning meeting")
            ],
            language: "en",
            modelName: "tiny"
        )
        let entry = try await store.add(transcript: transcript, audioSource: nil, title: "Planning notes")
        let server = makeServer(libraryStore: store)

        let response = try await server.handle(
            toolCall(name: "parola_search_library", arguments: ["query": "sprint"], id: 105)
        )
        let json = try encode(response)
        let text = try textBlock(from: json)
        #expect(text.contains(entry.id), "search output should include the matching entry id")
        #expect(text.contains("score"), "search output should include a score label per match")
        #expect(text.contains("at 01:14"), "a body hit should carry the time it is spoken")

        // "notes" is in the title alone, so there is no time to report.
        let titleOnly = try await server.handle(
            toolCall(name: "parola_search_library", arguments: ["query": "notes"], id: 106)
        )
        let titleOnlyText = try textBlock(from: try encode(titleOnly))
        #expect(titleOnlyText.contains(entry.id))
        #expect(!titleOnlyText.contains(", at "), "a title-only hit has no time to report")
    }

    @Test("library tools clamp a negative limit instead of trapping")
    func libraryToolsClampNegativeLimit() async throws {
        let (store, tmp) = try tempLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "sprint planning")],
                language: "en",
                modelName: "tiny"
            ),
            audioSource: nil,
            title: "Planning notes"
        )
        let server = makeServer(libraryStore: store)

        let recent = try await server.handle(
            toolCall(name: "parola_list_recent", arguments: ["limit": -1], id: 108)
        )
        #expect(try textBlock(from: try encode(recent)).isEmpty)

        let search = try await server.handle(
            toolCall(name: "parola_search_library", arguments: ["query": "sprint", "limit": -1], id: 109)
        )
        #expect(try textBlock(from: try encode(search)).isEmpty)
    }

    @Test("parola_app_ping forwards through the bridge and returns its response text")
    func appPingForwardsThroughBridge() async throws {
        let bridge = EchoBridge(reply: "{\"pong\":true}")
        let server = makeServer(libraryStore: try tempLibrary().0, bridge: bridge)

        let response = try await server.handle(toolCall(name: "parola_app_ping", id: 106))
        let json = try encode(response)
        let text = try textBlock(from: json)
        #expect(text == "{\"pong\":true}")
        let last = await bridge.lastCall
        #expect(last?.cmd == "ping")
    }

    @Test("parola_transcribe with a missing file wraps the failure as isError content")
    func transcribeMissingFileWrapped() async throws {
        let server = makeServer()
        let response = try await server.handle(
            toolCall(
                name: "parola_transcribe",
                arguments: ["path": "/tmp/parola-mcp-missing-\(UUID().uuidString).wav"],
                id: 107
            )
        )
        let json = try encode(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    private func encode(_ response: JSONRPCResponse?) throws -> [String: Any] {
        let response = try #require(response)
        let data = try JSONEncoder().encode(response)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor EchoBridge: BridgeProtocol {
    struct Call: Sendable {
        let cmd: String
        let argsJSON: Data
    }
    private(set) var lastCall: Call?
    private let reply: String
    init(reply: String) { self.reply = reply }
    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        lastCall = Call(cmd: cmd, argsJSON: argsJSON)
        return reply
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        "{}"
    }
}

private struct CancellingBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        throw CancellationError()
    }
}
