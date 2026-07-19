import Foundation

/// MCP tool that proxies to the running Parola.app's debug bridge. `properties` doubles as JSON schema and the allow-list of arg keys forwarded over the wire.
public struct AppTool: Sendable {
    public let name: String
    public let bridgeCmd: String
    public let description: String
    public let properties: [Property]
    public let required: [String]

    public struct Property: Sendable {
        public enum Kind: Sendable {
            case string(enum: [String]? = nil)
            case boolean
            case integer
            case stringArray
            case any
        }
        public let name: String
        public let kind: Kind
        public let description: String?

        public static func string(_ name: String, enum vals: [String]? = nil, description: String? = nil) -> Self {
            .init(name: name, kind: .string(enum: vals), description: description)
        }
        public static func bool(_ name: String, description: String? = nil) -> Self {
            .init(name: name, kind: .boolean, description: description)
        }
        public static func int(_ name: String, description: String? = nil) -> Self {
            .init(name: name, kind: .integer, description: description)
        }
        public static func stringArray(_ name: String, description: String? = nil) -> Self {
            .init(name: name, kind: .stringArray, description: description)
        }
        public static func any(_ name: String, description: String? = nil) -> Self {
            .init(name: name, kind: .any, description: description)
        }

        var schema: [String: Any] {
            var s: [String: Any] = [:]
            switch kind {
            case .string(let vals):
                s["type"] = "string"
                if let vals { s["enum"] = vals }
            case .boolean:
                s["type"] = "boolean"
            case .integer:
                s["type"] = "integer"
            case .stringArray:
                s["type"] = "array"
                s["items"] = ["type": "string"]
            case .any:
                break
            }
            if let description { s["description"] = description }
            return s
        }
    }

    public var mcpTool: MCPTool {
        var schema: [String: Any] = ["type": "object"]
        var props: [String: Any] = [:]
        for p in properties { props[p.name] = p.schema }
        schema["properties"] = props
        schema["additionalProperties"] = false
        if !required.isEmpty { schema["required"] = required }
        return MCPTool(name: name, description: description, inputSchema: AnyEncodable(schema))
    }

    public var argKeys: [String] { properties.map(\.name) }

    public func invoke(args: [String: Any], bridge: any BridgeProtocol) async throws -> MCPToolCallResult {
        let keys = argKeys
        let filtered: [String: Any] = keys.isEmpty
            ? [:]
            : args.filter { keys.contains($0.key) }
        let argsData = (try? JSONSerialization.data(withJSONObject: filtered)) ?? Data("{}".utf8)
        let text = try await bridge.call(bridgeCmd, argsJSON: argsData)
        return MCPToolCallResult(text: text)
    }
}

