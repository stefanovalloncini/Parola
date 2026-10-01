# Test bridge

A setting-gated local IPC that lets the `parola-mcp` server drive a running Parola.app. Built so Claude (or any MCP client) can change models, paste URLs, start recordings, and read state without anyone touching the GUI.

## What ships

| Piece | Path | Build configuration |
|---|---|---|
| In-app listener | `ParolaApp/ParolaApp/Bridge/ParolaAutomationServer.swift` | Ships in Debug and Release, gated by the `automationBridgeEnabled` setting (default on in Debug, off in Release) |
| MCP client | `ParolaCore/Sources/ParolaMCP/BridgeClient.swift` | always |
| MCP tool surface | `ParolaCore/Sources/ParolaMCP/` (`TypedToolRegistry.swift` + `LegacyAppTools.swift`) | always |
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

The tools advertised over MCP are the typed `parola_*` set plus `parola_app_dispatch`. The `parola_app_*` names below stay callable but are no longer listed in `tools/list` — new integrations should reach for the typed tools or the `parola_app_dispatch` fallback. A `parola_app_*` name runs the typed tool for the same command when there is one, and otherwise sends its command with the arguments given, as `parola_app_dispatch` does.

## Tool reference

Every `parola_app_*` tool fails with a clean error when the bridge isn't reachable. Required arguments are bold.

