# MCP server

Parola ships a Model Context Protocol server, so Claude or any other MCP
client can transcribe files and drive the running app.

The transport is line-delimited JSON-RPC 2.0 over stdin and stdout. Start it
with:

```sh
parola mcp
```

`parola-mcp` is a separate binary that runs the same server. It exists for
client configs written before the subcommand landed; new setups should use
`parola mcp`.

The release app bundles both binaries at `Parola.app/Contents/MacOS/`. To
build them from source instead:

```sh
cd ParolaCore
swift build          # .build/debug/parola, .build/debug/parola-mcp
```

## Setup

### Claude Code

```sh
claude mcp add parola -- /Applications/Parola.app/Contents/MacOS/parola mcp
```

If `parola` is on your `PATH` (for example a source build you symlinked), a
bare `parola mcp` works too:

```sh
claude mcp add parola -- parola mcp
```

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "parola": {
      "command": "/Applications/Parola.app/Contents/MacOS/parola",
      "args": ["mcp"]
    }
  }
}
```

The path must be absolute. A GUI app doesn't inherit the `PATH` from your
shell, so a bare `parola` won't resolve. Restart Claude Desktop after saving.

### Other clients

Any MCP-capable client works the same way: run `parola mcp` as a stdio server.
The server negotiates protocol versions `2024-11-05`, `2025-03-26`, and
`2025-06-18`, and answers `initialize`, `tools/list`, `tools/call`, `ping`, and
`shutdown`.

## Tools

Two groups. Engine tools run in the server process and need nothing else
installed. App tools talk to a running Parola.app over a local bridge.

### Engine tools

| Tool | What it does |
|---|---|
| `parola_transcribe` | Transcribe an audio or video file on device. See the reference below. |
| `parola_list_models` | The model catalog by category, with `[x]` on the installed ones. |
| `parola_list_engines` | Registered engines and whether each supports `translate` and `prompt`. |
| `parola_search_library` | Full-text search over stored transcripts. Returns entry ids with a score, the time of the first hit in the recording (absent for a title-only match) and a snippet. Args: `query`, `limit`. |
| `parola_list_recent` | Titles of the most recent stored transcripts. Arg: `limit`. |
| `parola_library_stats` | What the library adds up to: transcripts, audio, words, time spent transcribing, coverage, and a per-model table with each model's speed. Entries in Recently Deleted are left out. No arguments. |
| `parola_summarize` | Transcribe a file, then summarise it with the on-device LLM. Arg: `path`. |
| `parola_open_app` | Launch Parola.app and wait for its bridge. Args: `timeoutMs`, `bundleID`. |

### App tools

`parola_select_model`, `parola_transcribe_file`, `parola_transcribe_youtube`,
`parola_load_entry`, `parola_start_batch`, `parola_add_batch_files`,
`parola_run_prompt`, `parola_get_state`, `parola_get_state_revision`,
`parola_get_accessibility_tree`, `parola_screenshot`, `parola_wait_for_phase`,
`parola_wait_for_batch_job`, `parola_wait_for_revision`,
`parola_start_dictation`, `parola_stop_dictation`, `parola_export_transcript`,
`parola_open_settings`, `parola_reset_test_state`.

`parola_app_dispatch` forwards any bridge command that has no typed tool. Call
it with `{"command": "_handshake"}` for the full catalog.

These fail with a clean error when the app isn't running. Call
`parola_open_app` first; it launches the app and blocks until the bridge
answers. The wire protocol and the bridge's own gating live in
[test-bridge.md](test-bridge.md).

## parola_transcribe

| Argument | Type | Meaning |
|---|---|---|
| `path` | string, required | Absolute path to the audio or video file. |
| `model` | string | Variant id from `parola_list_models`. Defaults to the recommended model. |
| `language` | string | Two-letter code (`en`, `it`, …). Omit to auto-detect. |
| `format` | string | `txt` (default), `md`, `srt`, `vtt`, `json`. |
| `translate` | bool | Translate the speech to English instead of writing down what was said. Only engines whose `parola_list_engines` row reads `translate=true` accept it. |
| `initial_prompt` | string | Words or proper nouns to bias decoding toward. Whisper truncates it internally to about 111 tokens, so keep it short. |
| `output_path` | string | Absolute path to write the transcript to. Missing parent directories are created, and an existing file there is overwritten. A path nothing can be written to is refused before the audio is touched. |
| `save` | bool | Also store the transcript in Parola's library. The entry keeps a copy of the source file. |
| `skip_duplicates` | bool | Return the existing entry's details instead of transcribing when the library already holds this exact file. Off by default. |

An example call:

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "parola_transcribe",
    "arguments": {
      "path": "/Users/you/Recordings/standup.m4a",
      "model": "openai_whisper-large-v3_turbo",
      "language": "en",
      "format": "srt",
      "output_path": "/Users/you/Recordings/standup.srt",
      "initial_prompt": "Parola, WhisperKit, Parakeet"
    }
  }
}
```

