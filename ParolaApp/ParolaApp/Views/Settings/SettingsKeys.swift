import SwiftUI

enum SettingsPaneScope: String, CaseIterable, Identifiable {
    case general
    case customization
    case watchedFolders
    case recordMeetings
    case microphone
    case liveCaptions
    case dictation
    case snippets
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
        case .microphone: return "Microphone"
        case .liveCaptions: return "Live Captions"
        case .dictation: return "Dictation"
        case .snippets: return "Snippets"
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

    /// Search keywords surfaced by the sidebar search beyond the label match.
    var searchKeywords: [String] {
        switch self {
        case .general: return ["karaoke", "highlight", "word timestamps", "streaming", "diarize", "speakers", "vocabulary", "prompt"]
        case .customization: return ["appearance", "theme", "light", "dark", "density", "sidebar", "monospaced"]
        case .watchedFolders: return ["watch", "folder", "auto", "drop"]
        case .recordMeetings: return ["zoom", "teams", "meet", "webex", "meeting", "detect"]
        case .microphone: return ["mic", "input device", "vu", "level", "preview"]
        case .liveCaptions: return ["captions", "translate", "live"]
        case .dictation: return ["hotkey", "f5", "push to talk", "toggle", "indicator", "notch", "overlay", "cleanup", "workflows", "per-app"]
        case .snippets: return ["snippet", "expand", "abbreviation"]
        case .translation: return ["translate", "english"]
        case .transcriptionDefaults: return ["default", "model", "language", "engine", "whisper"]
        case .ignoredSegments: return ["filler", "uh", "um", "ignore", "skip"]
        case .findReplace: return ["regex", "replace", "term pack", "substitution", "rule"]
        case .exportFormats: return ["txt", "srt", "vtt", "csv", "docx", "pdf", "markdown", "html"]
        case .batchExport: return ["batch", "multiple files", "drag drop"]
        case .autoExport: return ["auto export", "rule"]
        case .integrations: return ["yt-dlp", "youtube", "homebrew"]
        case .prompts: return ["prompt", "cleanup", "translate", "bullet", "action"]
        case .automation: return ["mcp", "bridge", "claude code", "codex", "loopback"]
        case .updates: return ["sparkle", "appcast", "channel", "auto-update"]
        case .advanced: return ["model storage", "cache", "reveal", "reset", "export settings", "import settings"]
        }
    }

    var defaultsKeys: [String] {
        switch self {
        case .general:
            return ["useStreaming", "wordTimestamps", "karaokeHighlight", "initialPrompt", "diarize"]
        case .customization:
            return ["appTheme", "monospacedTimestamps", "sidebarDensity"]
        case .watchedFolders:
            return ["watchedFolders"]
        case .recordMeetings:
            return ["meetingDetectorEnabled"]
        case .microphone:
            return ["inputDeviceUID"]
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
                "dictationPerAppOverridesJSON"
            ]
        case .snippets:
            return ["snippets"]
        case .translation:
            return ["translate"]
        case .transcriptionDefaults:
            return ["selectedModel", "selectedLanguageRaw"]
        case .ignoredSegments:
            return ["ignoredSegmentRules"]
        case .findReplace:
            return ["findReplaceRules"]
        case .exportFormats:
            return []
        case .batchExport:
            return ["batchExportFormats", "batchExportToSourceFolder", "batchExportIncludeTimestamps"]
        case .autoExport:
            return ["autoExportRules"]
        case .integrations, .prompts:
            return []
        case .automation:
            return ["automationBridgeEnabled"]
        case .updates:
            return ["sparkleChannel", "sparkleAutomatic"]
        case .advanced:
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
            }
            .confirmationDialog(
                "Reset \(scope.label) to defaults?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    SettingsResetService.reset(scope: scope)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears the saved settings on this pane. Other panes are unaffected.")
            }
        }
    }
}

enum SettingsResetService {
    @MainActor
    static func reset(scope: SettingsPaneScope) {
        let defaults = UserDefaults.standard
        for key in scope.defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .parolaSettingsReset, object: scope)
    }

    @MainActor
    static func resetAll() {
        let defaults = UserDefaults.standard
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

struct ResetAllSettingsButton: View {
    @State private var confirming = false

    var body: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                confirming = true
            } label: {
                Text("Reset all Parola settings")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Reset every Parola setting?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Reset all", role: .destructive) {
                SettingsResetService.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears every saved preference. Library entries, models, and dictation prompts are kept.")
        }
    }
}
