import Foundation

/// The curated top-20 MCP tools exposed by `parola-mcp`. Each entry pairs a typed schema with
/// the bridge command it forwards to. Long-tail commands stay reachable via `parola_app_dispatch`.
public struct TypedTool: Sendable {
    public let name: String
    public let bridgeCmd: String
    public let description: String
    public let properties: [AppTool.Property]
    public let required: [String]
    public let additionalProperties: Bool

    public init(
        name: String,
        bridgeCmd: String,
        description: String,
        properties: [AppTool.Property],
        required: [String] = [],
        additionalProperties: Bool = false
    ) {
        self.name = name
        self.bridgeCmd = bridgeCmd
        self.description = description
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
    }

    public var mcpTool: MCPTool {
        var schema: [String: Any] = ["type": "object"]
        var props: [String: Any] = [:]
        for p in properties { props[p.name] = p.schema }
        schema["properties"] = props
        schema["additionalProperties"] = additionalProperties
        if !required.isEmpty { schema["required"] = required }
        return MCPTool(name: name, description: description, inputSchema: AnyEncodable(schema))
    }

    public var argKeys: [String] { properties.map(\.name) }

    public func invoke(args: [String: Any], bridge: any BridgeProtocol) async throws -> MCPToolCallResult {
        let keys = Set(argKeys)
        let filtered = args.filter { keys.contains($0.key) }
        let argsData = (try? JSONSerialization.data(withJSONObject: filtered)) ?? Data("{}".utf8)
        let text = try await bridge.call(bridgeCmd, argsJSON: argsData)
        return MCPToolCallResult(text: text)
    }
}

