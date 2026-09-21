import SwiftUI

enum SettingsPaneScope: String, CaseIterable, Identifiable {
    case general
    case customization
    case watchedFolders
    case recordMeetings
    case shortcuts
    case microphone
    case liveCaptions
    case dictation
    case snippets
    case corrections
    case translation
    case people
    case transcriptionDefaults
    case ignoredSegments
    case findReplace
    case exportFormats
    case batchExport
    case autoExport
    case sendTo
    case integrations
    case aiServices
    case prompts
    case automation
    case updates
    case advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .customization: return "Customization"
        case .watchedFolders: return "Watched Folders"
        case .recordMeetings: return "Record Meetings"
        case .shortcuts: return "Shortcuts"
        case .microphone: return "Microphone"
        case .liveCaptions: return "Live Captions"
        case .dictation: return "Dictation"
        case .snippets: return "Snippets"
        case .corrections: return "Corrections"
        case .translation: return "Translation"
        case .people: return "People"
        case .transcriptionDefaults: return "Transcription Defaults"
        case .ignoredSegments: return "Ignored Segments"
        case .findReplace: return "Find & Replace"
        case .exportFormats: return "Export Formats"
        case .batchExport: return "Batch Export"
        case .autoExport: return "Auto-Export"
        case .sendTo: return "Send To"
        case .integrations: return "Integrations"
        case .aiServices: return "AI Services"
        case .prompts: return "Prompts"
        case .automation: return "MCP & Automation"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        }
    }

    var localizedLabel: String {
        switch self {
        case .general: return String(localized: "General")
        case .customization: return String(localized: "Customization")
        case .watchedFolders: return String(localized: "Watched Folders")
        case .recordMeetings: return String(localized: "Record Meetings")
        case .shortcuts: return String(localized: "Shortcuts")
        case .microphone: return String(localized: "Microphone")
        case .liveCaptions: return String(localized: "Live Captions")
        case .dictation: return String(localized: "Dictation")
        case .snippets: return String(localized: "Snippets")
        case .corrections: return String(localized: "Corrections")
        case .translation: return String(localized: "Translation")
        case .people: return String(localized: "People")
        case .transcriptionDefaults: return String(localized: "Transcription Defaults")
        case .ignoredSegments: return String(localized: "Ignored Segments")
        case .findReplace: return String(localized: "Find & Replace")
        case .exportFormats: return String(localized: "Export Formats")
        case .batchExport: return String(localized: "Batch Export")
        case .autoExport: return String(localized: "Auto-Export")
        case .sendTo: return String(localized: "Send To")
        case .integrations: return String(localized: "Integrations")
        case .aiServices: return String(localized: "AI Services")
        case .prompts: return String(localized: "Prompts")
        case .automation: return String(localized: "MCP & Automation")
        case .updates: return String(localized: "Updates")
        case .advanced: return String(localized: "Advanced")
        }
    }

    /// Search keywords surfaced by the sidebar search beyond the label match.
    var searchKeywords: [String] {
        switch self {
        case .general: return ["karaoke", "highlight", "word timestamps", "streaming", "diarize", "speakers", "vocabulary", "prompt", "menu bar", "login", "launch", "startup", "title", "window", "new window"]
        case .customization: return ["appearance", "theme", "light", "dark", "density", "sidebar", "monospaced", "accent", "color", "terracotta", "custom colors", "palette"]
        case .watchedFolders: return ["watch", "folder", "auto", "drop"]
        case .recordMeetings: return ["zoom", "teams", "meet", "webex", "meeting", "detect", "system audio", "permission", "screen recording", "consent"]
        case .shortcuts: return ["hotkey", "key combo", "mic recording", "dictation key", "global", "keyboard"]
        case .microphone: return ["mic", "input device", "vu", "level", "preview", "count-in", "mute", "pause media", "music", "spotify", "auto-stop"]
        case .liveCaptions: return ["captions", "translate", "live"]
        case .dictation: return ["hotkey", "f5", "push to talk", "toggle", "indicator", "notch", "overlay", "cleanup", "workflows", "per-app", "hud", "opacity", "context", "clipboard", "screen", "ocr", "paste delay", "self-corrections", "url rule"]
        case .snippets: return ["snippet", "expand", "abbreviation", "trigger", "placeholder", "date", "time"]
        case .corrections: return ["correction", "fix", "replace", "dictation", "vocabulary"]
        case .translation: return ["translate", "english", "side by side", "language"]
        case .people: return ["people", "person", "speaker", "diarize", "identify speakers", "name", "colour", "color", "merge"]
        case .transcriptionDefaults: return ["default", "model", "language", "engine", "whisper", "privacy", "cloud", "llm", "speakers", "diarize", "word timestamps", "apple speech", "playback"]
        case .ignoredSegments: return ["filler", "uh", "um", "ignore", "skip"]
        case .findReplace: return ["regex", "replace", "term pack", "substitution", "rule"]
        case .exportFormats: return ["preset", "txt", "srt", "vtt", "csv", "tsv", "docx", "pdf", "markdown", "html", "json", "jsonl", "fcpxml", "final cut", "lrc", "lyrics", "subtitles"]
        case .batchExport: return ["batch", "multiple files", "drag drop", "queue", "sidecar", "folder", "preset"]
        case .autoExport: return ["auto export", "rule", "line length", "qc", "timestamps", "html theme", "preset"]
        case .sendTo: return ["obsidian", "vault", "send", "destination", "note", "markdown", "frontmatter", "wikilink"]
        case .integrations: return ["yt-dlp", "youtube", "homebrew", "install"]
        case .aiServices: return ["openai", "anthropic", "claude", "groq", "cerebras", "ollama", "local model", "api key", "endpoint", "llm", "summary", "chat", "cleanup", "apple intelligence"]
        case .prompts: return ["prompt", "cleanup", "translate", "bullet", "action", "trigger words", "assistant", "rewrite"]
        case .automation: return ["mcp", "bridge", "claude code", "codex", "loopback"]
        case .updates: return ["sparkle", "appcast", "channel", "auto-update"]
        case .advanced: return ["model storage", "cache", "reveal", "reset", "backup", "restore", "export settings", "import settings"]
        }
    }

    var defaultsKeys: [String] {
        switch self {
        case .general:
            return [
                "useStreaming", "wordTimestamps", "karaokeHighlight", "initialPrompt", "diarize",
                "showMenuBarExtra", "generateCardMetadata", "showAITitles", "showAISummaries",
                "customTitlePrompt", "customSummaryPrompt", "showSubtitleQC",
                "summaryOptions", "autostartSummary", "openEntriesInNewWindow"
            ]
        case .customization:
            return [
                "appTheme", "monospacedTimestamps", "sidebarDensity", "appAccentColor",
                "themeIsCustom", "themeCustomPaletteJSON"
            ]
        case .watchedFolders:
            return ["watchedFolders"]
        case .recordMeetings:
            return ["meetingDetectorEnabled", "meetingCaptureAppOnly"]
        case .shortcuts:
            // The dictation hotkey keys also live in the .dictation scope; both panes
            // show the recorder, and removeObject is idempotent across scopes.
            return [
                "micHotkeyEnabled", "micHotkeyKeyCode", "micHotkeyModifiers",
                "dictationKeyCode", "dictationKeyModifiers"
            ]
        case .microphone:
            return [
                "inputDeviceUID",
                "recordingMaxMinutes", "recordingCountInSeconds",
                "autoMuteWhileRecording", "autoPauseMediaWhileRecording"
            ]
        case .liveCaptions:
            return ["liveCaptionsTranslate"]
        case .dictation:
            return [
                "dictationEnabled",
                "dictationModeRaw",
                "dictationKeyCode",
                "dictationKeyModifiers",
                "dictationIndicatorStyleRaw",
                "dictationCleanupPromptID",
                "dictationPerAppOverridesJSON",
                "dictationHudOpacity",
                "dictationStripSelfCorrections",
                "dictationPasteDelayMs",
                "dictationContextSelection",
                "dictationContextClipboard",
                "dictationContextScreen"
            ]
        case .snippets:
            return ["snippets"]
        case .corrections:
            return ["correctionRules"]
        case .translation:
            return ["translate", "translationSideBySide"]
        case .people:
            // diarize is shared with the .general and .transcriptionDefaults scopes: all three
            // show the toggle, and each pane's reset must cover what it shows.
            return ["showMostUsedPeople", "diarize"]
        case .transcriptionDefaults:
            // wordTimestamps and diarize are shared with the .general scope: both panes
            // show the toggles, and each pane's reset must cover what it shows.
            return [
                "selectedModel", "selectedLanguageRaw", "expectedSpeakersRaw",
                "pausePlayerOnAppHidden", "parola.userPrivacyMode",
                "wordTimestamps", "diarize"
            ]
        case .ignoredSegments:
            return ["ignoredSegmentRules"]
        case .findReplace:
            return ["findReplaceRules"]
        case .exportFormats:
            return ["exportPresets"]
        case .batchExport:
            return [
                "batchExportPresets", "batchExportFormats", "batchExportToSourceFolder",
                "batchExportIncludeTimestamps", "batchExportFormatOptions"
            ]
        case .autoExport:
            return ["autoExportRules", "subtitleCaptionLength", "markdownTimestamps", "txtExportTimestamps", "htmlExportTheme"]
        case .sendTo:
            return ["destinations"]
        case .aiServices:
            return ["aiServices", "languageModelSelection", "remoteAIAcknowledged"]
        case .integrations, .prompts:
            return []
        case .automation:
            return ["automationBridgeEnabled"]
        case .updates:
            return ["sparkleChannel", "sparkleAutomatic"]
        case .advanced:
            // parola.modelsStoragePath stays out of every scope: it points at a machine-specific folder.
            return []
        }
    }
}

