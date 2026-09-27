import Foundation
import Testing
@testable import ParolaMCP

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("All tool names are unique")
    func uniqueNames() {
        let names = ToolRegistry.allToolNames()
        let unique = Set(names)
        #expect(names.count == unique.count, "duplicate tool names: \(names)")
    }

    @Test("Engine tool names are namespaced under parola_")
    func engineNaming() {
        for tool in EngineTool.allCases {
            #expect(tool.rawValue.hasPrefix("parola_"), "engine tool \(tool) missing prefix")
            #expect(tool.rawValue.hasPrefix("parola_app_") == false, "engine tool \(tool) collides with app namespace")
        }
    }

    @Test("Legacy app tool names stay under parola_app_ and out of tools/list")
    func legacyNaming() {
        let listed = Set(ToolRegistry.allToolNames())
        for name in LegacyAppTools.commands.keys {
            #expect(name.hasPrefix("parola_app_"), "legacy tool \(name) missing prefix")
            #expect(!listed.contains(name), "legacy tool \(name) is listed")
        }
    }

    @Test("Required props are declared properties")
    func requiredArePresent() {
        for tool in TypedToolRegistry.all {
            let propNames = Set(tool.properties.map(\.name))
            for r in tool.required {
                #expect(propNames.contains(r), "tool \(tool.name) marks '\(r)' as required but doesn't declare it")
            }
        }
    }

    @Test("Every tool produces a JSON-serialisable schema")
    func schemasSerialise() throws {
        let encoder = JSONEncoder()
        for tool in ToolRegistry.allTools() {
            let data = try encoder.encode(tool)
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(parsed?["name"] as? String == tool.name)
            #expect(parsed?["inputSchema"] is [String: Any], "tool \(tool.name) schema is not an object")
        }
    }

    @Test("Typed tool schema mirrors property declarations")
    func typedToolSchemaShape() throws {
        let export = try #require(TypedToolRegistry.byName["parola_export_transcript"])
        let data = try JSONEncoder().encode(export.mcpTool)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = parsed?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        let format = props?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "string")
        #expect((format?["enum"] as? [String])?.contains("srt") == true)
        #expect(schema?["required"] as? [String] == ["format"])
    }

    @Test("Bridge invocation forwards filtered args and command")
    func bridgeInvocationFiltersArgs() async throws {
        let tool = try #require(TypedToolRegistry.byName["parola_select_model"])
        let bridge = RecordingBridge()
        _ = try await tool.invoke(args: ["name": "openai_whisper-tiny", "ignored": 42], bridge: bridge)

        let call = try #require(await bridge.lastCall)
        #expect(call.cmd == "selectModel")
        let parsed = try JSONSerialization.jsonObject(with: call.argsJSON) as? [String: Any]
        #expect(parsed?["name"] as? String == "openai_whisper-tiny")
        #expect(parsed?["ignored"] == nil)
    }

    @Test("Tools without properties forward an empty object")
    func bridgeInvocationEmptyArgs() async throws {
        let tool = try #require(TypedToolRegistry.byName["parola_get_state"])
        let bridge = RecordingBridge()
        _ = try await tool.invoke(args: ["whatever": "should-be-dropped"], bridge: bridge)

        let call = try #require(await bridge.lastCall)
        #expect(call.cmd == "getState")
        let parsed = try JSONSerialization.jsonObject(with: call.argsJSON) as? [String: Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test("parola_open_app tool is exposed as an engine tool")
    func openAppToolRegistered() {
        #expect(ToolRegistry.allToolNames().contains("parola_open_app"))
    }

    @Test("default bundle id matches the app target's bundle id")
    func defaultBundleIDMatchesAppTarget() {
        #expect(AppLauncher.defaultBundleID == "app.parola.ParolaApp")
    }

    private func callTool(_ name: String, _ arguments: [String: Any], bridge: RecordingBridge) async throws -> [String: Any] {
        let server = MCPServer(libraryStore: scratchLibraryStore(), bridge: bridge)
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .int(1),
            method: "tools/call",
            params: AnyDecodable(["name": name, "arguments": arguments] as [String: Any])
        )
        let response = try #require(try await server.handle(request))
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool != true)
        let call = try #require(await bridge.lastCall)
        return try #require(try JSONSerialization.jsonObject(with: call.argsJSON) as? [String: Any])
    }

    @Test("Dictation legacy names forward to startDictation / stopDictation")
    func dictationToolsForwardCorrectly() async throws {
        let bridge = RecordingBridge()
        _ = try await callTool("parola_app_dictate", [:], bridge: bridge)
        #expect(await bridge.lastCall?.cmd == "startDictation")
        _ = try await callTool("parola_app_dictate_stop", [:], bridge: bridge)
        #expect(await bridge.lastCall?.cmd == "stopDictation")
    }

    @Test("A legacy name with a typed tool forwards what the typed tool does")
    func legacyNameRunsTheTypedTool() async throws {
        let bridge = RecordingBridge()
        let args = try await callTool(
            "parola_app_export_transcript", ["format": "srt", "includeTimestamps": true, "junk": 1], bridge: bridge
        )
        #expect(await bridge.lastCall?.cmd == "exportTranscript")
        #expect(args["format"] as? String == "srt")
        #expect(args["includeTimestamps"] as? Bool == true)
        #expect(args["junk"] == nil)
    }

    @Test("A legacy name without a typed tool sends its command with the caller's arguments")
    func legacyNameDispatchesItsCommand() async throws {
        let bridge = RecordingBridge()
        let args = try await callTool("parola_app_set_theme", ["theme": "dark"], bridge: bridge)
        #expect(await bridge.lastCall?.cmd == "setTheme")
        #expect(args["theme"] as? String == "dark")
    }

    @Test("A wait tool called without timeoutMs sends the default its description names")
    func waitToolSendsItsDefault() async throws {
        let bridge = RecordingBridge()
        let omitted = try await callTool("parola_wait_for_batch_job", ["jobID": "J"], bridge: bridge)
        #expect(omitted["timeoutMs"] as? Int == 30_000)
        let given = try await callTool("parola_wait_for_batch_job", ["jobID": "J", "timeoutMs": 1_234], bridge: bridge)
        #expect(given["timeoutMs"] as? Int == 1_234)
        let legacy = try await callTool("parola_app_wait_for_phase", ["phase": "ready"], bridge: bridge)
        #expect(legacy["timeoutMs"] as? Int == 10_000)
    }

    @Test("Every typed tool that takes timeoutMs sends the default its description names")
    func typedTimeoutDefaultsMatchTheirDescriptions() throws {
        let waits = TypedToolRegistry.all.filter { $0.argKeys.contains("timeoutMs") }
        #expect(!waits.isEmpty)
        for tool in waits {
            let fallback = try #require(tool.defaultTimeoutMs, "\(tool.name) has no default timeout")
            let described = tool.properties.first { $0.name == "timeoutMs" }?.description ?? ""
            #expect(described.contains("Defaults to \(fallback)."), "\(tool.name): \(described)")
        }
    }

    @Test("The client's socket outlasts the wait the app runs")
    func socketTimeoutCoversTheWait() {
        func timeout(_ cmd: String, _ args: String) -> TimeInterval {
            BridgeClient.socketTimeout(cmd: cmd, argsJSON: Data(args.utf8), floor: 35)
        }
        #expect(timeout("waitForBatchJob", #"{"timeoutMs":300000}"#) == 305)
        #expect(timeout("waitForPhase", #"{"timeoutMs":1000}"#) == 35)
        #expect(timeout("waitForBatchEmpty", "{}") == BridgeClient.longestWaitDefault + 5)
        #expect(timeout("ping", "{}") == 35)
    }

    @Test("BridgeClient pins a version constant for the wire protocol")
    func bridgeClientVersionPinned() {
        #expect(BridgeClient.clientVersion >= 1)
    }

    @Test("BridgeClient encodes valid JSON even with quotes and backslashes in cmd, token, args")
    func bridgeClientEscapesRequestJSON() throws {
        let client = BridgeClient()
        let data = client.encodeRequest(
            cmd: #"weird"cmd\name"#,
            argsJSON: Data(#"{"k":"v\"x"}"#.utf8),
            token: #"tok"en"#
        )
        let line = Data(data.prefix(while: { $0 != 0x0A }))
        let obj = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(obj["cmd"] as? String == #"weird"cmd\name"#)
        #expect(obj["auth"] as? String == #"tok"en"#)
        #expect((obj["args"] as? [String: Any])?["k"] as? String == #"v"x"#)
    }
}

private actor RecordingBridge: BridgeProtocol {
    struct Call: Sendable {
        let cmd: String
        let argsJSON: Data
    }
    private(set) var lastCall: Call?

    func call(_ cmd: String, argsJSON: Data) async throws -> String {
        lastCall = Call(cmd: cmd, argsJSON: argsJSON)
        return "{}"
    }
}
