import Foundation

/// Tool names from before the typed tools. `tools/list` no longer offers them, but client configs and
/// scripts written against them still work: each runs the typed tool for its bridge command when there
/// is one, and otherwise sends the command with the caller's arguments, as `parola_app_dispatch` does.
enum LegacyAppTools {
    static let commands: [String: String] = [
        "parola_app_ping": "ping",
        "parola_app_state": "getState",
        "parola_app_select_model": "selectModel",
        "parola_app_set_language": "setLanguage",
        "parola_app_set_theme": "setTheme",
        "parola_app_set_route": "setRoute",
        "parola_app_set_library_filter": "setLibraryFilter",
        "parola_app_transcribe_youtube": "transcribeYouTube",
        "parola_app_fetch_youtube_subs": "fetchYouTubeSubs",
        "parola_app_start_recording": "startRecording",
        "parola_app_stop_recording": "stopRecording",
        "parola_app_dictate": "startDictation",
        "parola_app_dictate_stop": "stopDictation",
        "parola_app_set_translate": "setTranslate",
        "parola_app_set_use_streaming": "setUseStreaming",
        "parola_app_toggle_live_captions": "toggleLiveCaptions",
        "parola_app_wait_for_phase": "waitForPhase",
        "parola_app_get_transcript": "getTranscript",
        "parola_app_clear_transcript": "clearTranscript",
        "parola_app_cancel": "cancel",
        "parola_app_dismiss_error": "dismissError",
        "parola_app_list_entries": "listEntries",
        "parola_app_load_entry": "loadEntry",
        "parola_app_delete_entry": "deleteEntry",
        "parola_app_download_model": "downloadModel",
        "parola_app_delete_model": "deleteModel",
        "parola_app_export_transcript": "exportTranscript",
        "parola_app_screenshot": "screenshot",
        "parola_app_list_windows": "listWindows",
        "parola_app_list_deleted_entries": "listDeletedEntries",
        "parola_app_restore_entry": "restoreEntry",
        "parola_app_purge_entry": "purgeEntry",
        "parola_app_search": "search",
        "parola_app_transcribe_file": "transcribeFile",
        "parola_app_list_prompts": "listPrompts",
        "parola_app_run_prompt": "runPrompt",
        "parola_app_get_prompt_output": "getPromptOutput",
        "parola_app_start_batch": "startBatch",
        "parola_app_add_batch_files": "addBatchFiles",
        "parola_app_clear_batch": "clearBatch",
        "parola_app_select_batch_job": "selectBatchJob",
        "parola_app_get_batch_jobs": "getBatchJobs",
        "parola_app_summarize_latest_entry": "summarizeLatestEntry",
        "parola_app_reveal_cache_directory": "revealCacheDirectory",
        "parola_app_get_settings": "getSettings",
        "parola_app_set_setting": "setSetting",
        "parola_app_open_settings": "openSettings",
        "parola_app_close_settings": "closeSettings",
    ]

    static func invoke(_ name: String, args: [String: Any], bridge: any BridgeProtocol) async throws -> MCPToolCallResult? {
        guard let command = commands[name] else { return nil }
        if let typed = TypedToolRegistry.byCommand[command] {
            return try await typed.invoke(args: args, bridge: bridge)
        }
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        return MCPToolCallResult(text: try await bridge.call(command, argsJSON: argsData))
    }
}
