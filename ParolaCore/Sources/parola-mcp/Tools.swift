import Foundation

enum Tools {
    static func all() -> [MCPTool] { [
        MCPTool(
            name: "parola_transcribe",
            description: "Transcribe an audio or video file using Parola's on-device engine.",
            inputSchema: AnyEncodable([
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to the audio or video file."],
                    "model": ["type": "string", "description": "Model variant id (see parola_list_models). Defaults to the recommended model."],
                    "language": ["type": "string", "description": "Two-letter language code (en, it, ...). Omit to auto-detect."],
                    "format": ["type": "string", "description": "Output format: txt, md, srt, vtt, json", "enum": ["txt", "md", "srt", "vtt", "json"]]
                ],
                "required": ["path"]
            ] as [String: Any])
        ),
        MCPTool(
            name: "parola_list_models",
            description: "List Parola's model catalog grouped by category, with installation state.",
            inputSchema: AnyEncodable(["type": "object", "properties": [String: Any]()] as [String: Any])
        ),
        MCPTool(
            name: "parola_list_engines",
            description: "List registered transcription engines and their capabilities.",
            inputSchema: AnyEncodable(["type": "object", "properties": [String: Any]()] as [String: Any])
        ),
        MCPTool(
            name: "parola_search_library",
            description: "Search Parola's transcript library by title substring.",
            inputSchema: AnyEncodable([
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "default": 10]
                ],
                "required": ["query"]
            ] as [String: Any])
        ),
        MCPTool(
            name: "parola_list_recent",
            description: "List recent transcripts in Parola's library.",
            inputSchema: AnyEncodable([
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "default": 10]
                ]
            ] as [String: Any])
        ),
        MCPTool(
            name: "parola_summarize",
            description: "Transcribe and summarise an audio file using the on-device LLM.",
            inputSchema: AnyEncodable([
                "type": "object",
                "properties": [
                    "path": ["type": "string"]
                ],
                "required": ["path"]
            ] as [String: Any])
        )
    ] }
}
