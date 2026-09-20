# Test bridge

A setting-gated local IPC that lets the `parola-mcp` server drive a running Parola.app. Built so Claude (or any MCP client) can change models, paste URLs, start recordings, and read state without anyone touching the GUI.

## What ships

| Piece | Path | Build configuration |
|---|---|---|
| In-app listener | `ParolaApp/ParolaApp/Bridge/ParolaAutomationServer.swift` | Ships in Debug and Release, gated by the `automationBridgeEnabled` setting (default on in Debug, off in Release) |
| MCP client | `ParolaCore/Sources/ParolaMCP/BridgeClient.swift` | always |
| MCP tool surface | `ParolaCore/Sources/ParolaMCP/` (`TypedToolRegistry.swift` + `AppTool.swift`) | always |
| Discovery file | `~/Library/Caches/Parola/bridge.port` | written at app launch |
| Auth token | `~/Library/Caches/Parola/bridge.token` | written at app launch, `0600` |
| Discovery record | `~/Library/Caches/Parola/bridge.json` | port, token, pid, startedAt, serverVersion |
| Wire-up | `.mcp.json` at repo root | committed |

## How it talks

The bridge listens on TCP loopback. On startup it asks the kernel for any free port, writes that port to `~/Library/Caches/Parola/bridge.port`, and starts accepting connections.

`BridgeClient` reads the port file, opens a connection, writes one line of JSON, reads one line of JSON, and closes. One request per connection. No pooling, because there's nothing worth pooling.

Request:

```json
{"id": "uuid", "version": 2, "cmd": "selectModel", "auth": "<token from bridge.token>", "args": {"name": "openai_whisper-tiny"}}
```

Response (success):

```json
{"id": "uuid", "ok": true, "command": "selectModel", "result": {...}, "serverVersion": 2, "elapsedMs": 12}
```

Response (failure):

```json
{"id": "uuid", "ok": false, "command": "selectModel", "error": {"code": "INVALID_ARGS", "message": "missing 'name'", "details": {}}, "serverVersion": 2, "elapsedMs": 3}
```

Every dispatch hops to `@MainActor` before touching `AppModel`, so the bridge is safe to call from any queue.

The tools advertised over MCP are the typed `parola_*` set plus `parola_app_dispatch`. The `parola_app_*` names below stay callable but are no longer listed in `tools/list` — new integrations should reach for the typed tools or the `parola_app_dispatch` fallback.

## Tool reference

Every `parola_app_*` tool fails with a clean error when the bridge isn't reachable. Required arguments are bold.