| Tool | Args | What it does |
|---|---|---|
| `parola_app_ping` | — | Returns `{pong: true}`. Use to confirm the bridge is up. |
| `parola_app_state` | — | Full state snapshot: phase, route, selectedModel, language, libraryFilter, libraryOrigin, appTheme, availableModels, transcript presence, and `introduction` (`{visible, step, steps, engine, engineChoices}`). `openEntryWindows` lists the entry ids open in their own transcript windows, and `openEntriesInNewWindow` says whether a double-click routes there. While transcribing, `phaseDetail` also carries `progress`, `stage` and `hasPartialText`. |
| `parola_app_select_model` | **name** | Set selectedModel to a catalog id. |
| `parola_app_set_language` | code | Two-letter language code, or empty string to auto-detect. |
| `parola_app_set_theme` | **theme** | `light` / `dark` / `system`. |
| `parola_app_set_route` | **route** | `transcript` / `batch` / `queue` / `statistics` / `recentlyDeleted` / `recording`. Takes the page the way the app's own controls do: clears any search and the category filter. `recording` is the take's Stage and needs a take that hasn't landed yet (`getState.recording` set, its `state` not `done`); otherwise it is `PRECONDITION`. |
| `openRecentlyDeleted` | — | Route the main window to the Recently Deleted page. Replies `{open, route}`. |
| `closeRecentlyDeleted` | — | Leave that page for the Library page. Replies `{open, route}`. |
| `goHome` | — | Show the Library page, with any filters set on it: clear the category and person filters and any search, and unload the transcript. Replies `{route}` once the list is back. |
| `goBack` | — | Follow the transcript header's back link: unload the transcript and restore the list it was opened from. Replies `{origin, route, libraryFilter, libraryBrowsingAll}` once that list is back. |
| `parola_app_set_library_filter` | category | `transcription` / `meeting` / `dictation`, or `all` or empty for the whole Library page. Clears any search and unloads the transcript, like clicking the row. |
| `parola_app_transcribe_youtube` | **url** | Paste a YouTube URL and start the download-then-transcribe flow. Replies `{started, parked}`: a link handed over during a recording or another run comes back `parked: true` and waits for that work to finish. |
| `parola_app_fetch_youtube_subs` | **url** | Same input, but fetch existing captions instead of running Whisper. Replies `{started, parked}` on the same terms. |
| `parola_app_start_recording` | source, category | Start mic (default) or systemAudio. Category tags the saved entry. |
| `parola_app_stop_recording` | — | Stop the active recording and finalize the transcript. |
| `pauseRecording` | — | Test mode: pause the take that is recording, the way the Stage's Pause does. Replies `{paused, recording}`; `paused` is false when no take is recording. |
| `resumeRecording` | — | Test mode: resume a paused take. Replies `{resumed, recording}`. |
| `addRecordingMarker` | — | Test mode: mark this moment of the take, the way ⌘B on the Stage does. Replies `{marker, recording}`; `marker` is the take's time in seconds, or `null` while nothing records or when the last mark is under a second old. |
| `feedTakeLevels` | **fixturePath** | Test mode: play a WAV fixture's loudness into the running take's level meter, in real time, until that take's meter goes away. For a take whose capture meters nothing, like a streaming take on `installMockStreamingTranscriber`, so its Stage band and silence warning behave as they would with a microphone. Replies `{feeding}`; `PRECONDITION` while no take meters. |
| `discardRecording` | — | Test mode: the Stage's confirmed Discard. The take's audio and checkpoint are deleted and nothing is saved; a take still arming ends the way Cancel ends it, and a stopped take is left alone. Replies `{discarded, recording}`. |
| `parola_app_set_translate` | **on** | Toggle translate-to-English. |
| `parola_app_set_use_streaming` | **on** | Toggle the live-mic streaming path. |
| `parola_app_toggle_live_captions` | — | Show or hide the Live Captions overlay. |
| `parola_app_wait_for_phase` | **phase**, timeoutMs | Poll until phase matches or timeout fires. Returns `{matched, state}`. |
| `waitForRecordingState` | **state**, timeoutMs | Poll until the take's session reaches `state` (`arming`, `recording`, `paused`, `finishing`, `transcribing`, `done`, `failed`, or `none` for no take) or the timeout fires. Replies `{matched, observed}`, plus `recording` as `getState.recording` shows it once matched. |
| `parola_app_get_transcript` | — | Text + language + modelName + segment count + duration. Null if none loaded. |
| `parola_app_clear_transcript` | — | Drop the in-memory transcript. |
| `parola_app_list_entries` | category, limit | Library entries with id, title (as stored), displayTitle (what the rows show), category, createdAt, durationSeconds, language. |
| `parola_app_load_entry` | **id** | Open a library entry by id — into the main pane, or into its own window when `openEntriesInNewWindow` is on. |
| `openEntryInNewWindow` | **entryID** | Open a library entry in its own read-only transcript window, the way ⇧⌘N and the row's context menu do. The window is titled after the entry. Replies `{opened, reason, openEntryWindows}`; `opened: false` when the library has no such entry or no window scene is ready yet. |
| `retranscribeEntry` | **entryID**, model, language | Run that entry's own audio again into the same entry, the way the Info inspector's Model and Language menus do. It opens the entry first if it isn't the one showing. Omitted arguments keep what the entry carries; `language: ""` means Auto. The entry keeps its id, title, labels, category and date; its favorites, notes, summary, translation, speaker map and card metadata are replaced. Replies `{entryID, model, language}`; `PRECONDITION` for an entry with no audio or while another re-run is going. |
| `parola_app_delete_entry` | **id** | Move an entry to Recently Deleted. |
| `parola_app_download_model` | **name** | Trigger a download from inside the app. Progress shows in the UI. |
| `parola_app_delete_model` | **name** | Delete a downloaded model. |
| `copyModelDetails` | — | Put the selected model's details on the pasteboard, the way Help ▸ Copy Model Details does: name, identifier, engine, catalog source, install state, path, size on disk and language coverage. Replies `{text}` with the same block. |
| `parola_app_export_transcript` | **format** | txt / md / html / docx / pdf / csv / srt / vtt / json. The app's save panel handles the destination. |
| `openExportSheet` | — | Open the Export sheet on the loaded transcript. Replies `{open, spec}`; `PRECONDITION` when nothing is loaded. |
| `setExportSpec` | **spec** | Merge fields over the sheet's spec (`options` merges field by field, so `{"options":{"timestamps":true}}` keeps the rest). Naming `format` moves the spec to that format's style; naming `style` alone picks that style's first format. Replies `{spec}`. |
| `exportWithSpec` | **spec**, **path** | Write the loaded transcript straight to `path` with that spec — no save panel. Replies `{path, format}`. |
| `setExportPresets` | **presets** | Replace the saved export presets with an array of `ExportPreset` objects. Built-ins are kept and re-stamped. Replies `{exportPresets}`. |
| `sendEntry` | **entryID**, **destinationID** | Send a library entry to one Send To destination. Replies `{outcome}`: `delivered` carries `destinationName` and the note `path`, `queued` the `attempt` and `nextAt`, `skipped` the `reason`. |
| `listDeliveries` | **entryID** | The delivery receipts stored in that entry's manifest (`destinationID`, `destinationName`, `deliveredAt`, `location`). |
| `setDestinations` | **destinations** | Replace the Send To list with an array of `{kind, config}` envelopes. In test mode a config may carry `vaultPath` instead of `vaultBookmark` and the app makes the bookmark for it. Replies `{destinations}`. |
| `setAIServices` | **services** | Replace the configured AI services with an array of `{id, kind, name, endpoint, model}` rows (`kind` is `openAI`, `anthropic`, `groq`, `cerebras`, `ollama` or `custom`). In test mode a row may carry an `apiKey`, which goes to the in-memory key store. Replies `{aiServices}` — the key is never echoed. |
| `setLanguageModelSelection` | **selection** | Replace the per-task model selection: `{"choices": {"summary": {"kind": "ollama", "endpoint": "http://127.0.0.1:11434", "model": "llama3.2:3b"}}}`. Tasks are `summary`, `chat`, `prompts`, `dictationCleanup`; a kind this build doesn't know reads as on device. Replies `{languageModelSelection}`. |
| `assignSpeaker` | **speakerLabel**, **personName** | Assign a speaker label in the open transcript to a person, creating them when the name is new. Every segment (and word) carrying the label takes the person's name. Replies `{speakerLabel, person, speakerAssignments}`. A blank name, a label the transcript doesn't carry, or no open transcript is refused. |
| `listPeople` | — | The people directory (`id`, `name`, `usageCount`, `colorIndex`), most used first. |
| `setPersonFilter` | personID | Filter the library list to one person, the way a PEOPLE sidebar row does; omit the id or pass null to clear it. Replies `{personFilter, entryCount}`. |
| `testAIService` | **id** | Ask one configured service a one-line question, with a 20 s ceiling. Replies `{ok, message, ms}`: `message` is the reply, or the error when `ok` is false. |
| `installMockDestination` | name, autoSend, categories, failuresBeforeSuccess | Test mode: add a destination that records what it is handed and writes nothing. Replies `{installed, destinationID}`. |
| `readMockDeliveries` | — | Test mode: `{deliveries, receipts}` — what the mock destinations were handed (`entryID`, `title`, `category`, `segmentCount`, `markdownBytes`, `favorites`) and the receipts they gave back. |
| `exportDiagnostics` | — | Render the diagnostics report and write it to the save destination. Returns `{path}`. In test mode, queue the destination with `queueSaveDestination` first. A dismissed panel is `PRECONDITION`; a failed write is `INTERNAL`. |
| `parola_app_dismiss_error` | — | Clear a failed phase (equivalent to clicking "Try again"). |
| `parola_app_screenshot` | path | Capture the main window to PNG via ScreenCaptureKit (needs Screen Recording permission). `path` is a bare filename stored under `Caches/Parola/Screenshots`. |
| `parola_app_list_windows` | — | Visible NSWindows: title, size, key/main flags. A transcript window carries the entry's title, so a driver can find it. |
| `translateTranscript` | **language** | Translate the loaded transcript into that language code and store the result. Uses whichever translator is installed (`installMockTranslator` in test mode). Replies `{translated, targetLanguage, segmentCount, provider}`, or `{translated: false, reason}` when the run failed or was refused. |
| `removeTranslation` | — | Drop the loaded transcript's translation. Replies `{removed}`. |
| `installMockTranslator` | **mode**, map, delayMs | Test mode: install a translator that never touches the Translation framework. `mode` is `reverseWords` or `map`; `map` is source text → translated text for the `map` mode; `delayMs` holds each batch. Replies `{installed, mode, mapCount, delayMs}`. Clear it with `clearMocks` scope `translator`. |
| `setSegmentFavorite` | **segmentID**, **isFavorite** | Star or unstar one segment of the loaded transcript, the way the card's star does. Replies `{applied, segmentID, isFavorite}`, or `{applied: false, reason}` when no entry is selected. Unstarring the last favorite also turns the Favorites-only filter off. |
| `setTranscriptPaneMode` | **mode** | Switch the transcript column between `transcript`, `summary` and `chat`, the way ⌘1/2/3 do. A mode the transcript or the AI feature can't support is ignored. Replies `{mode}` with the mode that landed. |
| `setSummaryOptions` | **options** | Merge fields over the saved summary options and persist the result (`{"options": {"length": "short"}}`). Replies `{summaryOptions}`. |
| `generateCardMetadata` | **id**, force | Write the AI title and one-line summary for a library entry. Needs the AI feature, and the `generateCardMetadata` setting unless `force: true` — which is the Info inspector's Regenerate, the one path that ignores the toggle. Replies `{generated, aiTitle, shortSummary}`, or `{generated: false, reason}`. |
| `toggleInspector` | — | Toggle the transcript inspector, the same way ⌘⇧I does. Below ~1050 pt of window the pane folds the inspector away, and this is the only way to bring it back. |
| `setWindowFrame` | x, y, w, h | Move and resize the main window; the reply carries the frame that landed after the window's minimum size clamped it. AX resize is refused on ad-hoc-signed builds, so layout checks go through here. |
| `showIntroduction` | — | Restart the first-run introduction, the way Help ▸ Show Introduction does. Works in test mode too, even without `--show-introduction`. |
| `introductionNext` | — | Move on to the next introduction scene; stops on the last one. On the engine scene it commits the chosen engine first, the way the Continue pill does. |
| `introductionBack` | — | Move back a scene; stops on the first one. |
| `introductionSkip` | — | Leave the introduction and mark it seen. There is no separate finish command: this is also how the last scene ends. |
| `introductionChooseEngine` | **id** | Pick one of the engine cards; the id comes from `engineChoices`. Nothing downloads until the introduction moves on. |

