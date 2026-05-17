import Foundation

public enum ToolRegistry {
    public static func allTools() -> [MCPTool] {
        EngineTool.allCases.map(\.mcpTool) + AppTools.all.map(\.mcpTool)
    }

    public static func allToolNames() -> [String] {
        EngineTool.allCases.map(\.rawValue) + AppTools.all.map(\.name)
    }
}
