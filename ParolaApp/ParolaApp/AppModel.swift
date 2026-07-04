import Combine
import CoreGraphics
import Foundation
import SwiftUI
import AVFoundation
import Observation
import UniformTypeIdentifiers
import ParolaCore
import ParolaDictation

@MainActor
@Observable
final class AppModel {

    // MARK: - State

    enum Phase: Equatable {
        case idle
        case downloadingModel(name: String, progress: Double)
        case loadingModel(name: String)
        case transcribing(file: URL)
        case recording(source: RecordSource)
        case ready
        case failed(message: String)
    }

    enum RecordSource: String, CaseIterable, Identifiable {
        case microphone
        case systemAudio
        var id: String { rawValue }
        var label: String {
            switch self {
            case .microphone: return String(localized: "Microphone")
            case .systemAudio: return String(localized: "System audio")
            }
        }
        var systemImage: String {
            switch self {
            case .microphone: return "mic.fill"
            case .systemAudio: return "waveform"
            }
        }
    }

    enum Route: String, Hashable, CaseIterable {
        case transcript
        case batch
        case queue
    }

    var route: Route = .transcript
    var settingsPane: String = "general"
    var settingsRoutePreview = false  // test-mode only: renders SettingsView in the main window so the bridge can screenshot panes
    var phase: Phase = .idle
    var transcript: Transcript? {
        didSet {
            // Backfill re-assigns and returns so the recursive didSet pass runs the side effects exactly once.
            if let d = pendingMediaDuration, var patched = transcript, (patched.durationSeconds ?? 0) < d - 0.05 {
                patched.durationSeconds = d
                transcript = patched
                return
            }
            if transcript == nil, promptOutput != nil { promptOutput = nil }
            currentSegmentIndex = nil
            let speakers = transcript?.uniqueSpeakers ?? []
            if speakers != transcriptSpeakers { transcriptSpeakers = speakers }
            transcriptVersion &+= 1
            if findIsOpen { scheduleRecomputeMatches() }
        }
    }
    private(set) var transcriptSpeakers: [String] = []
    private(set) var transcriptVersion: Int = 0
    // Short-circuits rather than building Transcript.text just to test for emptiness on every view update.
    var transcriptIsEmpty: Bool {
        guard let transcript else { return false }
        return !transcript.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var showingTrash: Bool = false
    var currentSegmentID: TranscriptSegment.ID?
    var currentWordID: WordTiming.ID?
    // Playback-tick cache: index of currentSegmentID in transcript.segments, so the 5 Hz tick
    // validates in O(1) instead of scanning. Nil'd whenever the transcript is replaced.
    @ObservationIgnored var currentSegmentIndex: Int?

    var liveSegments: [TranscriptSegment] = []
    var livePartialText: String = ""
    var liveVoiceActive: Bool = false
    var filePartialText: String = ""
    /// 0–1 fraction of the media transcribed so far, or nil while indeterminate (duration unknown, or the engine reports no progress).
    var fileTranscribeFraction: Double?
    var useStreaming: Bool = true { didSet { defaults.set(useStreaming, forKey: "useStreaming") } }
    var wordTimestamps: Bool = false { didSet { defaults.set(wordTimestamps, forKey: "wordTimestamps") } }
    var karaokeHighlight: Bool = true { didSet { defaults.set(karaokeHighlight, forKey: "karaokeHighlight") } }
    var initialPrompt: String = "" { didSet { defaults.set(initialPrompt, forKey: "initialPrompt") } }
    var diarize: Bool = false { didSet { defaults.set(diarize, forKey: "diarize") } }
    var autoTitleEntries: Bool = false { didSet { defaults.set(autoTitleEntries, forKey: "autoTitleEntries") } }
    var subtitleFPS: Double = 30 { didSet { defaults.set(subtitleFPS, forKey: "subtitleFPS") } }
    var subtitleCaptionLengthRaw: String = CaptionLength.none.rawValue { didSet { defaults.set(subtitleCaptionLengthRaw, forKey: "subtitleCaptionLength") } }
    var transcriptCompact: Bool = false { didSet { defaults.set(transcriptCompact, forKey: "transcriptCompact") } }
    var skipSilences: Bool = false { didSet { defaults.set(skipSilences, forKey: "skipSilences") } }
    var pausePlayerOnAppHidden: Bool = false { didSet { defaults.set(pausePlayerOnAppHidden, forKey: "pausePlayerOnAppHidden") } }
    var markdownTimestamps: Bool = false { didSet { defaults.set(markdownTimestamps, forKey: "markdownTimestamps") } }
    var htmlExportThemeRaw: String = HtmlExportTheme.light.rawValue { didSet { defaults.set(htmlExportThemeRaw, forKey: "htmlExportTheme") } }
    var dictationHudOpacity: Double = 1.0 { didSet { defaults.set(dictationHudOpacity, forKey: "dictationHudOpacity") } }
    var lastFindQuery: String = "" { didSet { defaults.set(lastFindQuery, forKey: "lastFindQuery") } }
    var userPrivacyMode: Bool = false { didSet { defaults.set(userPrivacyMode, forKey: "parola.userPrivacyMode") } }
    var pinnedModel: String = "" { didSet { defaults.set(pinnedModel, forKey: "pinnedModel") } }
    var mainWindowAlwaysOnTop: Bool = false { didSet { defaults.set(mainWindowAlwaysOnTop, forKey: "mainWindowAlwaysOnTop") } }
    var recentFilesRaw: String = "[]" { didSet { defaults.set(recentFilesRaw, forKey: "recentFiles") } }
    var micHotkeyKeyCode: Int = 15 { didSet { defaults.set(micHotkeyKeyCode, forKey: "micHotkeyKeyCode") } } // kVK_ANSI_R
    var micHotkeyModifiers: Int = 786721 { didSet { defaults.set(micHotkeyModifiers, forKey: "micHotkeyModifiers") } } // ⌃⌥⌘
    var micHotkeyEnabled: Bool = false { didSet { defaults.set(micHotkeyEnabled, forKey: "micHotkeyEnabled") } }
    var dictationStripSelfCorrections: Bool = false {
        didSet {
            defaults.set(dictationStripSelfCorrections, forKey: "dictationStripSelfCorrections")
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }
    var dictationPasteDelayMs: Int = 0 { didSet { defaults.set(dictationPasteDelayMs, forKey: "dictationPasteDelayMs") } }
    var dictationContextSelection: Bool = false {
        didSet {
            defaults.set(dictationContextSelection, forKey: "dictationContextSelection")
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }
    var dictationContextClipboard: Bool = false {
        didSet {
            defaults.set(dictationContextClipboard, forKey: "dictationContextClipboard")
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }
    var dictationContextScreen: Bool = false {
        didSet {
            defaults.set(dictationContextScreen, forKey: "dictationContextScreen")
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }
    var recordingMaxMinutes: Int = 0 { didSet { defaults.set(recordingMaxMinutes, forKey: "recordingMaxMinutes") } }
    var showMenuBarExtra: Bool = false { didSet { defaults.set(showMenuBarExtra, forKey: "showMenuBarExtra") } }
    var recordingCountInSeconds: Int = 0 { didSet { defaults.set(recordingCountInSeconds, forKey: "recordingCountInSeconds") } }
    var autoMuteWhileRecording: Bool = false { didSet { defaults.set(autoMuteWhileRecording, forKey: "autoMuteWhileRecording") } }
    var autoPauseMediaWhileRecording: Bool = false { didSet { defaults.set(autoPauseMediaWhileRecording, forKey: "autoPauseMediaWhileRecording") } }
    var recordingCountdown: Int? = nil
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    var recentFiles: [URL] {
        get {
            var list = RecentFilesList(capacity: 10)
            list.decode(recentFilesRaw)
            return list.urls
        }
        set {
            var list = RecentFilesList(capacity: 10)
            for url in newValue.reversed() { list.note(url) }
            recentFilesRaw = list.encoded
        }
    }

    func noteRecentFile(_ url: URL) {
        var list = RecentFilesList(capacity: 10)
        list.decode(recentFilesRaw)
        list.note(url)
        recentFilesRaw = list.encoded
    }

    func clearRecentFiles() {
        recentFilesRaw = "[]"
    }

    func toggleMicRecording() {
        switch phase {
        case .recording(.microphone):
            stopRecordingAndTranscribe()
        case .idle, .ready, .failed:
            startRecording(source: .microphone)
        default:
            return
        }
    }

    var micHotkeyModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(micHotkeyModifiers))
            .intersection(.deviceIndependentFlagsMask)
    }

    var batchJobs: [BatchJob] = []
    var selectedBatchJobID: BatchJob.ID?
    @ObservationIgnored var batchTask: Task<Void, Never>?

    var batchExportFormatsRaw: String = "txt,srt" { didSet { defaults.set(batchExportFormatsRaw, forKey: "batchExportFormats") } }
    var batchExportToSourceFolder: Bool = true { didSet { defaults.set(batchExportToSourceFolder, forKey: "batchExportToSourceFolder") } }
    var batchExportIncludeTimestamps: Bool = false { didSet { defaults.set(batchExportIncludeTimestamps, forKey: "batchExportIncludeTimestamps") } }
    var batchExportFormatOptionsJSON: String = "{}" { didSet { defaults.set(batchExportFormatOptionsJSON, forKey: "batchExportFormatOptions") } }

    var findIsOpen: Bool = false
    var findQuery: String = "" {
        didSet {
            if !findQuery.isEmpty { lastFindQuery = findQuery }
            scheduleRecomputeMatches()
        }
    }
    var findCaseSensitive: Bool = false { didSet { scheduleRecomputeMatches() } }
    var findReplacement: String = ""
    var matches: [TranscriptMatch] = [] { didSet { rebuildMatchesIndex() } }
    @ObservationIgnored var matchesBySegment: [Int: [TranscriptMatch]] = [:]
    var currentMatchIndex: Int = 0
    @ObservationIgnored var matchesDebounce: Task<Void, Never>?

    var inputDeviceUID: String = "" { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }

    var preferredInputDeviceUID: String? {
        inputDeviceUID.isEmpty ? nil : inputDeviceUID
    }

    var selectedModel: String = "openai_whisper-tiny" { didSet { defaults.set(selectedModel, forKey: "selectedModel") } }
    private var selectedLanguageRaw: String = "" { didSet { defaults.set(selectedLanguageRaw, forKey: "selectedLanguageRaw") } }
    var translate: Bool = false { didSet { defaults.set(translate, forKey: "translate") } }

    @ObservationIgnored private var cachedSelectedModel: String = ""
    @ObservationIgnored private var cachedCapabilities: EngineCapabilities = .whisperKitDefaults

    var selectedModelCapabilities: EngineCapabilities {
        if cachedSelectedModel != selectedModel {
            cachedSelectedModel = selectedModel
            cachedCapabilities = ModelCatalog.staticCapabilities(forID: selectedModel) ?? .whisperKitDefaults
        }
        return cachedCapabilities
    }

    nonisolated static func modelLabel(_ id: String) -> String {
        ModelCatalog.variant(id: id)?.displayName ?? id
    }

    // False only for Parakeet, which emits nothing until the end — so its empty window isn't "preparing".
    nonisolated static func engineStreamsPartials(_ id: String) -> Bool {
        ModelCatalog.variant(id: id)?.engineID != .parakeet
    }

    var activeEngineStreamsPartials: Bool {
        AppModel.engineStreamsPartials(selectedModel)
    }

    /// Non-blocking advisory when the selected model rejects the explicitly chosen language; nil for Auto-detect, matching TranscriptionSession.validate.
    var languageMismatchWarning: String? {
        guard let language = selectedLanguage,
              !selectedModelCapabilities.supportedLanguages.allows(language) else { return nil }
        return "\(AppModel.modelLabel(selectedModel)) is English-only. Pick a multilingual model (like Whisper) to transcribe other languages."
    }

    var selectedLanguage: String? {
        get { selectedLanguageRaw.isEmpty ? nil : selectedLanguageRaw }
        set { selectedLanguageRaw = newValue ?? "" }
    }

    var availableModels: [ModelInfo] = []
    var sourceFileURL: URL?

    var player: AVPlayer?
    var hasVideo: Bool = false
    var currentTimeSeconds: Double = 0
    var isPlaying: Bool = false
    @ObservationIgnored var playerTimeObserver: Any?
    @ObservationIgnored var timeControlObserver: NSKeyValueObservation?
    @ObservationIgnored var playerInstallToken: Int = 0
    /// Duration loaded from the player asset, applied once the transcript arrives — the transcribe path installs the player before the transcript exists.
    @ObservationIgnored var pendingMediaDuration: Double?

    var pendingExport: ExportFormat?

    // MARK: - Post-process rules

    var ignoredSegmentRules: [IgnoredSegmentRule] = [] {
        didSet { saveIgnoredSegmentRules() }
    }

    var findReplaceRules: [FindReplaceRule] = [] {
        didSet { saveFindReplaceRules() }
    }

    var snippets: [Snippet] = [] {
        didSet {
            saveSnippets()
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }

    var correctionRules: [CorrectionRule] = [] {
        didSet {
            saveCorrectionRules()
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }

    // MARK: - People (speakers)

    @ObservationIgnored let peopleStore = PeopleStore()
    var showingSpeakersSheet: Bool = false

    // MARK: - Prompt library

    @ObservationIgnored let promptLibrary = PromptLibrary()
    var promptOutput: PromptOutput?
    var isRunningPrompt: Bool = false
    var actionItems: [ActionItem] = []
    var isExtractingActionItems: Bool = false
    var smartChapters: [Chapter] = []
    var isExtractingChapters: Bool = false
    var entrySpeakerFilters: [String: String] = [:]

    struct PromptOutput: Identifiable {
        let id = UUID()
        let promptName: String
        let text: String
    }

    // MARK: - Auto-export rules

    var autoExportRules: [AutoExportRule] = [] {
        didSet { saveAutoExportRules() }
    }

    // MARK: - Watched folders

    @ObservationIgnored lazy var watchedFolders: WatchedFoldersStore = WatchedFoldersStore { [weak self] url in
        self?.transcribe(fileURL: url)
    }

    // MARK: - Live captions

    @ObservationIgnored weak var liveCaptions: LiveCaptionsController?

    func toggleLiveCaptions() {
        guard let liveCaptions else { return }
        Task { await liveCaptions.toggle(options: makeOptions(task: .transcribe)) }
    }

    // MARK: - Dictation

    var dictationEnabled: Bool = false {
        didSet {
            defaults.set(dictationEnabled, forKey: "dictationEnabled")
            if !isReloadingSettings { applyDictationEnabledChange() }
        }
    }

    var dictationModeRaw: String = DictationMode.pushToTalk.rawValue {
        didSet {
            defaults.set(dictationModeRaw, forKey: "dictationModeRaw")
            if !isReloadingSettings { applyDictationModeChange() }
        }
    }

    var dictationKeyCode: Int = 96 {
        didSet {
            defaults.set(dictationKeyCode, forKey: "dictationKeyCode")
            if !isReloadingSettings { restartDictation() }
        }
    }

    var dictationKeyModifiers: Int = 0 {
        didSet {
            defaults.set(dictationKeyModifiers, forKey: "dictationKeyModifiers")
            if !isReloadingSettings { restartDictation() }
        }
    }

    var dictationModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(dictationKeyModifiers))
            .intersection(.deviceIndependentFlagsMask)
    }

    var dictationIndicatorStyleRaw: String = DictationIndicatorStyle.overlay.rawValue {
        didSet {
            defaults.set(dictationIndicatorStyleRaw, forKey: "dictationIndicatorStyleRaw")
            if !isReloadingSettings { applyIndicatorStyleChange() }
        }
    }

    var dictationMode: DictationMode {
        DictationMode(rawValue: dictationModeRaw) ?? .pushToTalk
    }

    var dictationIndicatorStyle: DictationIndicatorStyle {
        DictationIndicatorStyle(rawValue: dictationIndicatorStyleRaw) ?? .overlay
    }

    // MARK: - Customization

    var appTheme: String = "system" { didSet { defaults.set(appTheme, forKey: "appTheme") } }  // "system" | "light" | "dark"
    var monospacedTimestamps: Bool = true { didSet { defaults.set(monospacedTimestamps, forKey: "monospacedTimestamps") } }
    var sidebarDensity: String = "comfortable" { didSet { defaults.set(sidebarDensity, forKey: "sidebarDensity") } }  // "comfortable" | "compact"

    var transcriptDisplayModeRaw: String = TranscriptDisplayMode.transcript.rawValue {
        didSet { defaults.set(transcriptDisplayModeRaw, forKey: "transcriptDisplayMode") }
    }

    var transcriptDisplayMode: TranscriptDisplayMode {
        get { TranscriptDisplayMode(rawValue: transcriptDisplayModeRaw) ?? .transcript }
        set { transcriptDisplayModeRaw = newValue.rawValue }
    }

    /// Syncs the live model after a bridge `setSetting` writes `key` to defaults; reloads the whole snapshot, not just `key`, since many observed properties (transcribe options, theme, dictation) drive live behavior.
    func reloadObservedSetting(key: String) {
        reloadSettings()
    }

    @ObservationIgnored private var isReloadingSettings = false
    @ObservationIgnored private var activeSideEffects: Set<BootstrapSideEffect> = []

    private func themeKeySnapshot() -> [String] {
        [appTheme, appAccentRaw, String(themeIsCustom), themeCustomPaletteJSON]
    }

    /// Re-reads every persisted setting into its observed property after a Reset or Import, suppressing the
    /// side-effecting didSets during the bulk read, then re-applying the side effects once. Avoids a relaunch.
    func reloadSettings() {
        let themeBefore = themeKeySnapshot()
        let watchedFoldersBefore = defaults.data(forKey: "watchedFolders")

        isReloadingSettings = true
        self.dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        self.dictationModeRaw = defaults.string(forKey: "dictationModeRaw") ?? DictationMode.pushToTalk.rawValue
        self.dictationKeyCode = defaults.object(forKey: "dictationKeyCode") == nil ? 96 : defaults.integer(forKey: "dictationKeyCode")
        self.dictationKeyModifiers = defaults.object(forKey: "dictationKeyModifiers") == nil ? 0 : defaults.integer(forKey: "dictationKeyModifiers")
        self.dictationIndicatorStyleRaw = defaults.string(forKey: "dictationIndicatorStyleRaw") ?? DictationIndicatorStyle.overlay.rawValue
        self.dictationCleanupPromptID = defaults.string(forKey: "dictationCleanupPromptID") ?? ""
        self.dictationPerAppOverridesJSON = defaults.string(forKey: "dictationPerAppOverridesJSON") ?? "{}"
        self.transcriptDisplayModeRaw = defaults.string(forKey: "transcriptDisplayMode") ?? TranscriptDisplayMode.transcript.rawValue
        self.useStreaming = readBool("useStreaming", default: true)
        self.wordTimestamps = defaults.bool(forKey: "wordTimestamps")
        self.karaokeHighlight = readBool("karaokeHighlight", default: true)
        self.initialPrompt = defaults.string(forKey: "initialPrompt") ?? ""
        self.diarize = defaults.bool(forKey: "diarize")
        self.autoTitleEntries = defaults.bool(forKey: "autoTitleEntries")
        self.subtitleFPS = readDouble("subtitleFPS", default: 30)
        self.subtitleCaptionLengthRaw = defaults.string(forKey: "subtitleCaptionLength") ?? CaptionLength.none.rawValue
        self.transcriptCompact = defaults.bool(forKey: "transcriptCompact")
        self.skipSilences = defaults.bool(forKey: "skipSilences")
        self.pausePlayerOnAppHidden = defaults.bool(forKey: "pausePlayerOnAppHidden")
        self.markdownTimestamps = defaults.bool(forKey: "markdownTimestamps")
        self.htmlExportThemeRaw = defaults.string(forKey: "htmlExportTheme") ?? HtmlExportTheme.light.rawValue
        self.dictationHudOpacity = readDouble("dictationHudOpacity", default: 1.0)
        self.lastFindQuery = defaults.string(forKey: "lastFindQuery") ?? ""
        self.userPrivacyMode = defaults.bool(forKey: "parola.userPrivacyMode")
        self.pinnedModel = defaults.string(forKey: "pinnedModel") ?? ""
        self.mainWindowAlwaysOnTop = defaults.bool(forKey: "mainWindowAlwaysOnTop")
        self.recentFilesRaw = defaults.string(forKey: "recentFiles") ?? "[]"
        self.micHotkeyKeyCode = readInt("micHotkeyKeyCode", default: 15)
        self.micHotkeyModifiers = readInt("micHotkeyModifiers", default: 786721)
        self.micHotkeyEnabled = defaults.bool(forKey: "micHotkeyEnabled")
        self.dictationStripSelfCorrections = defaults.bool(forKey: "dictationStripSelfCorrections")
        self.dictationPasteDelayMs = defaults.integer(forKey: "dictationPasteDelayMs")
        self.dictationContextSelection = defaults.bool(forKey: "dictationContextSelection")
        self.dictationContextClipboard = defaults.bool(forKey: "dictationContextClipboard")
        self.dictationContextScreen = defaults.bool(forKey: "dictationContextScreen")
        self.recordingMaxMinutes = defaults.integer(forKey: "recordingMaxMinutes")
        self.showMenuBarExtra = defaults.bool(forKey: "showMenuBarExtra")
        self.recordingCountInSeconds = defaults.integer(forKey: "recordingCountInSeconds")
        self.autoMuteWhileRecording = defaults.bool(forKey: "autoMuteWhileRecording")
        self.autoPauseMediaWhileRecording = defaults.bool(forKey: "autoPauseMediaWhileRecording")
        self.batchExportFormatsRaw = defaults.string(forKey: "batchExportFormats") ?? "txt,srt"
        self.batchExportToSourceFolder = readBool("batchExportToSourceFolder", default: true)
        self.batchExportIncludeTimestamps = defaults.bool(forKey: "batchExportIncludeTimestamps")
        self.batchExportFormatOptionsJSON = defaults.string(forKey: "batchExportFormatOptions") ?? "{}"
        self.inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "openai_whisper-tiny"
        self.selectedLanguageRaw = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        self.translate = defaults.bool(forKey: "translate")
        self.appTheme = defaults.string(forKey: "appTheme") ?? "system"
        self.monospacedTimestamps = readBool("monospacedTimestamps", default: true)
        self.sidebarDensity = defaults.string(forKey: "sidebarDensity") ?? "comfortable"
        self.appAccentRaw = defaults.string(forKey: AppAccent.storageKey) ?? AppAccent.terracotta.rawValue
        self.themeIsCustom = defaults.bool(forKey: "themeIsCustom")
        self.themeCustomPaletteJSON = defaults.string(forKey: "themeCustomPaletteJSON") ?? ""
        self.automationBridgeEnabled = readBool("automationBridgeEnabled", default: AppModel.defaultBridgeEnabled)
        self.sparkleChannelRaw = defaults.string(forKey: "sparkleChannel") ?? SparkleChannel.stable.rawValue
        self.sparkleAutomatic = readBool("sparkleAutomatic", default: true)
        self.liveCaptionsTranslate = defaults.bool(forKey: "liveCaptionsTranslate")
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        loadSnippets()
        loadCorrectionRules()
        isReloadingSettings = false

        refreshModelList()
        if themeKeySnapshot() != themeBefore {
            applyTheme()
            themeRevision &+= 1
        }
        // Re-apply only the side effects this launch actually wired (skipped under skipBootstrap tests).
        if activeSideEffects.contains(.dictationHotkey) {
            if dictationEnabled { stopDictation(); startDictation() } else { stopDictation() }
        }
        if activeSideEffects.contains(.sparkle) {
            applySparkleChannelChange()
            SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic
        }
        if activeSideEffects.contains(.liveCaptionsTranslateRestore) {
            applyLiveCaptionsTranslateChange()
        }
        if activeSideEffects.contains(.meetingDetector) {
            meetingDetector.isEnabled = (defaults.object(forKey: "meetingDetectorEnabled") as? Bool) ?? true
        }
        if activeSideEffects.contains(.watchedFolders), mode != .test,
           defaults.data(forKey: "watchedFolders") != watchedFoldersBefore {
            SettingsRelaunch.promptToApply("Quit and relaunch Parola to apply watched-folder changes.")
        }
    }
    var appAccentRaw: String = AppAccent.terracotta.rawValue { didSet { defaults.set(appAccentRaw, forKey: AppAccent.storageKey) } }

    var appAccent: AppAccent {
        get { AppAccent(rawValue: appAccentRaw) ?? .terracotta }
        set { appAccentRaw = newValue.rawValue }
    }

    var themeIsCustom: Bool = false { didSet { defaults.set(themeIsCustom, forKey: "themeIsCustom") } }
    var themeCustomPaletteJSON: String = "" { didSet { defaults.set(themeCustomPaletteJSON, forKey: "themeCustomPaletteJSON") } }

    /// Bumped on every theme change. The window root keys `.id` off it so the whole tree repaints —
    /// most leaf views read DS.Color.* statically and would not otherwise re-render on a palette swap.
    private(set) var themeRevision: Int = 0

    var themeSelection: ThemeSelection {
        if themeIsCustom, let palette = decodedCustomPalette() {
            return .custom(palette)
        }
        return .preset(ThemePreset(rawValue: appAccentRaw) ?? .terracotta)
    }

    @discardableResult
    func applyTheme() -> ThemePalette {
        let palette = themeSelection.palette
        DS.theme = palette
        return palette
    }

    func selectThemePreset(_ raw: String) {
        appAccentRaw = raw
        themeIsCustom = false
        applyTheme()
        themeRevision &+= 1
    }

    func applyCustomPalette(_ palette: ThemePalette) {
        guard let data = try? JSONEncoder().encode(palette),
              let json = String(data: data, encoding: .utf8) else { return }
        themeCustomPaletteJSON = json
        themeIsCustom = true
        applyTheme()
        themeRevision &+= 1
    }

    func resetToPresetTheme() {
        themeIsCustom = false
        applyTheme()
        themeRevision &+= 1
    }

    /// Live edit of the custom palette from the color editor. Updates DS.theme and persists, but
    /// does NOT bump themeRevision — a full `.id` rebuild would dismiss the open color picker. The
    /// rest of the app repaints with the new palette on its next render (e.g. when Settings closes).
    func previewCustomPalette(_ palette: ThemePalette) {
        guard let data = try? JSONEncoder().encode(palette),
              let json = String(data: data, encoding: .utf8) else { return }
        themeCustomPaletteJSON = json
        themeIsCustom = true
        DS.theme = palette
    }

    private func decodedCustomPalette() -> ThemePalette? {
        guard let data = themeCustomPaletteJSON.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ThemePalette.self, from: data)
    }

    var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var dictationCleanupPromptID: String = "" {
        didSet {
            defaults.set(dictationCleanupPromptID, forKey: "dictationCleanupPromptID")
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }

    var dictationPerAppOverridesJSON: String = "{}" {
        didSet {
            defaults.set(dictationPerAppOverridesJSON, forKey: "dictationPerAppOverridesJSON")
            cachedDictationWorkflows = nil
            if !isReloadingSettings {
                applyDictationCleanupPromptChange()
                restartDictation()
            }
        }
    }

    @ObservationIgnored var cachedDictationWorkflows: (json: String, map: [String: [DictationWorkflow]])?
    @ObservationIgnored var cachedDictationTriggerPrompts: [Prompt] = []

    static let dictationOverrideApps: [(bundleID: String, name: String)] = [
        ("com.apple.mail", "Mail"),
        ("com.apple.MobileSMS", "Messages"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.Notes", "Notes"),
    ]

    @ObservationIgnored let dictationController = DictationController()

    var dictationState: DictationCoordinator.State = .idle
    @ObservationIgnored let recordingAudioLevel = CurrentValueSubject<Float, Never>(0)
    var recordingIsSilent: Bool = false
    @ObservationIgnored var recordingLevelTask: Task<Void, Never>?
    @ObservationIgnored var silenceDetector: SilenceDetector = SilenceDetector(threshold: 8)
    @ObservationIgnored var silenceWatchTask: Task<Void, Never>?
    @ObservationIgnored var recordingAutoStopTask: Task<Void, Never>?

    private func readString(_ key: String, default fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private func readInt(_ key: String, default fallback: Int) -> Int {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.integer(forKey: key)
    }

    private func readBool(_ key: String, default fallback: Bool) -> Bool {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.bool(forKey: key)
    }

    private func readDouble(_ key: String, default fallback: Double) -> Double {
        if defaults.object(forKey: key) == nil { return fallback }
        return defaults.double(forKey: key)
    }

    private static let sharedJSONDecoder = JSONDecoder()
    private static let sharedJSONEncoder = JSONEncoder()

    func readJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? AppModel.sharedJSONDecoder.decode(T.self, from: data)
    }

    func writeJSON<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? AppModel.sharedJSONEncoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - Meeting detection

    var meetingDetectedApp: String?
    @ObservationIgnored var pendingRecordingCategory: EntryCategory = .transcription
    @ObservationIgnored lazy var meetingDetector: MeetingDetector = MeetingDetector { [weak self] appName in
        self?.meetingDetectedApp = appName
    }

    // MARK: - Library

    @ObservationIgnored let library: LibraryStore
    var libraryEntries: [LibraryEntry] = [] {
        didSet {
            rebuildLibraryIndex()
            libraryVersion &+= 1
        }
    }
    private(set) var libraryVersion: Int = 0
    var deletedEntries: [LibraryEntry] = []
    var searchResults: [LibraryEntry]?
    var selectedEntryID: LibraryEntry.ID?
    @ObservationIgnored private var libraryEntriesByID: [String: LibraryEntry] = [:]

    private func rebuildLibraryIndex() {
        libraryEntriesByID = Dictionary(uniqueKeysWithValues: libraryEntries.map { ($0.id, $0) })
    }

    func libraryEntry(id: LibraryEntry.ID) -> LibraryEntry? {
        libraryEntriesByID[id]
    }
    var libraryFilter: EntryCategory?
    /// True when the "All" chip is showing the flat all-categories list. Distinguishes All from Home, which both leave libraryFilter nil.
    var libraryBrowsingAll: Bool = false
    var librarySortOrder: LibrarySortOrder = .newest {
        didSet { reapplyLibrarySort() }
    }
    // Observed on purpose: LibraryRow and the list totals read these, and refreshBundleSizes fills them asynchronously, so the assignment must re-render.
    var libraryBundleSizes: [String: Int64] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var libraryRefreshTask: Task<Void, Never>?
    @ObservationIgnored var pendingTranscriptSaveTask: Task<Void, Never>?
    @ObservationIgnored var pendingTranscriptSaveGeneration: Int = 0
    static let trashRetentionDays = 30

    // MARK: - Engine

    @ObservationIgnored private let session = TranscriptionSession()
    @ObservationIgnored private let store = ModelStore.shared
    @ObservationIgnored let mediaSession = MediaSession()

    func mediaSessionConfig(allowMute: Bool) -> MediaSessionConfig {
        MediaSessionConfig(
            muteSystemAudio: allowMute && autoMuteWhileRecording,
            pausePlayback: autoPauseMediaWhileRecording
        )
    }

    @ObservationIgnored var liveSource: AudioSource?
    @ObservationIgnored var deferredArrivals: [URL] = []
    @ObservationIgnored private var streamingSession: (any StreamingTranscriber)?
    @ObservationIgnored private var streamingConsumer: Task<Void, Never>?
    @ObservationIgnored private var fileTranscribeTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeTranscribeTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeSubsTask: Task<Void, Never>?
    var canCancel: Bool {
        if batchTask != nil { return true }
        if streamingConsumer != nil { return true }
        if fileTranscribeTask != nil { return true }
        if downloadTask != nil { return true }
        if youtubeTranscribeTask != nil { return true }
        if youtubeSubsTask != nil { return true }
        return false
    }

    private func teardownActiveCapture() {
        stopSilenceWatch()
        stopRecordingLevelObserver()
        streamingConsumer?.cancel()
        streamingConsumer = nil
        if let s = streamingSession {
            streamingSession = nil
            Task { await s.stop() }
        }
        if let source = liveSource {
            liveSource = nil
            Task { await source.cancel() }
        }
        Task { await mediaSession.exitRecording() }
        pendingRecordingCategory = .transcription
    }

    func cancelCurrentWork() {
        let hadWork = canCancel || liveSource != nil
        cancelAllInFlightBatchJobs()
        deferredArrivals = []
        downloadTask?.cancel()
        downloadTask = nil
        fileTranscribeTask?.cancel()
        fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel()
        youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel()
        youtubeSubsTask = nil
        teardownActiveCapture()
        if hadWork || phase != .ready { phase = .idle }
    }

    func cancelAllTasks() {
        countdownTask?.cancel(); countdownTask = nil
        batchTask?.cancel(); batchTask = nil
        matchesDebounce?.cancel(); matchesDebounce = nil
        recordingLevelTask?.cancel(); recordingLevelTask = nil
        silenceWatchTask?.cancel(); silenceWatchTask = nil
        recordingAutoStopTask?.cancel(); recordingAutoStopTask = nil
        searchTask?.cancel(); searchTask = nil
        downloadTask?.cancel(); downloadTask = nil
        fileTranscribeTask?.cancel(); fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel(); youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel(); youtubeSubsTask = nil
        teardownActiveCapture()
    }

    func unloadTranscriptionSession() async {
        await session.unloadModel()
    }

    @ObservationIgnored private var testBridge: ParolaAutomationServer?
    private(set) var automationBridgeRunning: Bool = false
    private(set) var automationBridgePort: UInt16?

    var automationBridgeEnabled: Bool = AppModel.defaultBridgeEnabled { didSet { defaults.set(automationBridgeEnabled, forKey: "automationBridgeEnabled") } }

    static var defaultBridgeEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Sparkle

    var sparkleChannelRaw: String = SparkleChannel.stable.rawValue {
        didSet { if !isReloadingSettings { applySparkleChannelChange() }; defaults.set(sparkleChannelRaw, forKey: "sparkleChannel") }
    }

    var sparkleAutomatic: Bool = true {
        didSet { if !isReloadingSettings { SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic }; defaults.set(sparkleAutomatic, forKey: "sparkleAutomatic") }
    }

    var sparkleChannel: SparkleChannel {
        SparkleChannel(rawValue: sparkleChannelRaw) ?? .stable
    }

    private func applySparkleChannelChange() {
        SparkleUpdater.shared.channel = sparkleChannel
    }

    // MARK: - Live captions translation

    var liveCaptionsTranslate: Bool = false {
        didSet { if !isReloadingSettings { applyLiveCaptionsTranslateChange() }; defaults.set(liveCaptionsTranslate, forKey: "liveCaptionsTranslate") }
    }

    private func applyLiveCaptionsTranslateChange() {
        let enabled = liveCaptionsTranslate
        Task { await liveCaptions?.setTranslate(enabled) }
    }

    func startAutomationBridge() {
        guard testBridge == nil else { return }
        guard let bridge = try? ParolaAutomationServer(model: self, auditLog: AutomationAuditLog()) else { return }
        bridge.start { [weak self] port in
            self?.automationBridgePort = port
        }
        testBridge = bridge
        automationBridgeRunning = true
    }

    func stopAutomationBridge() {
        testBridge?.stop()
        testBridge = nil
        automationBridgeRunning = false
        automationBridgePort = nil
    }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let filePicker: FilePicker
    @ObservationIgnored let mode: AppBootstrap.Mode
    @ObservationIgnored let clock: any Clock<Duration>

    // MARK: - Bootstrap

    init(bootstrap: AppBootstrap) {
        let defaults = bootstrap.defaults
        self.defaults = defaults
        self.filePicker = bootstrap.filePicker
        self.mode = bootstrap.mode
        self.clock = bootstrap.clock
        self.library = LibraryStore(libraryURL: bootstrap.library ?? LibraryStore.defaultLibraryURL)
        // Suppress the settings didSets during the bulk read: side effects (notably startDictation)
        // must wait until after wireDictationController + the gated side-effect block below, or the
        // dictation coordinator is built before appModel is wired.
        isReloadingSettings = true
        self.dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        self.dictationModeRaw = defaults.string(forKey: "dictationModeRaw") ?? DictationMode.pushToTalk.rawValue
        self.dictationKeyCode = defaults.object(forKey: "dictationKeyCode") == nil ? 96 : defaults.integer(forKey: "dictationKeyCode")
        self.dictationKeyModifiers = defaults.object(forKey: "dictationKeyModifiers") == nil ? 0 : defaults.integer(forKey: "dictationKeyModifiers")
        self.dictationIndicatorStyleRaw = defaults.string(forKey: "dictationIndicatorStyleRaw") ?? DictationIndicatorStyle.overlay.rawValue
        self.dictationCleanupPromptID = defaults.string(forKey: "dictationCleanupPromptID") ?? ""
        self.dictationPerAppOverridesJSON = defaults.string(forKey: "dictationPerAppOverridesJSON") ?? "{}"
        self.transcriptDisplayModeRaw = defaults.string(forKey: "transcriptDisplayMode") ?? TranscriptDisplayMode.transcript.rawValue
        self.useStreaming = readBool("useStreaming", default: true)
        self.wordTimestamps = defaults.bool(forKey: "wordTimestamps")
        self.karaokeHighlight = readBool("karaokeHighlight", default: true)
        self.initialPrompt = defaults.string(forKey: "initialPrompt") ?? ""
        self.diarize = defaults.bool(forKey: "diarize")
        self.autoTitleEntries = defaults.bool(forKey: "autoTitleEntries")
        self.subtitleFPS = readDouble("subtitleFPS", default: 30)
        self.subtitleCaptionLengthRaw = defaults.string(forKey: "subtitleCaptionLength") ?? CaptionLength.none.rawValue
        self.transcriptCompact = defaults.bool(forKey: "transcriptCompact")
        self.skipSilences = defaults.bool(forKey: "skipSilences")
        self.pausePlayerOnAppHidden = defaults.bool(forKey: "pausePlayerOnAppHidden")
        self.markdownTimestamps = defaults.bool(forKey: "markdownTimestamps")
        self.htmlExportThemeRaw = defaults.string(forKey: "htmlExportTheme") ?? HtmlExportTheme.light.rawValue
        self.dictationHudOpacity = readDouble("dictationHudOpacity", default: 1.0)
        self.lastFindQuery = defaults.string(forKey: "lastFindQuery") ?? ""
        self.userPrivacyMode = defaults.bool(forKey: "parola.userPrivacyMode")
        self.pinnedModel = defaults.string(forKey: "pinnedModel") ?? ""
        self.mainWindowAlwaysOnTop = defaults.bool(forKey: "mainWindowAlwaysOnTop")
        self.recentFilesRaw = defaults.string(forKey: "recentFiles") ?? "[]"
        self.micHotkeyKeyCode = readInt("micHotkeyKeyCode", default: 15)
        self.micHotkeyModifiers = readInt("micHotkeyModifiers", default: 786721)
        self.micHotkeyEnabled = defaults.bool(forKey: "micHotkeyEnabled")
        self.dictationStripSelfCorrections = defaults.bool(forKey: "dictationStripSelfCorrections")
        self.dictationPasteDelayMs = defaults.integer(forKey: "dictationPasteDelayMs")
        self.dictationContextSelection = defaults.bool(forKey: "dictationContextSelection")
        self.dictationContextClipboard = defaults.bool(forKey: "dictationContextClipboard")
        self.dictationContextScreen = defaults.bool(forKey: "dictationContextScreen")
        self.recordingMaxMinutes = defaults.integer(forKey: "recordingMaxMinutes")
        self.showMenuBarExtra = defaults.bool(forKey: "showMenuBarExtra")
        self.recordingCountInSeconds = defaults.integer(forKey: "recordingCountInSeconds")
        self.autoMuteWhileRecording = defaults.bool(forKey: "autoMuteWhileRecording")
        self.autoPauseMediaWhileRecording = defaults.bool(forKey: "autoPauseMediaWhileRecording")
        self.batchExportFormatsRaw = defaults.string(forKey: "batchExportFormats") ?? "txt,srt"
        self.batchExportToSourceFolder = readBool("batchExportToSourceFolder", default: true)
        self.batchExportIncludeTimestamps = defaults.bool(forKey: "batchExportIncludeTimestamps")
        self.batchExportFormatOptionsJSON = defaults.string(forKey: "batchExportFormatOptions") ?? "{}"
        self.inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "openai_whisper-tiny"
        self.selectedLanguageRaw = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        self.translate = defaults.bool(forKey: "translate")
        self.appTheme = defaults.string(forKey: "appTheme") ?? "system"
        self.monospacedTimestamps = readBool("monospacedTimestamps", default: true)
        self.sidebarDensity = defaults.string(forKey: "sidebarDensity") ?? "comfortable"
        self.appAccentRaw = defaults.string(forKey: AppAccent.storageKey) ?? AppAccent.terracotta.rawValue
        self.themeIsCustom = defaults.bool(forKey: "themeIsCustom")
        self.themeCustomPaletteJSON = defaults.string(forKey: "themeCustomPaletteJSON") ?? ""
        self.automationBridgeEnabled = readBool("automationBridgeEnabled", default: AppModel.defaultBridgeEnabled)
        self.sparkleChannelRaw = defaults.string(forKey: "sparkleChannel") ?? SparkleChannel.stable.rawValue
        self.sparkleAutomatic = readBool("sparkleAutomatic", default: true)
        self.liveCaptionsTranslate = defaults.bool(forKey: "liveCaptionsTranslate")
        isReloadingSettings = false
        applyTheme()
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        loadSnippets()
        loadCorrectionRules()
        refreshModelList()
        refreshLibrary()
        wireDictationController()

        let sideEffects = bootstrap.sideEffects
        self.activeSideEffects = sideEffects
        if sideEffects.contains(.refreshYtDlp) {
            refreshYtDlpAvailability()
        }
        if sideEffects.contains(.watchedFolders) {
            _ = watchedFolders
        }
        if sideEffects.contains(.meetingDetector) {
            _ = meetingDetector
        }
        if sideEffects.contains(.dictationHotkey), dictationEnabled {
            startDictation()
        }
        if sideEffects.contains(.sparkle) {
            SparkleUpdater.shared.channel = sparkleChannel
            SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic
        }
        if sideEffects.contains(.liveCaptionsTranslateRestore) {
            let initialTranslate = liveCaptionsTranslate
            Task { [weak self] in await self?.liveCaptions?.setTranslate(initialTranslate) }
        }
        if sideEffects.contains(.automationBridge), automationBridgeEnabled {
            startAutomationBridge()
        }
        if sideEffects.contains(.libraryPurgeOnLaunch) {
            Task { [weak self, library] in
                await library.purgeDeletedOlderThan(days: AppModel.trashRetentionDays, now: Date())
                self?.refreshLibrary()
            }
        }
        Task { [weak self] in
            await self?.refreshDictationTriggerPrompts()
        }
    }

    convenience init(
        skipBootstrap: Bool = false,
        defaults: UserDefaults = .standard,
        filePicker: FilePicker = SystemFilePicker(),
        libraryURL: URL? = nil
    ) {
        let sideEffects: Set<BootstrapSideEffect> = skipBootstrap ? [] : BootstrapSideEffect.all
        let bootstrap = AppBootstrap(
            mode: .normal,
            library: libraryURL,
            defaultsOverride: defaults,
            sideEffects: sideEffects,
            filePicker: filePicker
        )
        self.init(bootstrap: bootstrap)
    }

    deinit {
        recordingLevelTask?.cancel()
        streamingConsumer?.cancel()
        libraryRefreshTask?.cancel()
    }

    /// A non-fatal warning (e.g. a failed library save) shown without replacing the open transcript.
    var nonFatalWarning: String?

    func persistToLibrary(_ result: Transcript, audioSource: URL?) {
        let category = pendingRecordingCategory
        pendingRecordingCategory = .transcription
        Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await library.add(
                    transcript: result,
                    audioSource: audioSource,
                    category: category
                )
                refreshLibrary()
                selectedEntryID = entry.id
                if autoTitleEntries {
                    autoTitleEntry(entry.id, transcript: result)
                }
            } catch {
                nonFatalWarning = "The transcript is still open, but Parola couldn't save it to your library. \(error.localizedDescription)"
            }
            if let audioSource {
                runAutoExports(transcript: result, sourceURL: audioSource)
            }
        }
    }

    // MARK: - Model list

    var modelSizes: [String: Int64] = [:]
    var modelsBeingDeleted: Set<String> = []

    func refreshModelList() {
        let curated = store.catalog()
        let extra = (try? store.installedModels())?.filter { ent in
            !curated.contains { $0.name == ent.name }
        } ?? []
        availableModels = curated + extra

        if !availableModels.contains(where: { $0.name == selectedModel }) {
            selectedModel = availableModels.first?.name ?? "openai_whisper-tiny"
        }
        refreshModelSizes()
    }

    func refreshModelSizes() {
        let names = availableModels.filter(\.isInstalled).map(\.name)
        let store = self.store
        Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for name in names {
                if let size = store.sizeOnDisk(name) {
                    sizes[name] = Int64(size)
                }
            }
            await MainActor.run { [weak self] in
                self?.modelSizes = sizes
            }
        }
    }

    func deleteModel(_ name: String) {
        guard !modelsBeingDeleted.contains(name) else { return }
        modelsBeingDeleted.insert(name)
        let store = self.store
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Void, Error>
            do {
                try store.deleteAny(idOrPath: name)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard let self else { return }
                self.modelsBeingDeleted.remove(name)
                switch result {
                case .success:
                    self.refreshModelList()
                case .failure(let error):
                    self.phase = .failed(message: "Could not delete \(name): \(error.localizedDescription)")
                }
            }
        }
    }

