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
    case transcriptionDefaults
    case ignoredSegments
    case findReplace
    case exportFormats
    case batchExport
    case autoExport
    case integrations
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
        case .transcriptionDefaults: return "Transcription Defaults"
        case .ignoredSegments: return "Ignored Segments"
        case .findReplace: return "Find & Replace"
        case .exportFormats: return "Export Formats"
        case .batchExport: return "Batch Export"
        case .autoExport: return "Auto-Export"
        case .integrations: return "Integrations"
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
        case .transcriptionDefaults: return String(localized: "Transcription Defaults")
        case .ignoredSegments: return String(localized: "Ignored Segments")
        case .findReplace: return String(localized: "Find & Replace")
        case .exportFormats: return String(localized: "Export Formats")
        case .batchExport: return String(localized: "Batch Export")
        case .autoExport: return String(localized: "Auto-Export")
        case .integrations: return String(localized: "Integrations")
        case .prompts: return String(localized: "Prompts")
        case .automation: return String(localized: "MCP & Automation")
        case .updates: return String(localized: "Updates")
        case .advanced: return String(localized: "Advanced")
        }
    }

    /// Search keywords surfaced by the sidebar search beyond the label match.
    var searchKeywords: [String] {
        switch self {
        case .general: return ["karaoke", "highlight", "word timestamps", "streaming", "diarize", "speakers", "vocabulary", "prompt", "menu bar", "login", "launch", "startup", "title"]
        case .customization: return ["appearance", "theme", "light", "dark", "density", "sidebar", "monospaced", "accent", "color", "terracotta", "custom colors", "palette"]
        case .watchedFolders: return ["watch", "folder", "auto", "drop"]
        case .recordMeetings: return ["zoom", "teams", "meet", "webex", "meeting", "detect", "system audio", "permission", "screen recording", "consent"]
        case .shortcuts: return ["hotkey", "key combo", "mic recording", "dictation key", "global", "keyboard"]
        case .microphone: return ["mic", "input device", "vu", "level", "preview", "count-in", "mute", "pause media", "music", "spotify", "auto-stop"]
        case .liveCaptions: return ["captions", "translate", "live"]
        case .dictation: return ["hotkey", "f5", "push to talk", "toggle", "indicator", "notch", "overlay", "cleanup", "workflows", "per-app", "hud", "opacity", "context", "clipboard", "screen", "ocr", "paste delay", "self-corrections", "url rule"]
        case .snippets: return ["snippet", "expand", "abbreviation", "trigger", "placeholder", "date", "time"]
        case .corrections: return ["correction", "fix", "replace", "dictation", "vocabulary"]
        case .translation: return ["translate", "english"]
        case .transcriptionDefaults: return ["default", "model", "language", "engine", "whisper", "privacy", "cloud", "llm", "speakers", "diarize", "word timestamps", "apple speech", "playback"]
        case .ignoredSegments: return ["filler", "uh", "um", "ignore", "skip"]
        case .findReplace: return ["regex", "replace", "term pack", "substitution", "rule"]
        case .exportFormats: return ["txt", "srt", "vtt", "csv", "tsv", "docx", "pdf", "markdown", "html", "json", "jsonl", "fcpxml", "final cut", "lrc", "lyrics", "subtitles"]
        case .batchExport: return ["batch", "multiple files", "drag drop", "queue", "sidecar", "folder"]
        case .autoExport: return ["auto export", "rule", "line length", "qc", "timestamps", "html theme"]
        case .integrations: return ["yt-dlp", "youtube", "homebrew", "install"]
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
                "showMenuBarExtra", "autoTitleEntries", "showSubtitleQC"
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
            return ["translate"]
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
            return []
        case .batchExport:
            return [
                "batchExportFormats", "batchExportToSourceFolder", "batchExportIncludeTimestamps",
                "batchExportFormatOptions"
            ]
        case .autoExport:
            return ["autoExportRules", "subtitleCaptionLength", "markdownTimestamps", "txtExportTimestamps", "htmlExportTheme"]
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

struct ResetPaneButton: View {
    let scope: SettingsPaneScope
    @State private var confirming = false

    var body: some View {
        if scope.defaultsKeys.isEmpty {
            EmptyView()
        } else {
            HStack {
                Spacer()
                Button("Reset to defaults") {
                    confirming = true
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .axLeaf("Pane.Button.ResetToDefaults.\(scope.rawValue)")
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
        NotificationCenter.default.post(name: .parolaSettingsReset, object: nil)
    }
}

extension Notification.Name {
    static let parolaSettingsReset = Notification.Name("ParolaSettingsResetNotification")
}