public enum TypedToolRegistry {
    /// The full top-20 list, in the order they appear in the v7-C spec.
    public static let all: [TypedTool] = [
        TypedTool(
            name: "parola_select_model",
            bridgeCmd: "selectModel",
            description: "Change the model selected in the running app. Pass a variant id from parola_list_models (e.g. 'openai_whisper-large-v3_turbo').",
            properties: [.string("name", description: "Model variant id.")],
            required: ["name"]
        ),
        TypedTool(
            name: "parola_transcribe_file",
            bridgeCmd: "transcribeFile",
            description: "Transcribe a local audio or video file with the currently selected model. Mirrors dropping the file onto the app.",
            properties: [
                .string("path", description: "Absolute path to the audio or video file."),
                .bool("translate", description: "Translate to English when supported by the model."),
            ],
            required: ["path"]
        ),
        TypedTool(
            name: "parola_transcribe_youtube",
            bridgeCmd: "transcribeYouTube",
            description: "Submit a YouTube URL to the running app. The app downloads audio via yt-dlp, then transcribes.",
            properties: [
                .string("url", description: "YouTube URL."),
                .int("expectedSpeakers", description: "Optional hint for diarisation."),
            ],
            required: ["url"]
        ),
        TypedTool(
            name: "parola_load_entry",
            bridgeCmd: "loadEntry",
            description: "Open a library entry by id. Clears any active library filter and shows the transcript.",
            properties: [.string("id", description: "Library entry id.")],
            required: ["id"]
        ),
        TypedTool(
            name: "parola_search_library",
            bridgeCmd: "search",
            description: "Full-text search the library. Returns matching entries with id, title, category.",
            properties: [
                .string("query", description: "Query string."),
                .int("limit", description: "Max entries to return (default 20)."),
            ],
            required: ["query"]
        ),
        TypedTool(
            name: "parola_start_batch",
            bridgeCmd: "startBatch",
            description: "Submit multiple files for batch transcription. Routes the app to the Batch view.",
            properties: [.stringArray("paths", description: "Absolute file paths to enqueue.")],
            required: ["paths"]
        ),
        TypedTool(
            name: "parola_add_batch_files",
            bridgeCmd: "addBatchFiles",
            description: "Append files to the current batch queue without resetting it.",
            properties: [.stringArray("paths", description: "Absolute file paths to enqueue.")],
            required: ["paths"]
        ),
        TypedTool(
            name: "parola_run_prompt",
            bridgeCmd: "runPrompt",
            description: "Run a prompt against the currently loaded transcript. Pass the prompt's id (or name).",
            properties: [
                .string("promptID", description: "Prompt id from parola_app_list_prompts."),
                .string("name", description: "Alternative: prompt display name."),
                .string("id", description: "Alias for promptID."),
            ],
            required: []
        ),
        TypedTool(
            name: "parola_get_state",
            bridgeCmd: "getState",
            description: "Snapshot the running app's state. Optional 'include' filters by area: app, selection, transcript, library, batch, find, recording, dictation, sheets, windows.",
            properties: [
                .stringArray("include", description: "Whitelist of state areas to include."),
            ],
            required: []
        ),
        TypedTool(
            name: "parola_get_state_revision",
            bridgeCmd: "getStateRevision",
            description: "Returns a monotonically increasing counter bumped after every mutating command.",
            properties: [],
            required: []
        ),
        TypedTool(
            name: "parola_get_accessibility_tree",
            bridgeCmd: "getAccessibilityTree",
            description: "Dump the main window's accessibility tree as JSON. Strictly observational — to act, always go through bridge commands.",
            properties: [
                .string("windowID", description: "Window id from parola_app_list_windows. Defaults to 'main'."),
                .string("filter", enum: ["actionable", "all"], description: "Filter mode. 'actionable' keeps interactive nodes only."),
            ],
            required: []
        ),
        TypedTool(
            name: "parola_screenshot",
            bridgeCmd: "screenshot",
            description: "Capture the main window's contents. Returns base64 (<1MB) or a tempPath.",
            properties: [
                .string("windowID", description: "Window id from parola_app_list_windows. Defaults to 'main'."),
                .string("format", enum: ["png", "jpeg"], description: "Image format. Defaults to png."),
            ],
            required: []
        ),
        TypedTool(
            name: "parola_wait_for_phase",
            bridgeCmd: "waitForPhase",
            description: "Poll until the app's phase matches 'phase' or the timeout fires.",
            properties: [
                .string("phase", enum: ["idle", "downloadingModel", "loadingModel", "transcribing", "recording", "ready", "failed"], description: "Phase to wait for."),
                .int("timeoutMs", description: "Max ms to wait. Defaults to 10000."),
            ],
            required: ["phase"]
        ),
        TypedTool(
            name: "parola_wait_for_batch_job",
            bridgeCmd: "waitForBatchJob",
            description: "Poll until a batch job reaches a terminal status (done/failed/cancelled) or the timeout fires.",
            properties: [
                .string("jobID", description: "Batch job UUID."),
                .int("timeoutMs", description: "Max ms to wait. Defaults to 30000."),
            ],
            required: ["jobID"]
        ),
        TypedTool(
            name: "parola_wait_for_revision",
            bridgeCmd: "waitForRevision",
            description: "Block until the state revision counter reaches 'min' or the timeout fires.",
            properties: [
                .int("min", description: "Minimum revision value to wait for."),
                .int("timeoutMs", description: "Max ms to wait. Defaults to 5000."),
            ],
            required: ["min"]
        ),
        TypedTool(
            name: "parola_start_dictation",
            bridgeCmd: "startDictation",
            description: "Start a push-to-talk dictation session.",
            properties: [],
            required: []
        ),
        TypedTool(
            name: "parola_stop_dictation",
            bridgeCmd: "stopDictation",
            description: "End the current dictation session and insert the cleaned-up text at the cursor.",
            properties: [],
            required: []
        ),
        TypedTool(
            name: "parola_export_transcript",
            bridgeCmd: "exportTranscript",
            description: "Export the current transcript. The save panel is shown by the app.",
            properties: [
                .string("format", enum: ["txt", "md", "html", "docx", "pdf", "csv", "srt", "vtt", "json"], description: "Output format."),
                .bool("includeTimestamps", description: "Embed segment timestamps in formats that support them."),
            ],
            required: ["format"]
        ),
        TypedTool(
            name: "parola_open_settings",
            bridgeCmd: "openSettings",
            description: "Open the Settings window, optionally focusing a specific pane.",
            properties: [
                .string("pane", description: "Pane identifier (e.g. 'general', 'dictation')."),
            ],
            required: []
        ),
        TypedTool(
            name: "parola_reset_test_state",
            bridgeCmd: "resetTestState",
            description: "Reset the app to a clean state for tests. Only available when launched with --test-mode.",
            properties: [],
            required: []
        ),
    ]

    public static let byName: [String: TypedTool] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    public static let appDispatch: MCPTool = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "Bridge command name (camelCase, as returned by _handshake)."],
                "args": ["type": "object", "description": "Command arguments. Schema depends on the command.", "additionalProperties": true],
            ],
            "required": ["command"],
            "additionalProperties": false,
        ]
        return MCPTool(
            name: "parola_app_dispatch",
            description: "Generic fallback for any bridge command not exposed as a typed tool. Use _handshake to discover the catalog. Prefer typed tools when available.",
            inputSchema: AnyEncodable(schema)
        )
    }()

    /// Returns the tools emitted to `tools/list`: typed entries that don't collide with an engine
    /// tool name, plus the catch-all dispatch tool.
    public static func emittedTools(skipping engineNames: Set<String>) -> [MCPTool] {
        all.filter { !engineNames.contains($0.name) }.map(\.mcpTool) + [appDispatch]
    }
}
