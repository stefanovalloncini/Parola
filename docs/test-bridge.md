# Test bridge

Debug-only IPC that lets the `parola-mcp` server drive a running Parola.app. Built so Claude (or any MCP client) can change models, paste URLs, start recordings, and read state without anyone touching the GUI.

## What ships

| Piece | Path | Build configuration |
|---|---|---|
| In-app listener | `ParolaApp/ParolaApp/Bridge/ParolaTestBridge.swift` | `#if DEBUG`, stripped from Release |
| MCP client | `ParolaCore/Sources/parola-mcp/BridgeClient.swift` | always |
| MCP tool surface | `ParolaCore/Sources/parola-mcp/Tools.swift` (`parola_app_*`) | always |
| Discovery file | `~/Library/Caches/Parola/bridge.port` | written at app launch |
| Wire-up | `.mcp.json` at repo root | committed |

## How it talks

The bridge listens on TCP loopback. On startup it asks the kernel for any free port, writes that port to `~/Library/Caches/Parola/bridge.port`, and starts accepting connections.

`BridgeClient` reads the port file, opens a connection, writes one line of JSON, reads one line of JSON, and closes. One request per connection. No pooling, because there's nothing worth pooling.

Request:

```json
{"id": "uuid", "cmd": "selectModel", "args": {"name": "openai_whisper-tiny"}}
```

Response (success):

```json
{"id": "uuid", "ok": true, "result": {...}}
```

Response (failure):

```json
{"id": "uuid", "ok": false, "error": "missing 'name'"}
```

Every dispatch hops to `@MainActor` before touching `AppModel`, so the bridge is safe to call from any queue.

## Tool reference

Every `parola_app_*` tool fails with a clean error when the bridge isn't reachable. Required arguments are bold.

| Tool | Args | What it does |
|---|---|---|
| `parola_app_ping` | — | Returns `{pong: true}`. Use to confirm the bridge is up. |
| `parola_app_state` | — | Full state snapshot: phase, route, selectedModel, language, libraryFilter, appTheme, availableModels, transcript presence. |
| `parola_app_select_model` | **name** | Set selectedModel to a catalog id. |
| `parola_app_set_language` | code | Two-letter language code, or empty string to auto-detect. |
| `parola_app_set_theme` | **theme** | `light` / `dark` / `system`. |
| `parola_app_set_route` | **route** | `transcript` / `batch` / `queue`. |
| `parola_app_set_library_filter` | category | `transcription` / `meeting` / `dictation`, or empty to clear. |
| `parola_app_transcribe_youtube` | **url** | Paste a YouTube URL and start the download-then-transcribe flow. |
| `parola_app_fetch_youtube_subs` | **url** | Same input, but fetch existing captions instead of running Whisper. |
| `parola_app_start_recording` | source, category | Start mic (default) or systemAudio. Category tags the saved entry. |
| `parola_app_stop_recording` | — | Stop the active recording and finalize the transcript. |
| `parola_app_set_translate` | **on** | Toggle translate-to-English. |
| `parola_app_set_use_streaming` | **on** | Toggle the live-mic streaming path. |
| `parola_app_toggle_live_captions` | — | Show or hide the Live Captions overlay. |
| `parola_app_wait_for_phase` | **phase**, timeoutMs | Poll until phase matches or timeout fires. Returns `{matched, state}`. |
| `parola_app_get_transcript` | — | Text + language + modelName + segment count + duration. Null if none loaded. |
| `parola_app_clear_transcript` | — | Drop the in-memory transcript. |
| `parola_app_list_entries` | category, limit | Library entries with id, title, category, createdAt. |
| `parola_app_load_entry` | **id** | Open a library entry by id. |
| `parola_app_delete_entry` | **id** | Move an entry to Recently Deleted. |
| `parola_app_download_model` | **name** | Trigger a download from inside the app. Progress shows in the UI. |
| `parola_app_delete_model` | **name** | Delete a downloaded model. |
| `parola_app_export_transcript` | **format** | txt / md / html / docx / pdf / csv / srt / vtt / json. The app's save panel handles the destination. |
| `parola_app_dismiss_error` | — | Clear a failed phase (equivalent to clicking "Try again"). |
| `parola_app_screenshot` | path | Capture the main window to PNG. SwiftUI custom views aren't fully captured by `dataWithPDF`; only NSTextField-shaped content shows up reliably. |
| `parola_app_list_windows` | — | Visible NSWindows: title, size, key/main flags. |

### Settings + library

