import Foundation
import Testing
@testable import ParolaMCP

@Suite("MCPServer JSON-RPC dispatch")
struct MCPServerTests {
    private func makeServer() -> MCPServer {
        MCPServer(bridge: NullBridge())
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

    private func encode(_ response: JSONRPCResponse?) throws -> [String: Any] {
        let response = try #require(response)
        let data = try JSONEncoder().encode(response)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct NullBridge: BridgeProtocol {
    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        "{}"
    }
}
