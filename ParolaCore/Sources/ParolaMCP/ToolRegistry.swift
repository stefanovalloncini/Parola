import Foundation

public enum ToolRegistry {
    public static func allTools() -> [MCPTool] {
        let engineNames = Set(EngineTool.allCases.map(\.rawValue))
        return EngineTool.allCases.map(\.mcpTool)
            + TypedToolRegistry.emittedTools(skipping: engineNames)
    }

    public static func allToolNames() -> [String] {
        allTools().map(\.name)
    }
}