    func prewarmSelectedModel() {
        let name = selectedModel
        guard store.isInstalled(name) else { return }
        Task.detached { [session] in
            await session.prewarm(modelName: name)
        }
    }

    func downloadModel(_ name: String) {
        let progress = makeDownloadProgressHandler(for: name)
        downloadTask?.cancel()
        downloadTask = Task {
            do {
                phase = .downloadingModel(name: name, progress: 0)
                _ = try await store.download(variant: name, progress: progress)
                phase = .idle
                refreshModelList()
            } catch {
                if !Task.isCancelled { phase = .failed(message: "Download failed: \(error.localizedDescription)") }
            }
            if !Task.isCancelled { downloadTask = nil }
        }
    }

    // MARK: - File transcription

    func presentOpenPanel() {
        Task { [weak self] in
            guard let self else { return }
            let urls = await self.filePicker.chooseInputFiles(allowedTypes: [.audio, .movie], allowsMultiple: true)
            guard !urls.isEmpty else { return }
            if urls.count == 1 {
                self.transcribe(fileURL: urls[0])
            } else {
                self.startBatch(urls: urls)
            }
        }
    }

    func transcribe(fileURL: URL, translateOverride: Bool? = nil) {
        // Arrivals must never stomp an active capture or batch (drops, watched folders, Services, URL scheme).
        if case .recording = phase {
            deferredArrivals.append(fileURL)
            return
        }
        if fileURL.pathExtension == "parola" {
            Task { [weak self] in await self?.openProjectDocument(at: fileURL) }
            return
        }
        if batchIsRunning {
            addBatchFiles([fileURL])
            return
        }
        noteRecentFile(fileURL)
        sourceFileURL = fileURL
        installPlayer(for: fileURL)
        let probeSource = FileAudioSource(url: fileURL)
        Task { [weak self] in
            let duration = await Task.detached { probeSource.synchronousDuration() }.value
            guard let self, let duration, self.sourceFileURL == fileURL else { return }
            if self.pendingMediaDuration == nil { self.pendingMediaDuration = duration }
        }
        filePartialText = ""
        fileTranscribeFraction = nil

        let task: TranscriptionTask = (translateOverride ?? translate) ? .translate : .transcribe

        fileTranscribeTask?.cancel()
        fileTranscribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loadingModel(name: selectedModel)
                if !store.isInstalled(selectedModel) {
                    phase = .downloadingModel(name: selectedModel, progress: 0)
                }

                phase = .transcribing(file: fileURL)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: fileURL),
                    options: makeOptions(task: task),
                    downloadProgress: makeDownloadProgressHandler(for: selectedModel),
                    partialHandler: makeFilePartialHandler(),
                    progressHandler: makeFileProgressHandler()
                )
                try Task.checkCancellation()
                let processed = await postProcessDetached(result)
                selectedEntryID = nil
                transcript = processed
                filePartialText = ""
                fileTranscribeFraction = nil
                phase = .ready
                persistToLibrary(processed, audioSource: fileURL)
            } catch {
                filePartialText = ""
                fileTranscribeFraction = nil
                if !Task.isCancelled { applyTranscriptionError(error) }
            }
            if !Task.isCancelled { self.fileTranscribeTask = nil }
        }
    }

    private func makeFilePartialHandler() -> @Sendable (String) -> Void {
        return { [weak self] text in
            Task { @MainActor in
                guard let self, self.filePartialText != text else { return }
                self.filePartialText = text
            }
        }
    }

    var currentOptions: TranscriptionOptions {
        makeOptions(task: translate ? .translate : .transcribe)
    }

    private func makeOptions(task: TranscriptionTask) -> TranscriptionOptions {
        TranscriptionOptions(
            model: selectedModel,
            language: selectedLanguage,
            task: task,
            wordTimestamps: wordTimestamps,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt,
            diarize: diarize
        )
    }

    @MainActor private final class DownloadProgressThrottle {
        var lastPercent = -1
    }

    private func makeDownloadProgressHandler(for modelName: String) -> @Sendable (Double) -> Void {
        let throttle = DownloadProgressThrottle()
        return { [weak self] frac in
            let percent = Int(frac * 100)
            Task { @MainActor [weak self] in
                guard let self, percent != throttle.lastPercent else { return }
                throttle.lastPercent = percent
                self.phase = .downloadingModel(name: modelName, progress: frac)
            }
        }
    }

    @MainActor private final class FileProgressThrottle {
        var lastPercent = -1
        var lastFraction: Double = 0
    }

    private func makeFileProgressHandler() -> @Sendable (Double) -> Void {
        let throttle = FileProgressThrottle()
        return { [weak self] seconds in
            Task { @MainActor [weak self] in
                guard let self, let duration = self.pendingMediaDuration, duration > 0 else { return }
                let fraction = min(1, max(throttle.lastFraction, seconds / duration))
                let percent = Int(fraction * 100)
                guard percent != throttle.lastPercent else { return }
                throttle.lastPercent = percent
                throttle.lastFraction = fraction
                self.fileTranscribeFraction = fraction
            }
        }
    }

    // MARK: - YouTube URL

    var youtubeSheetOpen: Bool = false
    var ytDlpAvailable: Bool = false
    var ytDlpInstalling: Bool = false
    var ytDlpInstallError: String?

    func refreshYtDlpAvailability() {
        ytDlpAvailable = YtDlpInstaller.locate() != nil
    }

    func installYtDlpViaBrew() {
        guard !ytDlpInstalling else { return }
        guard let brew = YtDlpInstaller.locateBrew() else {
            ytDlpInstallError = "Homebrew isn't installed. Install it from https://brew.sh, then try again."
            return
        }
        ytDlpInstalling = true
        ytDlpInstallError = nil
        Task { [weak self] in
            let outcome = await YtDlpInstaller.install(formula: "yt-dlp", brewPath: brew)
            guard let self else { return }
            self.ytDlpInstalling = false
            switch outcome {
            case .success:
                self.refreshYtDlpAvailability()
                if !self.ytDlpAvailable {
                    self.ytDlpInstallError = "Homebrew finished, but yt-dlp still isn't on the expected path."
                }
            case .failure(let message):
                self.ytDlpInstallError = message
            }
        }
    }

    func transcribeYouTube(urlString: String) {
        guard let url = makeYouTubeURL(urlString) else { return }

        youtubeTranscribeTask?.cancel()
        youtubeTranscribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                phase = .downloadingModel(name: "youtube", progress: 0)
                let fetcher = MediaFetcherFactory.make()
                let audioURL = try await fetcher.prepare(url: url)
                try Task.checkCancellation()
                sourceFileURL = audioURL
                installPlayer(for: audioURL)

                phase = .transcribing(file: audioURL)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler(for: selectedModel)
                )
                try Task.checkCancellation()
                let processed = await postProcessDetached(result)
                selectedEntryID = nil
                transcript = processed
                phase = .ready
                persistToLibrary(processed, audioSource: audioURL)
            } catch {
                if !Task.isCancelled { applyTranscriptionError(error) }
            }
            if !Task.isCancelled { self.youtubeTranscribeTask = nil }
        }
    }

    func fetchYouTubeSubs(urlString: String) {
        guard let url = makeYouTubeURL(urlString) else { return }

        youtubeSubsTask?.cancel()
        youtubeSubsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                phase = .transcribing(file: url)
                let result = try await YouTubeSubsFetcher.fetch(url: url, preferLanguage: selectedLanguage)
                try Task.checkCancellation()
                let processed = await postProcessDetached(result)
                selectedEntryID = nil
                transcript = processed
                phase = .ready
                persistToLibrary(processed, audioSource: nil)
            } catch {
                if !Task.isCancelled { applyTranscriptionError(error) }
            }
            if !Task.isCancelled { self.youtubeSubsTask = nil }
        }
    }

    private func makeYouTubeURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString), url.isYtDlpSupported else {
            phase = .failed(message: Self.unsupportedURLMessage())
            return nil
        }
        youtubeSheetOpen = false
        return url
    }

    private func applyTranscriptionError(_ error: Error) {
        if error is CancellationError || Task.isCancelled {
            phase = .idle
        } else {
            phase = .failed(message: Self.transcriptionFailureMessage(for: error))
        }
    }

    nonisolated static func transcriptionFailureMessage(for error: Error, bundle: Bundle = .main) -> String {
        if case ParolaError.transcriptionFailed(let reason) = error {
            return String(localized: "Transcription failed: \(reason)", bundle: bundle)
        }
        return error.localizedDescription
    }

    nonisolated static func unsupportedURLMessage(bundle: Bundle = .main) -> String {
        String(localized: "That URL isn't on a host yt-dlp can fetch.", bundle: bundle)
    }

    nonisolated static func exportFailureMessage(for error: Error, bundle: Bundle = .main) -> String {
        String(localized: "Export failed: \(error.localizedDescription)", bundle: bundle)
    }

    nonisolated static func recordingFailureMessage(
        for error: Error,
        source: RecordSource,
        screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess(),
        bundle: Bundle = .main
    ) -> String {
        if source == .systemAudio, case ParolaError.captureUnavailable = error, !screenRecordingGranted {
            return String(
                localized: "Parola needs Screen Recording permission to capture system audio. Open System Settings → Privacy & Security → Screen Recording and grant Parola access, then start recording again.",
                bundle: bundle
            )
        }
        return transcriptionFailureMessage(for: error, bundle: bundle)
    }

    nonisolated static func microphoneAccessOffMessage(bundle: Bundle = .main) -> String {
        String(
            localized: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone, then start recording again.",
            bundle: bundle
        )
    }

    nonisolated static func transcriptDisplayTitle(
        sourceFileURL: URL?,
        entry: LibraryEntry?,
        fallback: String
    ) -> String {
        if let entry, sourceBelongsToEntry(sourceFileURL, bundleURL: entry.bundleURL) {
            return entry.title
        }
        if let sourceFileURL {
            return sourceFileURL.deletingPathExtension().lastPathComponent
        }
        return entry?.title ?? fallback
    }

    private nonisolated static func sourceBelongsToEntry(_ source: URL?, bundleURL: URL) -> Bool {
        guard let source else { return false }
        // Match the entry's unique <id>.parola bundle by name; a full-path compare breaks on the test sandbox's /tmp symlink.
        return source.deletingLastPathComponent().lastPathComponent == bundleURL.lastPathComponent
    }

    func dismissError() {
        phase = .idle
    }

    var cacheDirectoryDisplayPath: String {
        ModelStore.shared.directory.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func revealCacheDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([ModelStore.shared.directory])
    }

    // MARK: - Recording

    func startRecording(source: RecordSource) {
        let countIn = max(0, recordingCountInSeconds)
        if countIn > 0 {
            beginCountIn(seconds: countIn) { [weak self] in
                self?.beginRecordingNow(source: source)
            }
        } else {
            beginRecordingNow(source: source)
        }
    }

    private func beginCountIn(seconds: Int, then: @escaping () -> Void) {
        countdownTask?.cancel()
        recordingCountdown = seconds
        let clock = clock
        countdownTask = Task { @MainActor [weak self] in
            for value in stride(from: seconds, to: 0, by: -1) {
                guard !Task.isCancelled else { return }
                self?.recordingCountdown = value
                try? await Task.sleep(for: .seconds(1), clock: clock)
            }
            guard !Task.isCancelled else { return }
            self?.recordingCountdown = nil
            then()
        }
    }

    func cancelRecordingCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        recordingCountdown = nil
    }

    /// The streaming mic path drives WhisperKit off the live mic and never consults
    /// MockAudioSourceRegistry. With a mic fixture installed (test-mode) we must avoid it and take the
    /// file-capture path instead, so the fixture transcribes the same way system audio does.
    func shouldUseStreamingMic() async -> Bool {
        guard useStreaming else { return false }
        return await MockAudioSourceRegistry.shared.resolve(for: .mic) == nil
    }

    private func beginRecordingNow(source: RecordSource) {
        let config = mediaSessionConfig(allowMute: source == .microphone)
        Task {
            if source == .microphone, mode == .normal, await AVCaptureDevice.requestAccess(for: .audio) == false {
                phase = .failed(message: Self.microphoneAccessOffMessage())
                return
            }
            if source == .microphone, await shouldUseStreamingMic() {
                startStreamingMic()
                return
            }
            await mediaSession.enterRecording(config: config)
            do {
                phase = .recording(source: source)
                switch source {
                case .microphone:
                    let mic = await LiveAudioSourceFactory.makeMicrophone(
                        deviceUID: preferredInputDeviceUID,
                        clock: clock
                    )
                    try await mic.start()
                    liveSource = mic
                    observeRecordingLevels(from: mic)
                case .systemAudio:
                    let sys = await LiveAudioSourceFactory.makeSystem(clock: clock)
                    try await sys.start()
                    liveSource = sys
                    observeRecordingLevels(from: sys)
                }
                scheduleRecordingAutoStop()
            } catch {
                await mediaSession.exitRecording()
                phase = .failed(message: Self.recordingFailureMessage(for: error, source: source))
                drainDeferredArrivals()
            }
        }
    }

    private func scheduleRecordingAutoStop() {
        recordingAutoStopTask?.cancel()
        let limit = recordingMaxMinutes
        guard limit > 0 else { return }
        let clock = clock
        recordingAutoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit * 60), clock: clock)
            guard !Task.isCancelled, let self else { return }
            guard case .recording = self.phase else { return }
            self.stopRecordingAndTranscribe()
        }
    }

    private func observeRecordingLevels(from source: any LiveAudioSource) {
        recordingLevelTask?.cancel()
        let subject = recordingAudioLevel
        recordingLevelTask = Task { @MainActor in
            let stream = await source.levels()
            for await value in stream {
                if abs(subject.value - value) > 0.05 {
                    subject.send(value)
                }
            }
        }
    }

    private func stopRecordingLevelObserver() {
        recordingLevelTask?.cancel()
        recordingLevelTask = nil
        recordingAudioLevel.send(0)
    }

    private func updateSilenceFlag() {
        let alert = silenceDetector.shouldAlert()
        if recordingIsSilent != alert { recordingIsSilent = alert }
    }

    private func startSilenceWatch() {
        stopSilenceWatch()
        silenceDetector.reset()
        recordingIsSilent = false
        let clock = clock
        silenceWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750), clock: clock)
                if Task.isCancelled { return }
                self?.updateSilenceFlag()
            }
        }
    }

    private func stopSilenceWatch() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        silenceDetector.reset()
        recordingIsSilent = false
    }

    private func startStreamingMic() {
        streamingConsumer?.cancel()
        let s = StreamingTranscriberFactory.make(clock: clock)
        streamingSession = s
        liveSegments = []
        livePartialText = ""
        liveVoiceActive = false
        phase = .recording(source: .microphone)
        startSilenceWatch()
        scheduleRecordingAutoStop()

        let opts = currentOptions
        let progress = makeDownloadProgressHandler(for: selectedModel)
        let config = mediaSessionConfig(allowMute: true)

        streamingConsumer = Task { @MainActor in
            await mediaSession.enterRecording(config: config)
            do {
                let events = try await s.start(options: opts, speakerLabeler: nil, downloadProgress: progress)
                phase = .recording(source: .microphone)
                for await event in events {
                    await handleStreamingEvent(event)
                }
            } catch {
                teardownStreaming()
                phase = .failed(message: Self.transcriptionFailureMessage(for: error))
                drainDeferredArrivals()
            }
            await mediaSession.exitRecording()
        }
    }

    /// Stops and clears the live streaming session, its consumer, and the silence watch.
    /// Without this a failed stream left the audio engine and observers running.
    private func teardownStreaming() {
        streamingConsumer?.cancel()
        streamingConsumer = nil
        if let session = streamingSession {
            streamingSession = nil
            Task { await session.stop() }
        }
        stopSilenceWatch()
    }

    func handleStreamingEvent(_ event: StreamingEvent) async {
        switch event {
        case .partial(let text):
            if livePartialText != text { livePartialText = text }
        case .confirmed(let segment):
            liveSegments.append(segment)
            if !livePartialText.isEmpty { livePartialText = "" }
        case .voiceActivity(let active):
            if liveVoiceActive != active { liveVoiceActive = active }
            silenceDetector.note(active: active)
            updateSilenceFlag()
        case .warning:
            break
        case .failed(let msg):
            teardownStreaming()
            phase = .failed(message: msg)
            drainDeferredArrivals()
        case .finished(let transcript):
            let processed = await postProcessDetached(transcript)
            self.selectedEntryID = nil
            self.transcript = processed
            self.livePartialText = ""
            self.liveSegments = []
            self.phase = .ready
            persistToLibrary(processed, audioSource: nil)
            drainDeferredArrivals()
        }
    }

    func stopRecordingAndTranscribe() {
        recordingAutoStopTask?.cancel()
        recordingAutoStopTask = nil
        if let s = streamingSession {
            Task { @MainActor in
                await s.stop()
                streamingSession = nil
                // Await delivery of the final .finished event; cancelling here can drop the whole recording.
                await streamingConsumer?.value
                streamingConsumer = nil
                stopRecordingLevelObserver()
                stopSilenceWatch()
            }
            return
        }

        guard let source = liveSource else { return }
        // Hand off synchronously so a racing auto-stop or second click can't start a duplicate run.
        liveSource = nil
        fileTranscribeTask = Task {
            await mediaSession.exitRecording()
            do {
                let url = try await source.prepare()
                stopRecordingLevelObserver()
                sourceFileURL = url
                installPlayer(for: url)

                phase = .transcribing(file: url)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: url),
                    options: currentOptions
                )
                let processed = await postProcessDetached(result)
                selectedEntryID = nil
                transcript = processed
                phase = .ready
                persistToLibrary(processed, audioSource: url)
                drainDeferredArrivals()
            } catch {
                stopRecordingLevelObserver()
                phase = .failed(message: Self.transcriptionFailureMessage(for: error))
                drainDeferredArrivals()
            }
        }
    }

    // MARK: - Editing

    func editSegment(id: TranscriptSegment.ID, newText: String) {
        guard var t = transcript else { return }
        guard let idx = t.segments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != t.segments[idx].text else { return }
        t.segments[idx].text = trimmed
        t.segments[idx].words = nil
        transcript = t
        persistCurrentTranscriptIfLoaded()
    }

    func deleteSegment(id: TranscriptSegment.ID) {
        guard var t = transcript else { return }
        let before = t.segments.count
        t.segments.removeAll { $0.id == id }
        guard t.segments.count != before else { return }
        transcript = t
        persistCurrentTranscriptIfLoaded()
    }

    func nudgeSegmentStart(id: TranscriptSegment.ID, frames: Int) {
        guard var t = transcript else { return }
        t.segments = SegmentTimingNudge.nudgeStart(
            segments: t.segments, id: id, frameDelta: frames, fps: subtitleFPS
        )
        transcript = t
        persistCurrentTranscriptIfLoaded(textChanged: false)
    }

    func nudgeSegmentEnd(id: TranscriptSegment.ID, frames: Int) {
        guard var t = transcript else { return }
        t.segments = SegmentTimingNudge.nudgeEnd(
            segments: t.segments, id: id, frameDelta: frames, fps: subtitleFPS
        )
        transcript = t
        persistCurrentTranscriptIfLoaded(textChanged: false)
    }

    /// Schedules a debounced (~1 s) persist of the current transcript. Rapid edits coalesce: only the
    /// latest snapshot (identified by the generation counter) is written; earlier tasks cancel themselves.
    func persistCurrentTranscriptIfLoaded(textChanged: Bool = true) {
        guard let id = selectedEntryID, let transcript else { return }
        pendingTranscriptSaveGeneration &+= 1
        let generation = pendingTranscriptSaveGeneration
        pendingTranscriptSaveTask?.cancel()
        let clock = clock
        pendingTranscriptSaveTask = Task { [weak self, library] in
            try? await Task.sleep(for: .seconds(1), clock: clock)
            guard !Task.isCancelled else { return }
            guard await self?.pendingTranscriptSaveGeneration == generation else { return }
            try? await library.updateTranscript(transcript, for: id, reindex: textChanged)
            await MainActor.run { [weak self] in
                if self?.pendingTranscriptSaveGeneration == generation {
                    self?.pendingTranscriptSaveTask = nil
                }
            }
        }
    }

    /// Flushes any pending debounced transcript write immediately. Call at entry-switch or batch-select.
    func flushPendingTranscriptSave() async {
        guard let id = selectedEntryID, let transcript else {
            pendingTranscriptSaveTask?.cancel()
            pendingTranscriptSaveTask = nil
            return
        }
        pendingTranscriptSaveTask?.cancel()
        pendingTranscriptSaveTask = nil
        try? await library.updateTranscript(transcript, for: id)
    }

    /// Synchronously cancels any pending debounced save and returns the snapshot to write.
    /// Used by AppDelegate.applicationWillTerminate, which cannot await async functions.
    func cancelAndDrainPendingTranscriptSave() -> (id: LibraryEntry.ID, transcript: Transcript)? {
        pendingTranscriptSaveTask?.cancel()
        pendingTranscriptSaveTask = nil
        guard let id = selectedEntryID, let transcript else { return nil }
        return (id, transcript)
    }

    // MARK: - Find & replace

    func toggleFind() {
        findIsOpen.toggle()
        if findIsOpen {
            if findQuery.isEmpty, !lastFindQuery.isEmpty {
                findQuery = lastFindQuery
            }
        } else {
            findQuery = ""
            matches = []
            currentMatchIndex = 0
        }
    }

    // MARK: - Project document

    func openProjectDocument(at url: URL) async {
        do {
            let doc = try await Task.detached { try ParolaDocument.read(at: url) }.value
            sourceFileURL = doc.audioURL
            transcript = doc.transcript
            if let audio = doc.audioURL {
                installPlayer(for: audio)
            } else {
                tearDownPlayer()
            }
            phase = .ready
            recomputeMatches()
        } catch {
            phase = .failed(message: "Couldn't open document: \(error.localizedDescription)")
        }
    }

    func saveProjectDocument() {
        guard let transcript, let sourceFileURL else { return }
        let suggested = sourceFileURL.deletingPathExtension().lastPathComponent + ".parola"
        Task { [weak self] in
            guard let self else { return }
            guard let dest = await self.filePicker.chooseSaveDestination(suggestedName: suggested, allowedTypes: []) else { return }
            do {
                try await Task.detached { _ = try ParolaDocument.write(transcript: transcript, audioURL: sourceFileURL, to: dest) }.value
            } catch {
                self.phase = .failed(message: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Summary

    var isSummarising: Bool = false
    var summaryError: String?
    @ObservationIgnored private var summaryGeneration: Int = 0
    /// Test seam: when set, replaces the on-device SummaryService so summarise timing is deterministic.
    @ObservationIgnored var summariseOperation: (@Sendable (Transcript) async throws -> Summary)?

    func summariseTranscript() {
        guard let transcript, !isSummarising else { return }
        isSummarising = true
        summaryError = nil
        summaryGeneration &+= 1
        let generation = summaryGeneration
        let snapshot = transcript
        let entryID = selectedEntryID
        let summarise = summariseOperation ?? { try await SummaryService().summarise($0) }
        Task { [weak self] in
            do {
                let summary = try await summarise(snapshot)
                guard let self, generation == summaryGeneration else { return }
                guard self.selectedEntryID == entryID else { isSummarising = false; return }
                self.transcript?.summary = summary
                isSummarising = false
            } catch {
                guard let self, generation == summaryGeneration else { return }
                summaryError = error.localizedDescription
                isSummarising = false
            }
        }
    }

    // MARK: - Burn subtitles into video

    func burnSubtitlesIntoVideo() {
        guard let transcript else { return }
        Task { [weak self] in
            guard let self else { return }
            let inputURLs = await self.filePicker.chooseInputFiles(
                allowedTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                allowsMultiple: false,
                message: "Pick the video to burn subtitles into."
            )
            guard let videoURL = inputURLs.first else { return }
            let suggested = videoURL.deletingPathExtension().lastPathComponent + " (captioned).mp4"
            guard let outputURL = await self.filePicker.chooseSaveDestination(
                suggestedName: suggested,
                allowedTypes: [.mpeg4Movie]
            ) else { return }

            let snapshot = transcript
            self.phase = .transcribing(file: outputURL)
            do {
                try await SubtitleBurner.burn(transcript: snapshot, video: videoURL, to: outputURL)
                self.phase = .ready
            } catch {
                self.phase = .failed(message: "Burn failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Export

    func exportRequest(_ format: ExportFormat) {
        guard transcript != nil else { return }
        pendingExport = format
    }

    func exportSegmentNotesAsMarkdown() {
        guard let transcript,
              let entryID = selectedEntryID,
              let entry = libraryEntry(id: entryID) else {
            return
        }
        let notes = entry.segmentNotes
        let title = entry.title
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.filePicker.chooseSaveDestination(
                suggestedName: "\(title)-notes.md",
                allowedTypes: [.plainText]
            ) else { return }
            let body = NotesMarkdownRenderer.render(transcript: transcript, notes: notes, title: title)
            try? body.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    func jumpToNextSpeaker() {
        guard let transcript, !transcript.segments.isEmpty else { return }
        let segments = transcript.segments
        let startIdx: Int
        if let current = currentSegmentID,
           let idx = segments.firstIndex(where: { $0.id == current }) {
            startIdx = idx
        } else {
            startIdx = -1
        }
        let currentSpeaker = startIdx >= 0 ? segments[startIdx].speaker : nil
        for offset in 1..<segments.count {
            let idx = (startIdx + offset) % segments.count
            if segments[idx].speaker != currentSpeaker, segments[idx].speaker != nil {
                seek(to: segments[idx])
                return
            }
        }
    }

    var currentTranscriptTitle: String {
        Self.transcriptDisplayTitle(
            sourceFileURL: sourceFileURL,
            entry: selectedEntryID.flatMap { libraryEntry(id: $0) },
            fallback: String(localized: "Transcript")
        )
    }

    func shareTranscriptViaMail() {
        guard let transcript else { return }
        let title = currentTranscriptTitle
        guard let url = TranscriptMail.mailtoURL(title: title, transcript: transcript) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyTranscriptToPasteboard(withTimestamps: Bool) {
        guard let transcript else { return }
        Task {
            let text = await Task.detached {
                withTimestamps ? TranscriptTimestampedText.render(transcript) : transcript.text
            }.value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func copyTranscriptAsFormat(_ format: ExportFormat) {
        guard let transcript else { return }
        let exporter = makeExporter(for: format)
        Task {
            guard let data = try? await Task.detached(operation: { try exporter.render(transcript) }).value,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func printTranscript() {
        guard let transcript else { return }
        let title = currentTranscriptTitle
        let attributed = Self.makePrintableAttributedString(for: transcript, title: title)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 36, height: 48)
        textView.textStorage?.setAttributedString(attributed)

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = title
        operation.run()
    }

    private static func makePrintableAttributedString(for transcript: Transcript, title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.labelColor,
        ]
        result.append(NSAttributedString(string: title + "\n\n", attributes: titleAttrs))

        let stampAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]
        let speakerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]

        for segment in transcript.segments {
            result.append(NSAttributedString(string: Timecode.format(segment.start) + "  ", attributes: stampAttrs))
            if let speaker = segment.speaker {
                result.append(NSAttributedString(string: speaker + ": ", attributes: speakerAttrs))
            }
            result.append(NSAttributedString(string: segment.text.trimmingCharacters(in: .whitespaces) + "\n\n", attributes: bodyAttrs))
        }
        return result
    }

    func performExport(_ format: ExportFormat) {
        guard let transcript else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.filePicker.chooseSaveDestination(
                suggestedName: "transcript.\(format.fileExtension)",
                allowedTypes: [.plainText]
            ) else { return }
            let exporter = self.makeExporter(for: format)
            do {
                try await Task.detached {
                    let data = try exporter.render(transcript)
                    try data.write(to: url, options: .atomic)
                }.value
            } catch {
                self.phase = .failed(message: Self.exportFailureMessage(for: error))
            }
        }
    }

    var subtitleCaptionLength: CaptionLength {
        CaptionLength(rawValue: subtitleCaptionLengthRaw) ?? .none
    }

    func makeExporter(for format: ExportFormat) -> TranscriptExporter {
        switch format {
        case .srt: return SrtExporter(options: SubtitleOptions(captionLength: subtitleCaptionLength))
        case .vtt: return VttExporter(options: SubtitleOptions(captionLength: subtitleCaptionLength))
        case .md:  return MarkdownExporter(options: MarkdownOptions(showTimestamps: markdownTimestamps))
        case .html:
            let theme = HtmlExportTheme(rawValue: htmlExportThemeRaw) ?? .light
            return HtmlExporter(options: HtmlOptions(theme: theme))
        default:   return Exporters.exporter(for: format)
        }
    }
}

