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

    @Test("App tool names are namespaced under parola_app_")
    func appNaming() {
        for tool in AppTools.all {
            #expect(tool.name.hasPrefix("parola_app_"), "app tool \(tool.name) missing prefix")
        }
    }

    @Test("Required props are declared properties")
    func requiredArePresent() {
        for tool in AppTools.all {
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

    @Test("App tool schema mirrors property declarations")
    func appToolSchemaShape() throws {
        let setTheme = try #require(AppTools.byName["parola_app_set_theme"])
        let data = try JSONEncoder().encode(setTheme.mcpTool)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = parsed?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        let theme = props?["theme"] as? [String: Any]
        #expect(theme?["type"] as? String == "string")
        #expect(theme?["enum"] as? [String] == ["light", "dark", "system"])
        #expect(schema?["required"] as? [String] == ["theme"])
    }

    @Test("Bridge invocation forwards filtered args and command")
    func bridgeInvocationFiltersArgs() async throws {
        let tool = try #require(AppTools.byName["parola_app_select_model"])
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
        let tool = try #require(AppTools.byName["parola_app_ping"])
        let bridge = RecordingBridge()
        _ = try await tool.invoke(args: ["whatever": "should-be-dropped"], bridge: bridge)

        let call = try #require(await bridge.lastCall)
        #expect(call.cmd == "ping")
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

    @Test("Dictation app tools forward to startDictation / stopDictation")
    func dictationToolsForwardCorrectly() async throws {
        let start = try #require(AppTools.byName["parola_app_dictate"])
        let stop = try #require(AppTools.byName["parola_app_dictate_stop"])
        let bridge = RecordingBridge()
        _ = try await start.invoke(args: [:], bridge: bridge)
        let startCall = try #require(await bridge.lastCall)
        #expect(startCall.cmd == "startDictation")
        _ = try await stop.invoke(args: [:], bridge: bridge)
        let stopCall = try #require(await bridge.lastCall)
        #expect(stopCall.cmd == "stopDictation")
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
