# Managed deployment

Parola reads deployment policy from the standard managed-app configuration
dictionary: the `com.apple.configuration.managed` key in the app's defaults
domain (`app.parola.ParolaApp`). Push it with MDM, or write it directly on a
Mac without MDM:

```sh
defaults write app.parola.ParolaApp com.apple.configuration.managed \
  '{ enabledFeatures = (dictation, ai); }'
```

Configuration is read at launch; relaunch the app to apply changes. The
`parola` CLI and the `parola-mcp` server read the same domain, so one dict
governs every frontend.

## Keys

| Key | Type | Effect |
|---|---|---|
| `enabledFeatures` | array of strings | Allowlist of feature units. Absent: everything on. Present: exactly the listed units run — their UI disappears, their subsystems never start, and the CLI, App Intents, URL scheme, and MCP bridge refuse them. Unknown names are ignored. Empty array: all ten units off; file transcription, library, export, search, and settings still work. |
| `defaultModel` | string | Model id selected at first launch. |
| `allowedEngines` | array of strings | Restricts transcription engines and the model catalog. |
| `disableDictation` | bool | Legacy switch for the `dictation` unit. |
| `disableYouTubeIngestion` | bool | Legacy switch for the `youtube` unit. |
| `disableDestinations` | bool | Switch for the `destinations` unit (Send To). |
| `disableCloudLLM` | bool | Blocks cloud LLM providers; on-device AI keeps working. |
| `disableModelDownloads` | bool | Blocks new model downloads. |
| `requireEnglishOnly` | bool | Forces English transcription. |

Legacy booleans intersect with `enabledFeatures`; the most restrictive
combination wins.

## Feature units

`dictation`, `meetings`, `micRecording`, `liveCaptions`, `youtube`, `batch`,
`ai`, `automation`, `watchedFolders`, `destinations`.

A dictation-only deployment:

```sh
defaults write app.parola.ParolaApp com.apple.configuration.managed \
  '{ enabledFeatures = (dictation); }'
```

Remove the policy:

```sh
defaults delete app.parola.ParolaApp com.apple.configuration.managed
```

When any managed key is set, the About window shows a note that features are
managed by the deployment. Without MDM the dict is plain defaults, so a user
with terminal access can undo it; the lock is against the UI, not a
determined administrator.