| Tool | Args | What it does |
|---|---|---|
| `parola_app_get_settings` | — | All UserDefaults-backed settings: theme, model, language, streaming, diarize, wordTimestamps, dictation, sidebar density, batch export prefs, meeting detector. |
| `parola_app_set_setting` | **key**, value | Generic UserDefaults setter. Bypasses `@AppStorage`'s outside-of-View flakiness by writing directly + nudging `objectWillChange`. |
| `parola_app_open_settings` | — | Open the Settings window via the standard `showSettingsWindow:` selector. |
| `parola_app_close_settings` | — | Close any open Settings window. |
| `parola_app_search` | **query**, limit | Full-text search across the library; polls until the 200 ms debounce settles. |
| `parola_app_list_deleted_entries` | limit | Recently Deleted entries with id, title, category, deletedAt. |
| `parola_app_restore_entry` | **id** | Move an entry back from Recently Deleted. |
| `parola_app_purge_entry` | **id** | Permanently delete from Recently Deleted. |

### Prompts + batch + files

| Tool | Args | What it does |
|---|---|---|
| `parola_app_list_prompts` | — | Built-in + user prompts: Cleanup, Translate, Professional tone, Bullet points, Action items, plus any user-added. |
| `parola_app_run_prompt` | **name** or **id** | Run a prompt against the current transcript. Requires Apple Intelligence. |
| `parola_app_get_prompt_output` | — | Latest `{promptName, text}` or null. |
| `parola_app_transcribe_file` | **path**, translate | Drop-equivalent: transcribe a file by absolute path. |
| `parola_app_start_batch` | **paths** | Submit multiple files. Auto-navigates to Batch view. |
| `parola_app_add_batch_files` | **paths** | Append more files to the existing batch. |
| `parola_app_clear_batch` | — | Cancel and remove all queued jobs. |
| `parola_app_select_batch_job` | **id** | Select a specific job to view its transcript. |
| `parola_app_get_batch_jobs` | — | All jobs: id, file, status (pending/transcribing/done/failed/cancelled), progress, error. |
| `parola_app_summarize_latest_entry` | — | Run the on-device summarizer against the most recent library entry. |
| `parola_app_reveal_cache_directory` | — | Open Finder showing the model cache directory. |

## Workflow

1. Run a Debug build of Parola.app (Xcode → Run, or `open` the binary in `~/Library/Developer/Xcode/DerivedData/.../Parola.app`). Look for `[ParolaTestBridge] listening on 127.0.0.1:<port>` in stderr.
2. Claude Code picks up the server from `.mcp.json` on the next session. For ad-hoc testing, run `parola-mcp` directly over stdio.
3. Call `parola_app_ping` first. If it returns `pong`, the rest works.

End-to-end example. Transcribe a YouTube URL and read the result back:

```text
parola_app_select_model        { "name": "openai_whisper-large-v3_turbo" }
parola_app_set_language        { "code": "" }                # auto-detect
parola_app_transcribe_youtube  { "url": "https://www.youtube.com/watch?v=..." }
parola_app_wait_for_phase      { "phase": "ready", "timeoutMs": 120000 }
parola_app_get_transcript      {}
```

## Adding a new command

1. Add a `case "myThing":` block to `dispatch(cmd:args:)` in `ParolaTestBridge.swift`. Parse args, call into `AppModel`, return a `[String: Any]`.
2. Add a `MCPTool(name: "parola_app_my_thing", ...)` entry to `Tools.all()`.
3. Add a `case "parola_app_my_thing":` to `MCPServer.callTool`, listing which arg keys to forward.

That's the whole loop. The wire format has no versioning or schema validation on purpose. If the dispatch can't find a required arg it throws, and the MCP client surfaces the error text as an `isError` content block.

## Why not Accessibility or XCUITest

AX scripting needs Accessibility permission and breaks when SwiftUI rearranges views. The bridge reads the same `AppModel` the views read from, so identifier drift doesn't matter.

XCUITest spins up a fresh app each run. The bridge talks to the live process, which is useful when reproducing a bug that needed manual setup.

For CI-friendly regression coverage, XCUITest is the right layer. For "Claude, try this thing while I watch," the bridge is.

## Caveats

Release builds have no bridge. The `#if DEBUG` strip is deliberate so notarised binaries can't be remote-controlled.

TCP loopback is bound with `acceptLocalOnly = true`. Anyone on this machine could connect to it. If you don't trust your local user, don't run Debug builds with the bridge.

The bridge holds a weak reference to `AppModel`. When the app quits, the listener stops and the port file goes stale. `BridgeClient` reads the file fresh on every call, so it picks up a relaunched app on a new port without any restart on the MCP side.