| Tool | Args | What it does |
|---|---|---|
| `parola_app_ping` | — | Returns `{pong: true}`. Use to confirm the bridge is up. |
| `parola_app_state` | — | Full state snapshot: phase, route, selectedModel, language, libraryFilter, libraryOrigin, appTheme, availableModels, transcript presence, and `introduction` (`{visible, step, steps, engine, engineChoices}`). While transcribing, `phaseDetail` also carries `progress`, `stage` and `hasPartialText`. |
| `parola_app_select_model` | **name** | Set selectedModel to a catalog id. |
| `parola_app_set_language` | code | Two-letter language code, or empty string to auto-detect. |
| `parola_app_set_theme` | **theme** | `light` / `dark` / `system`. |
| `parola_app_set_route` | **route** | `transcript` / `batch` / `queue` / `statistics` / `recentlyDeleted`. |
| `openRecentlyDeleted` | — | Route the main window to the Recently Deleted page. Replies `{open, route}`. |
| `closeRecentlyDeleted` | — | Leave that page for Home. Replies `{open, route}`. |
| `goBack` | — | Follow the transcript header's back link: unload the transcript and restore the list it was opened from. Replies `{origin, route, libraryFilter, libraryBrowsingAll}`. |
| `parola_app_set_library_filter` | category | `transcription` / `meeting` / `dictation`, `all` for the sidebar's All row, or empty for Home. Clears any search and unloads the transcript, like clicking the row. |
| `parola_app_transcribe_youtube` | **url** | Paste a YouTube URL and start the download-then-transcribe flow. Replies `{started, parked}`: a link handed over during a recording or another run comes back `parked: true` and waits for that work to finish. |
| `parola_app_fetch_youtube_subs` | **url** | Same input, but fetch existing captions instead of running Whisper. Replies `{started, parked}` on the same terms. |
| `parola_app_start_recording` | source, category | Start mic (default) or systemAudio. Category tags the saved entry. |
| `parola_app_stop_recording` | — | Stop the active recording and finalize the transcript. |
| `parola_app_set_translate` | **on** | Toggle translate-to-English. |
| `parola_app_set_use_streaming` | **on** | Toggle the live-mic streaming path. |
| `parola_app_toggle_live_captions` | — | Show or hide the Live Captions overlay. |
| `parola_app_wait_for_phase` | **phase**, timeoutMs | Poll until phase matches or timeout fires. Returns `{matched, state}`. |
| `parola_app_get_transcript` | — | Text + language + modelName + segment count + duration. Null if none loaded. |
| `parola_app_clear_transcript` | — | Drop the in-memory transcript. |
| `parola_app_list_entries` | category, limit | Library entries with id, title, category, createdAt, durationSeconds, language. |
| `parola_app_load_entry` | **id** | Open a library entry by id. |
| `parola_app_delete_entry` | **id** | Move an entry to Recently Deleted. |
| `parola_app_download_model` | **name** | Trigger a download from inside the app. Progress shows in the UI. |
| `parola_app_delete_model` | **name** | Delete a downloaded model. |
| `parola_app_export_transcript` | **format** | txt / md / html / docx / pdf / csv / srt / vtt / json. The app's save panel handles the destination. |
| `exportDiagnostics` | — | Render the diagnostics report and write it to the save destination. Returns `{path}`. In test mode, queue the destination with `queueSaveDestination` first. A dismissed panel is `PRECONDITION`; a failed write is `INTERNAL`. |
| `parola_app_dismiss_error` | — | Clear a failed phase (equivalent to clicking "Try again"). |
| `parola_app_screenshot` | path | Capture the main window to PNG via ScreenCaptureKit (needs Screen Recording permission). `path` is a bare filename stored under `Caches/Parola/Screenshots`. |
| `parola_app_list_windows` | — | Visible NSWindows: title, size, key/main flags. |
| `toggleInspector` | — | Toggle the transcript inspector, the same way ⌘⇧I does. Below ~1050 pt of window the pane folds the inspector away, and this is the only way to bring it back. |
| `setWindowFrame` | x, y, w, h | Move and resize the main window; the reply carries the frame that landed after the window's minimum size clamped it. AX resize is refused on ad-hoc-signed builds, so layout checks go through here. |
| `showIntroduction` | — | Restart the first-run introduction, the way Help ▸ Show Introduction does. Works in test mode too, even without `--show-introduction`. |
| `introductionNext` | — | Move on to the next introduction scene; stops on the last one. On the engine scene it commits the chosen engine first, the way the Continue pill does. |
| `introductionBack` | — | Move back a scene; stops on the first one. |
| `introductionSkip` | — | Leave the introduction and mark it seen. There is no separate finish command: this is also how the last scene ends. |
| `introductionChooseEngine` | **id** | Pick one of the engine cards; the id comes from `engineChoices`. Nothing downloads until the introduction moves on. |

The five introduction commands and `getState.introduction` all reply `{visible, step, steps, engine, engineChoices}`.
`visible` says whether the introduction is on screen; `step` is the scene showing now and `steps` the order this
deployment walks, drawn from `hello`, `transcribe`, `features`, `engine`, `ready`. The `engine` step is present
only when `engineChoices` is non-empty; otherwise it is left out of `steps` and the reply's `engine` field is
`null`. `engine` is the ringed card: an explicit `introductionChooseEngine`, or the app's current model when
that is one of `engineChoices` and nothing has been clicked yet — never a fallback to the first choice, since
Continue only ever commits an explicit pick. `engineChoices` lists the ids the engine scene offers.
`setSetting introductionComplete false` brings a finished introduction back once `showIntroduction` has run at least once this session (it lifts the test-mode suppression for the rest of the process); before that, the flag changes but nothing appears.

Rows named without the `parola_app_` prefix are raw bridge commands, called through `parola_app_dispatch`.

### Settings + library

