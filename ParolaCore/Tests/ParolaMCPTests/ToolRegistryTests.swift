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
            #expect(!tool.rawValue.hasPrefix("parola_app_"), "engine tool \(tool) collides with app namespace")
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