Without `output_path` the result is the whole transcript in the chosen format.
With it, the file is written and the result carries a short report instead:

```
Wrote srt to /Users/you/Recordings/standup.srt
42 segments, 00:07:31

Preview:
1
00:00:00,000 --> 00:00:04,120
Morning, everyone.
```

The preview stops at 500 characters. A two-hour recording stays out of the
client's context that way. A file with no speech in it reports that instead of
a preview.

An existing file at `output_path` is replaced. Nothing warns first, so don't
point a run at a transcript someone has edited by hand. If the write fails
anyway — the disk filled, the folder went away — the transcript comes back in
the result with the failure next to it, rather than being lost.

Parola knows a file by the SHA-256 of its bytes, so a call on a recording the
library already holds gets an extra text block saying which entry it is and when
it was made. The run still happens; `skip_duplicates: true` returns that block on
its own and transcribes nothing.

`save` adds a second text block naming the library entry, which
`parola_search_library` and `parola_list_recent` can then find. The entry keeps
a copy of the source audio or video, so saving a 2 GB recording puts another
2 GB in the library. A failed save is reported in that block rather than
failing the call — the transcript itself is still returned.

Every result also carries a block saying what the run cost:

```
Transcribed in 37 s (16× real time)
transcription_seconds: 37.00
speed_factor: 16.00
```

The two keys are always `%.2f` with a `.` decimal separator, whatever the
machine's locale. The block is absent when the run did not go through a file
transcription, and `speed_factor` is absent when the media duration is unknown,
so a parser has to treat both as optional.

## Progress notifications

Transcription is slow enough that a client should show progress. The client
opts in per call by putting a token in `_meta`:

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "parola_transcribe",
    "arguments": { "path": "/Users/you/Recordings/standup.m4a" },
    "_meta": { "progressToken": 4 }
  }
}
```

The server then writes `notifications/progress` messages while the call runs,
echoing the token verbatim:

```json
{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":4,"progress":37,"total":100,"message":"Transcribing with openai_whisper-large-v3_turbo"}}
```

`progress` is a percent on a 0–100 scale and rises strictly. `message` names
the current stage: `Downloading <model>`, `Preparing audio`, or
`Transcribing with <model>`. When the run has to fetch a model first, that
download takes the leading 30 points and the numbers keep climbing into the
transcription.

Every notification for a call is written before that call's response. A call
with no token gets no notifications. A cancelled call stops producing them.

Progress matters most on a call that has to fetch a Whisper or Parakeet model
first: that download runs for minutes on a large variant, and used to look like
the server had hung. Apple Speech, the default on macOS 26, is the exception.
Its locale assets are installed by the system, which reports nothing back, so
the first call with it sits at `Preparing audio` until they land — and
`parola_list_models` marks it `[x]` either way.

## Troubleshooting

**The first call takes forever.** It's fetching a model. With a Whisper or
Parakeet variant a `progressToken` shows the download climbing;
`parola_list_models` marks installed variants with `[x]` and anything else gets
fetched on demand. With Apple Speech there's nothing to show: macOS installs
its locale assets itself and reports no progress, and the row reads `[x]`
whether or not they're on disk.

**`parola mcp` isn't in `parola --help`.** The subcommand is gated on the
`automation` feature unit. A managed config whose `enabledFeatures` omits
`automation` hides it. See [deployment.md](deployment.md).

**`parola_summarize` answers "AI is disabled in this deployment."** Same
mechanism: `enabledFeatures` doesn't list `ai`. Every other tool keeps working.

**App tools say the bridge is unreachable.** Call `parola_open_app`. If it
still fails, the app is running with the automation bridge switched off —
[test-bridge.md](test-bridge.md) covers the setting.

**The client shows no tools at all.** Run the server by hand and look at
stderr; it logs `parola-mcp listening on stdio` on startup. A crash on launch
usually means the binary path in the client config is stale.

**A call failed and stderr didn't say why.** The server records diagnostics
while it runs. `parola diagnostics` writes them out as a plain-text report —
structural facts only, no transcript text or paths — and prints its path;
`parola diagnostics --clear` deletes what was recorded, sparing a file a live process is still writing.