| Tool | Args | What it does |
|---|---|---|
| `parola_app_get_settings` | — | All UserDefaults-backed settings: theme, model, language, streaming, diarize, wordTimestamps, dictation, sidebar density, batch export prefs, meeting detector. |
| `parola_app_set_setting` | **key**, value | Generic UserDefaults setter. Bypasses `@AppStorage`'s outside-of-View flakiness by writing directly + nudging `objectWillChange`. |
| `parola_app_open_settings` | — | Open the Settings window via the standard `showSettingsWindow:` selector. |
| `parola_app_close_settings` | — | Close any open Settings window. |
| `parola_app_search` | **query**, limit | Full-text search across the library; polls until the 200 ms debounce settles. |
| `parola_app_list_deleted_entries` | limit | Recently Deleted entries with id, title, category, deletedAt. |
| `selectDeletedEntries` | ids | Select rows on the Recently Deleted page, the way a click would; omit `ids` to clear. Ids the page isn't showing are ignored. Replies `{selected, ids}`. |
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
| `dropFiles` | **paths**, half | Routes files through the split drop zone: `now` transcribes, `queue` enqueues. |
| `previewDropZone` | payload, count, half | Test mode only: shapes the drop overlay without a drag so it can be captured. |
| `parola_app_clear_batch` | — | Cancel and remove all queued jobs. |
| `parola_app_select_batch_job` | **id** | Select a specific job to view its transcript. |
| `parola_app_get_batch_jobs` | — | All jobs: id, file, status (pending/transcribing/done/failed/cancelled), progress, error. |
| `parola_app_summarize_latest_entry` | — | Run the on-device summarizer against the most recent library entry. |
| `parola_app_reveal_cache_directory` | — | Open Finder showing the model cache directory. |

## Workflow

1. Run a Debug build of Parola.app (Xcode → Run, or `open` the binary in `~/Library/Developer/Xcode/DerivedData/.../Parola.app`). Look for `[ParolaAutomationServer] listening on 127.0.0.1:<port>` in stderr.
2. Claude Code picks up the server from `.mcp.json` on the next session. For ad-hoc testing, run `parola-mcp` directly over stdio.
3. Call `parola_app_dispatch` with `{ "command": "ping" }` first. If it returns `pong`, the rest works.

`scripts/scenarios.sh` drives the same bridge without a build of your own. It builds the app, launches it against a throwaway library, defaults domain and home directory under `/tmp`, runs `ScenarioTests` against that instance, and kills only the process it launched — a Parola you already have open is left alone, and the scenarios never see your real library. Add `--keep` after the mode to leave the sandbox behind; the script prints where it is. `--mock` also gets a throwaway models folder and downloads nothing. `--real` drives the live pipeline, so it reads the models folder you already use: nothing there is deleted, but a missing tiny model is downloaded into it. Its library, defaults suite and home are isolated like every other run's.

End-to-end example. Transcribe a YouTube URL and read the result back:

```text
parola_select_model       { "name": "openai_whisper-large-v3_turbo" }
parola_app_dispatch       { "command": "setLanguage", "args": { "code": "" } }   # auto-detect
parola_transcribe_youtube { "url": "https://www.youtube.com/watch?v=..." }
parola_wait_for_phase     { "phase": "ready", "timeoutMs": 120000 }
parola_app_dispatch       { "command": "getTranscript" }
```

## Adding a new command

1. Add an `AutomationCommand` to the matching list in `ParolaApp/ParolaApp/Bridge/Commands/` (name, area, `kind` — `.mutating` bumps the revision counter — declared args, handler). Declared args are validated before the handler runs.
2. That's enough: the command is callable through `parola_app_dispatch` and shows up in `_handshake`.
3. If it's common enough to deserve a listed schema, promote it with a `TypedTool` entry in `TypedToolRegistry.swift`.

If validation or the handler throws, the MCP client surfaces the structured error as an `isError` content block.

## Why not Accessibility or XCUITest

AX scripting needs Accessibility permission and breaks when SwiftUI rearranges views. The bridge reads the same `AppModel` the views read from, so identifier drift doesn't matter.

XCUITest spins up a fresh app each run. The bridge talks to the live process, which is useful when reproducing a bug that needed manual setup.

For CI-friendly regression coverage, XCUITest is the right layer. For "Claude, try this thing while I watch," the bridge is.

## Caveats

The bridge ships in Release too, but stays off unless `automationBridgeEnabled` is set — it defaults on in Debug and off in Release, so notarised binaries aren't remote-controlled out of the box.

TCP loopback is bound with `acceptLocalOnly = true`. Anyone on this machine could connect to it. If you don't trust your local user, don't run Debug builds with the bridge.

The bridge holds a weak reference to `AppModel`. When the app quits, the listener stops and the port file goes stale. `BridgeClient` reads the file fresh on every call, so it picks up a relaunched app on a new port without any restart on the MCP side.
