import Foundation
import Testing
@testable import ParolaMCP

@Suite("TypedToolRegistry")
struct TypedToolRegistryTests {
    private static let expectedTypedTools: [(String, String)] = [
        ("parola_select_model",            "selectModel"),
        ("parola_transcribe_file",         "transcribeFile"),
        ("parola_transcribe_youtube",      "transcribeYouTube"),
        ("parola_load_entry",              "loadEntry"),
        ("parola_search_library",          "search"),
        ("parola_start_batch",             "startBatch"),
        ("parola_add_batch_files",         "addBatchFiles"),
        ("parola_run_prompt",              "runPrompt"),
        ("parola_get_state",               "getState"),
        ("parola_get_state_revision",      "getStateRevision"),
        ("parola_get_accessibility_tree",  "getAccessibilityTree"),
        ("parola_screenshot",              "screenshot"),
        ("parola_wait_for_phase",          "waitForPhase"),
        ("parola_wait_for_batch_job",      "waitForBatchJob"),
        ("parola_wait_for_revision",       "waitForRevision"),
        ("parola_start_dictation",         "startDictation"),
        ("parola_stop_dictation",          "stopDictation"),
        ("parola_export_transcript",       "exportTranscript"),
        ("parola_open_settings",           "openSettings"),
        ("parola_reset_test_state",        "resetTestState"),
    ]

    @Test("All 20 typed tools from the v7-C spec are registered with the right bridge command")
    func twentyTypedToolsRegistered() {
        #expect(TypedToolRegistry.all.count == 20)
        for (toolName, bridgeCmd) in Self.expectedTypedTools {
            let tool = TypedToolRegistry.byName[toolName]
            #expect(tool != nil, "typed tool \(toolName) missing")
            #expect(tool?.bridgeCmd == bridgeCmd, "tool \(toolName) maps to wrong bridge cmd: \(tool?.bridgeCmd ?? "nil")")
        }
    }

    @Test("Required args are declared in the property list")
    func requiredArgsDeclared() {
        for tool in TypedToolRegistry.all {
            let names = Set(tool.properties.map(\.name))
            for req in tool.required {
                #expect(names.contains(req), "tool \(tool.name) marks \(req) required but doesn't declare it")
            }
        }
    }

    @Test("Each typed tool produces a JSON-serialisable schema with 'object' type")
    func schemasSerialise() throws {
        let encoder = JSONEncoder()
        for tool in TypedToolRegistry.all {
            let data = try encoder.encode(tool.mcpTool)
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(parsed?["name"] as? String == tool.name)
            let schema = parsed?["inputSchema"] as? [String: Any]
            #expect(schema?["type"] as? String == "object")
            #expect(schema?["additionalProperties"] as? Bool == false)
        }
    }

    @Test("parola_select_model schema declares name as required string")
    func selectModelSchema() throws {
        let tool = try #require(TypedToolRegistry.byName["parola_select_model"])
        let data = try JSONEncoder().encode(tool.mcpTool)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = parsed?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        let name = props?["name"] as? [String: Any]
        #expect(name?["type"] as? String == "string")
        #expect(schema?["required"] as? [String] == ["name"])
    }

    @Test("parola_screenshot allows windowID and format as optional enums")
    func screenshotSchema() throws {
        let tool = try #require(TypedToolRegistry.byName["parola_screenshot"])
        let data = try JSONEncoder().encode(tool.mcpTool)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = parsed?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        let format = props?["format"] as? [String: Any]
        #expect(format?["enum"] as? [String] == ["png", "jpeg"])
        let required = schema?["required"] as? [String]
        #expect(required == nil || required?.isEmpty == true)
    }

    @Test("parola_app_dispatch is registered with an opaque command + args schema")
    func dispatchSchema() throws {
        let dispatch = TypedToolRegistry.appDispatch
        #expect(dispatch.name == "parola_app_dispatch")
        let data = try JSONEncoder().encode(dispatch)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = parsed?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        #expect((props?["command"] as? [String: Any])?["type"] as? String == "string")
        let argsProp = props?["args"] as? [String: Any]
        #expect(argsProp?["type"] as? String == "object")
        #expect(argsProp?["additionalProperties"] as? Bool == true)
        #expect(schema?["required"] as? [String] == ["command"])
    }

    @Test("ToolRegistry.allTools emits typed tools + dispatch and de-dupes engine names")
    func registryEmitsTypedAndDispatch() {
        let names = ToolRegistry.allToolNames()
        #expect(names.contains("parola_app_dispatch"))
        #expect(names.contains("parola_select_model"))
        #expect(names.contains("parola_get_accessibility_tree"))
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }
        #expect(dupes.isEmpty, "duplicate tool names: \(dupes.keys)")
    }

    @Test("Typed tool invocation forwards filtered args to the right bridge command")
    func typedToolForwarding() async throws {
        let tool = try #require(TypedToolRegistry.byName["parola_load_entry"])
        let bridge = RecordingBridge()
        _ = try await tool.invoke(args: ["id": "abc123", "ignored": 42], bridge: bridge)
        let call = try #require(await bridge.lastCall)
        #expect(call.cmd == "loadEntry")
        let parsed = try JSONSerialization.jsonObject(with: call.argsJSON) as? [String: Any]
        #expect(parsed?["id"] as? String == "abc123")
        #expect(parsed?["ignored"] == nil)
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
