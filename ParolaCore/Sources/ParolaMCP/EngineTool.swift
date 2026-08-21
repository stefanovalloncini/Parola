import Foundation

/// MCP tools served directly by the engine — no running app required. Exhaustively switched in `MCPServer.invoke` so registration and handling stay in sync.
public enum EngineTool: String, CaseIterable, Sendable {
    case transcribe       = "parola_transcribe"
    case listModels       = "parola_list_models"
    case listEngines      = "parola_list_engines"
    case searchLibrary    = "parola_search_library"
    case listRecent       = "parola_list_recent"
    case summarize        = "parola_summarize"
    case openApp          = "parola_open_app"

    public var mcpTool: MCPTool {
        switch self {
        case .transcribe:
            return MCPTool(
                name: rawValue,
                description: "Transcribe an audio or video file using Parola's on-device engine.",
                inputSchema: AnyEncodable([
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the audio or video file."],
                        "model": ["type": "string", "description": "Model variant id (see parola_list_models). Defaults to the recommended model."],
                        "language": ["type": "string", "description": "Two-letter language code (en, it, ...). Omit to auto-detect."],
                        "format": ["type": "string", "description": "Output format: txt, md, srt, vtt, json", "enum": TranscribeFormat.allCases.map(\.rawValue)],
                        "translate": ["type": "boolean", "default": false, "description": "Translate the speech to English instead of transcribing what was said. Only engines whose parola_list_engines row reads translate=true accept it."],
                        "initial_prompt": ["type": "string", "description": "Words or proper nouns to bias decoding toward. Whisper truncates it internally to about 224 tokens, so keep it short."],
                    ],
                    "required": ["path"],
                ] as [String: Any])
            )
        case .listModels:
            return MCPTool(
                name: rawValue,
                description: "List Parola's model catalog grouped by category, with installation state.",
                inputSchema: AnyEncodable(["type": "object", "properties": [String: Any]()] as [String: Any])
            )
        case .listEngines:
            return MCPTool(
                name: rawValue,
                description: "List registered transcription engines and their capabilities.",
                inputSchema: AnyEncodable(["type": "object", "properties": [String: Any]()] as [String: Any])
            )
        case .searchLibrary:
            return MCPTool(
                name: rawValue,
                description: "Search Parola's transcript library by title substring.",
                inputSchema: AnyEncodable([
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "default": 10],
                    ],
                    "required": ["query"],
                ] as [String: Any])
            )
        case .listRecent:
            return MCPTool(
                name: rawValue,
                description: "List recent transcripts in Parola's library.",
                inputSchema: AnyEncodable([
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "default": 10],
                    ],
                ] as [String: Any])
            )
        case .summarize:
            return MCPTool(
                name: rawValue,
                description: "Transcribe and summarise an audio file using the on-device LLM.",
                inputSchema: AnyEncodable([
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                ] as [String: Any])
            )
        case .openApp:
            return MCPTool(
                name: rawValue,
                description: "Launch Parola.app if it isn't running and wait until the app bridge is reachable. Call this first when the parola_* app tools report the bridge is down.",
                inputSchema: AnyEncodable([
                    "type": "object",
                    "properties": [
                        "timeoutMs": ["type": "integer", "description": "Max ms to wait for the bridge after launch. Defaults to 10000."],
                        "bundleID": ["type": "string", "description": "Override the bundle id. Defaults to app.parola.ParolaApp."],
                    ],
                ] as [String: Any])
            )
        }
    }
}
