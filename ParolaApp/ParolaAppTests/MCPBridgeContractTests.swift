import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaMCP
import ParolaTestSupport

@MainActor
@Suite("MCP tools match the app's bridge commands")
struct MCPBridgeContractTests {
    private struct Tool {
        let name: String
        let bridgeCmd: String
        let properties: [AppTool.Property]
        let required: [String]
    }

    private static let tools: [Tool] =
        AppTools.all.map { Tool(name: $0.name, bridgeCmd: $0.bridgeCmd, properties: $0.properties, required: $0.required) }
        + TypedToolRegistry.all.map { Tool(name: $0.name, bridgeCmd: $0.bridgeCmd, properties: $0.properties, required: $0.required) }

    let server: ParolaAutomationServer

    init() throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("mcpcontract"))
        server = try ParolaAutomationServer(model: model)
    }

    @Test("the registries are not empty")
    func registriesAreNotEmpty() {
        #expect(!AppTools.all.isEmpty)
        #expect(!TypedToolRegistry.all.isEmpty)
    }

    @Test("every MCP tool forwards to a command the app has")
    func everyToolHasACommand() {
        for tool in Self.tools {
            #expect(server.command(named: tool.bridgeCmd) != nil, "\(tool.name) forwards to \(tool.bridgeCmd), which the app doesn't have")
        }
    }

    @Test("every argument an MCP tool forwards is one its command declares")
    func everyForwardedArgumentIsDeclared() {
        for tool in Self.tools {
            guard let command = server.command(named: tool.bridgeCmd) else { continue }
            let declared = Set(command.args.map(\.name))
            for property in tool.properties {
                #expect(declared.contains(property.name), "\(tool.name) forwards \(property.name), which \(tool.bridgeCmd) doesn't declare")
            }
        }
    }

    @Test("every argument the app can't do without is required by the MCP tool")
    func appRequiredArgumentsAreRequired() {
        for tool in Self.tools {
            guard let command = server.command(named: tool.bridgeCmd) else { continue }
            for argument in command.args where argument.required && argument.defaultValue == nil {
                #expect(tool.required.contains(argument.name), "\(tool.name) leaves \(argument.name) optional, but \(tool.bridgeCmd) requires it")
            }
        }
    }

    @Test("every MCP argument's type is one its command accepts")
    func argumentTypesAgree() {
        for tool in Self.tools {
            guard let command = server.command(named: tool.bridgeCmd) else { continue }
            let declared = Dictionary(uniqueKeysWithValues: command.args.map { ($0.name, $0.kind) })
            for property in tool.properties {
                guard let kind = declared[property.name] else { continue }
                #expect(
                    Self.accepts(kind, property.kind),
                    "\(tool.name).\(property.name) is \(property.kind), which \(tool.bridgeCmd) doesn't accept as \(kind)"
                )
            }
        }
    }

    private static func accepts(_ app: AutomationCommand.Argument.Kind, _ mcp: AppTool.Property.Kind) -> Bool {
        switch (app, mcp) {
        case (.any, _), (_, .any):
            return true
        case (.boolean, .boolean), (.integer, .integer), (.double, .integer), (.stringArray, .stringArray):
            return true
        case (.string(let allowed), .string(let offered)):
            guard let allowed else { return true }
            guard let offered else { return false }
            return Set(offered).isSubset(of: allowed)
        default:
            return false
        }
    }
}