/// Persisted settings that no Settings pane hosts — they are set from the transcript view, the
/// burn-in sheet and the captions windows. They stay out of `SettingsPaneScope.defaultsKeys` so a
/// pane's own Reset button only clears what that pane shows, but a backup or a full reset covers them.
enum UnscopedSettingsKeys {
    static let all: [String] = [
        "burnFontSize", "burnTextColor", "burnOutline",
        "subtitleFPS", "skipSilences", "playbackRate",
        "transcriptCompact", "transcriptDisplayMode",
        "mainWindowAlwaysOnTop", "pinnedModel",
        "liveCaptions.fontSize", "liveCaptions.opacity", "presenter.fontSize",
        "introductionComplete",
    ]
}

struct ResetPaneButton: View {
    let scope: SettingsPaneScope
    @State private var confirming = false

    var body: some View {
        if scope.defaultsKeys.isEmpty {
            EmptyView()
        } else {
            HStack {
                Button("Reset to Defaults") {
                    confirming = true
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Pane.Button.ResetToDefaults.\(scope.rawValue)")
                Spacer()
            }
            .confirmationDialog(
                String(localized: "Reset \(scope.localizedLabel) to defaults?"),
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    SettingsResetService.reset(scope: scope)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears the saved settings on this pane, including any of them shown on another pane too.")
            }
        }
    }
}

enum SettingsResetService {
    @MainActor
    static func reset(scope: SettingsPaneScope) {
        let defaults = DefaultsStore.current
        for key in scope.defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .parolaSettingsReset, object: scope)
    }

    @MainActor
    static func resetAll() {
        let defaults = DefaultsStore.current
        for scope in SettingsPaneScope.allCases {
            for key in scope.defaultsKeys {
                defaults.removeObject(forKey: key)
            }
        }
        for key in UnscopedSettingsKeys.all {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .parolaSettingsReset, object: nil)
    }
}

extension Notification.Name {
    static let parolaSettingsReset = Notification.Name("ParolaSettingsResetNotification")
}