The five introduction commands and `getState.introduction` all reply `{visible, step, steps, engine, engineChoices}`.

`getState.recording` is the take the window shows, from its count-in until the next take starts, or `null` when there is none:
`{state, elapsed, startedAt, paused, markers, title, category, source, isStreaming, device, progress, stage, hasPartialText}`.
`state` is one of `arming` / `recording` / `paused` / `finishing` / `transcribing` / `done` / `failed`; `elapsed` and
`markers` are seconds of the take; `startedAt` is seconds since 1970, `null` until the first audio; `device` names the
input a mic take listens on. While a file take transcribes, `progress` is its 0–1 fraction (`null` until the engine
reports one), and `stage` and `hasPartialText` mirror `phaseDetail`'s for its run; otherwise they read `null` and `false`.
`phase` reads `recording` whenever that take is arming, recording or paused. Neither its capture nor its transcription
moves the phase: a failure shows on its Stage as `recording.state` `failed` (and, when another page shows, as an
`exportNotice`), while `phase` stays on whatever the rest of the window shows, `ready` with an older transcript
included. Where a take lands is decided when its run ends, not at Stop: with its own Stage up it lands there and loads
its transcript; with another page, a newer take's Stage or no main window, it goes to the library with a toast and
loads nothing. To read a take back, keep its Stage up (`setRoute recording`), wait with `waitForRecordingState done`
(the transcript is loaded before the save marks the take done), then `getTranscript`. While a take captures, entries
open as usual, a file, link or batch handed over waits for it (a link replies `parked: true`), and `retranscribeEntry`
is `PRECONDITION`. While its run transcribes, links, drops and batches still wait behind it, but `transcribeFile` and
`retranscribeEntry` stop the run and save the take "(not transcribed)" with a notice, and `downloadModel` is
`PRECONDITION` whatever `phase` reads.