public enum AppTools {
    public static let all: [AppTool] = [
        AppTool(
            name: "parola_app_ping",
            bridgeCmd: "ping",
            description: "Reach out to the running app to confirm the bridge is healthy. Returns {pong: true}.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_state",
            bridgeCmd: "getState",
            description: "Snapshot the running Parola.app: phase (idle/loadingModel/downloadingModel/transcribing/recording/exporting/ready/failed), route, selectedModel, language, libraryFilter, appTheme, transcript presence, model list. Fails if no Debug build is running.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_select_model",
            bridgeCmd: "selectModel",
            description: "Change the selected model in the running app. Pass a variant id from parola_list_models (e.g. 'openai_whisper-large-v3_turbo').",
            properties: [.string("name")],
            required: ["name"]
        ),
        AppTool(
            name: "parola_app_set_language",
            bridgeCmd: "setLanguage",
            description: "Set the transcription language code (en, it, fr, …). Pass an empty string to auto-detect.",
            properties: [.string("code")],
            required: []
        ),
        AppTool(
            name: "parola_app_set_theme",
            bridgeCmd: "setTheme",
            description: "Switch the app theme. Accepts 'light', 'dark', or 'system'.",
            properties: [.string("theme", enum: ["light", "dark", "system"])],
            required: ["theme"]
        ),
        AppTool(
            name: "parola_app_set_route",
            bridgeCmd: "setRoute",
            description: "Navigate the detail pane. Accepts 'transcript', 'batch', or 'queue'.",
            properties: [.string("route", enum: ["transcript", "batch", "queue"])],
            required: ["route"]
        ),
        AppTool(
            name: "parola_app_set_library_filter",
            bridgeCmd: "setLibraryFilter",
            description: "Filter the library detail view by entry category. Pass 'transcription', 'meeting', 'dictation', or an empty string to clear the filter and return to Home.",
            properties: [.string("category", enum: ["transcription", "meeting", "dictation", ""])],
            required: []
        ),
        AppTool(
            name: "parola_app_transcribe_youtube",
            bridgeCmd: "transcribeYouTube",
            description: "Submit a YouTube URL to the running app. The app downloads audio via yt-dlp, then transcribes. Combine with parola_app_wait_for_phase to wait for 'ready'.",
            properties: [.string("url")],
            required: ["url"]
        ),
        AppTool(
            name: "parola_app_fetch_youtube_subs",
            bridgeCmd: "fetchYouTubeSubs",
            description: "Submit a YouTube URL and fetch existing captions via yt-dlp instead of running Whisper.",
            properties: [.string("url")],
            required: ["url"]
        ),
        AppTool(
            name: "parola_app_start_recording",
            bridgeCmd: "startRecording",
            description: "Start a microphone or system-audio recording. 'source' is 'microphone' (default) or 'systemAudio'. 'category' tags the resulting library entry: 'transcription' (default), 'meeting', or 'dictation'.",
            properties: [
                .string("source", enum: ["microphone", "systemAudio"]),
                .string("category", enum: ["transcription", "meeting", "dictation"]),
            ],
            required: []
        ),
        AppTool(
            name: "parola_app_stop_recording",
            bridgeCmd: "stopRecording",
            description: "Stop the active recording and run transcription. For streaming-mic this finishes the live session and emits a final transcript.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_dictate",
            bridgeCmd: "startDictation",
            description: "Start a push-to-talk dictation session in the running app. Equivalent to pressing the dictation hotkey.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_dictate_stop",
            bridgeCmd: "stopDictation",
            description: "End the current dictation session and insert the cleaned-up text at the cursor.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_set_translate",
            bridgeCmd: "setTranslate",
            description: "Toggle translate-to-English mode for the next transcription. 'on' is required.",
            properties: [.bool("on")],
            required: ["on"]
        ),
        AppTool(
            name: "parola_app_set_use_streaming",
            bridgeCmd: "setUseStreaming",
            description: "Toggle the streaming microphone pipeline. When off, mic recordings transcribe after stop instead of live.",
            properties: [.bool("on")],
            required: ["on"]
        ),
        AppTool(
            name: "parola_app_toggle_live_captions",
            bridgeCmd: "toggleLiveCaptions",
            description: "Toggle the Live Captions overlay on or off.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_wait_for_phase",
            bridgeCmd: "waitForPhase",
            description: "Poll until the app's phase matches 'phase' (idle/loadingModel/downloadingModel/transcribing/recording/exporting/ready/failed) or the timeout fires. 'timeoutMs' defaults to 10000.",
            properties: [
                .string("phase", enum: ["idle", "downloadingModel", "loadingModel", "transcribing", "recording", "exporting", "ready", "failed"]),
                .int("timeoutMs"),
            ],
            required: ["phase"]
        ),
        AppTool(
            name: "parola_app_get_transcript",
            bridgeCmd: "getTranscript",
            description: "Return the transcript currently loaded in the app: text, language, modelName, segment count, duration.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_clear_transcript",
            bridgeCmd: "clearTranscript",
            description: "Drop the in-memory transcript and return to the empty pane.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_cancel",
            bridgeCmd: "cancel",
            description: "Cancel any in-flight transcription, YouTube download, batch run, streaming mic session, or recording. Restores phase to idle. Returns {cancelled: true} if there was work to cancel.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_dismiss_error",
            bridgeCmd: "dismissError",
            description: "Clear a failed phase. Equivalent to clicking 'Try again' on the error screen.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_list_entries",
            bridgeCmd: "listEntries",
            description: "List library entries from the running app. Optional 'category' (transcription/meeting/dictation) filters; 'limit' caps the result count (default 50).",
            properties: [
                .string("category", enum: ["transcription", "meeting", "dictation"]),
                .int("limit"),
            ],
            required: []
        ),
        AppTool(
            name: "parola_app_load_entry",
            bridgeCmd: "loadEntry",
            description: "Open a library entry by id (clears any active library filter and shows the transcript).",
            properties: [.string("id")],
            required: ["id"]
        ),
        AppTool(
            name: "parola_app_delete_entry",
            bridgeCmd: "deleteEntry",
            description: "Move a library entry to Recently Deleted by id.",
            properties: [.string("id")],
            required: ["id"]
        ),
        AppTool(
            name: "parola_app_download_model",
            bridgeCmd: "downloadModel",
            description: "Trigger a model download from inside the running app (shows progress in the UI).",
            properties: [.string("name")],
            required: ["name"]
        ),
        AppTool(
            name: "parola_app_delete_model",
            bridgeCmd: "deleteModel",
            description: "Delete a downloaded model from disk.",
            properties: [.string("name")],
            required: ["name"]
        ),
        AppTool(
            name: "parola_app_export_transcript",
            bridgeCmd: "exportTranscript",
            description: "Export the current transcript via the app's export pipeline. 'format' is one of txt, md, html, docx, pdf, csv, tsv, srt, vtt, json, jsonl, fcpxml, lrc. The save panel is shown by the app.",
            properties: [.string("format", enum: ["txt", "md", "html", "docx", "pdf", "csv", "tsv", "srt", "vtt", "json", "jsonl", "fcpxml", "lrc"])],
            required: ["format"]
        ),
        AppTool(
            name: "parola_app_screenshot",
            bridgeCmd: "screenshot",
            description: "Capture the app's main window to a PNG via ScreenCaptureKit (needs Screen Recording permission). Optional 'path' is a bare filename stored under Caches/Parola/Screenshots. Returns {path, width, height, bytes, windowTitle}.",
            properties: [.string("path")],
            required: []
        ),
        AppTool(
            name: "parola_app_list_windows",
            bridgeCmd: "listWindows",
            description: "List visible NSWindows owned by the running app with title, size, key/main state. Useful for picking the right window before screenshotting.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_list_deleted_entries",
            bridgeCmd: "listDeletedEntries",
            description: "List entries in Recently Deleted. Optional 'limit' (default 50).",
            properties: [.int("limit")],
            required: []
        ),
        AppTool(
            name: "parola_app_restore_entry",
            bridgeCmd: "restoreEntry",
            description: "Restore an entry from Recently Deleted back to the library by id.",
            properties: [.string("id")],
            required: ["id"]
        ),
        AppTool(
            name: "parola_app_purge_entry",
            bridgeCmd: "purgeEntry",
            description: "Permanently delete an entry from Recently Deleted. Bypasses the 30-day retention window.",
            properties: [.string("id")],
            required: ["id"]
        ),
        AppTool(
            name: "parola_app_search",
            bridgeCmd: "search",
            description: "Full-text search the library. Returns matching entries with id, title, category. Optional 'limit' (default 20).",
            properties: [.string("query"), .int("limit")],
            required: ["query"]
        ),
        AppTool(
            name: "parola_app_transcribe_file",
            bridgeCmd: "transcribeFile",
            description: "Open a local audio or video file by absolute path and transcribe it with the currently selected model. Mirrors what dropping a file onto the app does.",
            properties: [.string("path"), .bool("translate")],
            required: ["path"]
        ),
        AppTool(
            name: "parola_app_list_prompts",
            bridgeCmd: "listPrompts",
            description: "Return Parola's prompt library: built-in prompts (Cleanup, Translate, Professional tone, ...) plus any user-defined ones. Each entry has id, name, isBuiltIn, instructions.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_run_prompt",
            bridgeCmd: "runPrompt",
            description: "Run a prompt against the currently loaded transcript. Pass either the prompt's 'name' or 'id'. Output lands asynchronously; poll parola_app_get_prompt_output until isRunningPrompt flips off.",
            properties: [.string("name"), .string("id")],
            required: []
        ),
        AppTool(
            name: "parola_app_get_prompt_output",
            bridgeCmd: "getPromptOutput",
            description: "Return the latest prompt-run result {promptName, text}, or null if no prompt has been run since the transcript was loaded.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_start_batch",
            bridgeCmd: "startBatch",
            description: "Submit multiple files (array of absolute paths) for batch transcription. Routes the app to the Batch view.",
            properties: [.stringArray("paths")],
            required: ["paths"]
        ),
        AppTool(
            name: "parola_app_add_batch_files",
            bridgeCmd: "addBatchFiles",
            description: "Append more files to the current batch queue without resetting it. Accepts an array of absolute paths.",
            properties: [.stringArray("paths")],
            required: ["paths"]
        ),
        AppTool(
            name: "parola_app_clear_batch",
            bridgeCmd: "clearBatch",
            description: "Cancel any active batch and remove all queued jobs.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_select_batch_job",
            bridgeCmd: "selectBatchJob",
            description: "Highlight a batch job by its UUID so its transcript shows in the right pane.",
            properties: [.string("id")],
            required: ["id"]
        ),
        AppTool(
            name: "parola_app_get_batch_jobs",
            bridgeCmd: "getBatchJobs",
            description: "List currently queued batch jobs with id, file, status (pending/transcribing/done/failed/cancelled), progress, error.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_summarize_latest_entry",
            bridgeCmd: "summarizeLatestEntry",
            description: "Run the on-device summarizer against the most recent library entry. Requires Apple Intelligence enabled.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_reveal_cache_directory",
            bridgeCmd: "revealCacheDirectory",
            description: "Open Finder showing Parola's model cache directory.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_get_settings",
            bridgeCmd: "getSettings",
            description: "Return the persisted user-preference values (UserDefaults) for everything Settings shows: model, language, theme, streaming/diarize/word-timestamps toggles, dictation, sidebar density, batch export prefs, meeting detector.",
            properties: [],
            required: []
        ),
        AppTool(
            name: "parola_app_set_setting",
            bridgeCmd: "setSetting",
            description: "Set any UserDefaults-backed setting. Pass the storage 'key' (e.g. 'wordTimestamps', 'karaokeHighlight', 'diarize', 'meetingDetectorEnabled', 'sidebarDensity', 'monospacedTimestamps', 'dictationEnabled', 'batchExportToSourceFolder', 'initialPrompt') and a 'value' of the matching type. Use parola_app_get_settings to see the surface.",
            properties: [.string("key"), .any("value")],
            required: ["key"]
        ),
        AppTool(
            name: "parola_app_open_settings",
            bridgeCmd: "openSettings",
            description: "Open the Settings window, optionally focusing a pane. Pass 'pane' as one of: general, customization, watchedFolders, recordMeetings, shortcuts, microphone, liveCaptions, dictation, snippets, corrections, localModels, transcriptionDefaults, translation, ignoredSegments, findReplace, exportFormats, batchExport, autoExport, integrations, prompts, automation, updates, advanced, about. Returns whether a Settings window was found after opening.",
            properties: [.string("pane")],
            required: []
        ),
        AppTool(
            name: "parola_app_close_settings",
            bridgeCmd: "closeSettings",
            description: "Close any open Settings/Preferences window.",
            properties: [],
            required: []
        ),
    ]

    public static let byName: [String: AppTool] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )
}