`getState.burn` is the subtitle burn running beside the phase, `{state, progress, output}` with `state` one of
`running` / `finished` / `failed` (a failed one adds `message`), or `null` when there is none.
`getState.exportPresets` carries the whole preset library (`{id, name, spec, isBuiltIn}` each) and
`getState.exportSpec` the sheet's current spec, or `null` while the sheet is shut.
`getState.translation` is `{targetLanguage, segmentCount, inProgress, provider}` for a translated transcript and
`null` otherwise. A run in flight wins over a translation already stored: it reports the target it is heading for,
`segmentCount` as the segments sent so far and `inProgress: true`, so a script can wait on a first translation.
`getState.translationSideBySide` is the two-column preference.
`getState.favoriteSegments` lists the starred segment ids of the open entry and `getState.favoritesOnly` says whether the transcript is filtered to them.
`getState.transcriptPaneMode` is which of `transcript` / `summary` / `chat` the column is showing.
`getState.summaryOptions` is the saved summary options as `setSummaryOptions` takes them, and `getState.autostartSummary` whether a finished transcription summarises itself.
`getState.aiServices` lists the configured AI services (`id`, `kind`, `name`, `model`, `endpoint`, `hasKey`) — the API key itself is never returned by any command, and never reaches the diagnostics export.
`getState.languageModelSelection` is the per-task selection as `setLanguageModelSelection` takes it, and `getState.remoteAIAcknowledged` says whether the one-time "transcripts leave this Mac" notice has been accepted (`setSetting remoteAIAcknowledged true` skips the sheet in a script).
`getState.people` is the people directory as `listPeople` returns it, `getState.speakerAssignments` the open entry's label → person id map (empty for a transcript that isn't in the library), `getState.personFilter` the person the library list is filtered to, and `getState.showMostUsedPeople` whether the PEOPLE sidebar section shows (`setSetting showMostUsedPeople false` hides it).
`getState.retranscribing` is true while a re-run started by `retranscribeEntry` or the Info inspector's menus is going; poll it to wait one out, since a second `retranscribeEntry` is refused until it settles.
`getState.appVisibilityMode` is where Parola shows itself — `dockAndMenuBar` (the default), `menuBarOnly` (no Dock icon, no ⌘-Tab) or `dockOnly` (no menu bar item); `setSetting appVisibilityMode menuBarOnly` applies it live, and `showMenuBarExtra` follows it rather than being set on its own.
`getState.playSoundWhenFinished` says whether a finished transcription rings the system Glass sound — once per single-file run, once per batch run, once per re-run, and never for an import.
`getState.destinations` lists the Send To destinations in order (`id`, `kind`, `name`, `isEnabled`, `autoSend`, `categories`); a
kind this build cannot run comes back with the kind it was stored as and `isEnabled: false`.
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
| `parola_app_get_settings` | — | All UserDefaults-backed settings: theme, model, language, streaming, diarize, wordTimestamps, dictation, meeting detector. |
| `parola_app_set_setting` | **key**, value | Generic UserDefaults setter. Bypasses `@AppStorage`'s outside-of-View flakiness by writing directly + nudging `objectWillChange`. |
| `parola_app_open_settings` | — | Open the Settings window via the standard `showSettingsWindow:` selector. |
| `parola_app_close_settings` | — | Close any open Settings window. |
| `parola_app_search` | **query**, limit | Full-text search across the library; polls until the 200 ms debounce settles. |
| `parola_app_list_deleted_entries` | limit | Recently Deleted entries with id, title, category, deletedAt. |
| `selectDeletedEntries` | ids | Select rows on the Recently Deleted page, the way a click would; omit `ids` to clear. Ids the page isn't showing are ignored. Replies `{selected, ids}`. |
| `getDuplicateImport` | — | The "Already in your library" sheet: whether it is open, the entry it matched, and how many files the last batch import skipped. |
| `resolveDuplicateImport` | **choice**, remember | Press `openExisting`, `transcribeAgain` or `dismiss`. `remember: true` ticks the sheet's checkbox first, so the choice becomes the `duplicateImportPolicy` setting (`alwaysAsk` / `transcribeAgain` / `openExisting`, also writable with `setSetting`). Replies `{choice, duplicateImportPolicy}`. |
| `parola_app_restore_entry` | **id** | Move an entry back from Recently Deleted. |
| `parola_app_purge_entry` | **id** | Permanently delete from Recently Deleted. |

### Prompts + batch + files

| Tool | Args | What it does |
|---|---|---|
| `parola_app_list_prompts` | — | Built-in + user prompts: Cleanup, Translate, Professional tone, Bullet points, Action items, plus any user-added. |
| `parola_app_run_prompt` | **name** or **id** | Run a prompt against the current transcript. Requires Apple Intelligence. |
| `parola_app_get_prompt_output` | — | Latest `{promptName, text}` or null. |
| `parola_app_transcribe_file` | **path**, translate | Drop-equivalent: transcribe a file by absolute path. |
| `parola_app_start_batch` | **paths** | Submit multiple files. Opens the Queue, unless a take is recording or its Stage is showing. |
| `parola_app_add_batch_files` | **paths** | Append more files to the existing batch. Opens the Queue, unless a take is recording or its Stage is showing. |
| `dropFiles` | **paths**, half, confirmLarge | Routes files through the split drop zone: `now` transcribes, `queue` enqueues. A drop yielding more than 200 files waits on a prompt: the reply's `awaitingConfirmation` says so, and `confirmLarge: true` answers Add Files. The reply's `route` is the page on screen after the drop: `queue` once the files join a batch (a take that is recording, or its Stage, keeps the page), `transcript` when a file starts on its own. |
| `resolveLargeDrop` | **choice** | Answers the large-drop prompt: `add` queues the files, `cancel` drops them. `getState.pendingLargeDropCount` shows what is waiting. |
| `previewDropZone` | payload, count, half | Test mode only: shapes the drop overlay without a drag so it can be captured. |
| `parola_app_clear_batch` | — | Cancel and remove all queued jobs. |
| `parola_app_select_batch_job` | **id** | Open a finished job's transcript, as its Open button does: its library entry, or its own copy while the save is in flight. Replies once the entry has loaded. |
| `parola_app_get_batch_jobs` | — | All jobs: id, file, status (pending/transcribing/done/failed/cancelled), progress, error. |
| `parola_app_summarize_latest_entry` | options | Run the on-device summarizer against the most recent library entry. `options` merges `SummaryOptions` fields over the saved ones for this run only. |
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
