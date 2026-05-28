import Combine
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
    }

    enum Route: String, Hashable, CaseIterable {
        case transcript
        case batch
        case queue
    }

    var route: Route = .transcript
    var phase: Phase = .idle
    var transcript: Transcript? {
        didSet {
            let speakers = transcript?.uniqueSpeakers ?? []
            if speakers != transcriptSpeakers { transcriptSpeakers = speakers }
            transcriptVersion &+= 1
            if findIsOpen { scheduleRecomputeMatches() }
        }
    }
    private(set) var transcriptSpeakers: [String] = []
    private(set) var transcriptVersion: Int = 0
    var showingTrash: Bool = false
    var currentSegmentID: TranscriptSegment.ID?
    var currentWordID: WordTiming.ID?

    var liveSegments: [TranscriptSegment] = []
    var livePartialText: String = ""
    var liveVoiceActive: Bool = false
    var filePartialText: String = ""
    @ObservationIgnored @AppStorage("useStreaming", store: DefaultsStore.current) var useStreaming: Bool = true
    @ObservationIgnored @AppStorage("wordTimestamps", store: DefaultsStore.current) var wordTimestamps: Bool = false
    @ObservationIgnored @AppStorage("karaokeHighlight", store: DefaultsStore.current) var karaokeHighlight: Bool = true
    @ObservationIgnored @AppStorage("initialPrompt", store: DefaultsStore.current) var initialPrompt: String = ""
    @ObservationIgnored @AppStorage("diarize", store: DefaultsStore.current) var diarize: Bool = false
    @ObservationIgnored @AppStorage("subtitleFPS", store: DefaultsStore.current) var subtitleFPS: Double = 30
    @ObservationIgnored @AppStorage("subtitleCaptionLength", store: DefaultsStore.current) var subtitleCaptionLengthRaw: String = CaptionLength.none.rawValue
    @ObservationIgnored @AppStorage("transcriptCompact", store: DefaultsStore.current) var transcriptCompact: Bool = false
    @ObservationIgnored @AppStorage("skipSilences", store: DefaultsStore.current) var skipSilences: Bool = false
    @ObservationIgnored @AppStorage("pausePlayerOnAppHidden", store: DefaultsStore.current) var pausePlayerOnAppHidden: Bool = false
    @ObservationIgnored @AppStorage("markdownTimestamps", store: DefaultsStore.current) var markdownTimestamps: Bool = false
    @ObservationIgnored @AppStorage("htmlExportTheme", store: DefaultsStore.current) var htmlExportThemeRaw: String = HtmlExportTheme.light.rawValue
    @ObservationIgnored @AppStorage("dictationHudOpacity", store: DefaultsStore.current) var dictationHudOpacity: Double = 1.0
    @ObservationIgnored @AppStorage("lastFindQuery", store: DefaultsStore.current) var lastFindQuery: String = ""
    @ObservationIgnored @AppStorage("parola.userPrivacyMode", store: DefaultsStore.current) var userPrivacyMode: Bool = false
    @ObservationIgnored @AppStorage("pinnedModel", store: DefaultsStore.current) var pinnedModel: String = ""
    @ObservationIgnored @AppStorage("mainWindowAlwaysOnTop", store: DefaultsStore.current) var mainWindowAlwaysOnTop: Bool = false
    @ObservationIgnored @AppStorage("recentFiles", store: DefaultsStore.current) var recentFilesRaw: String = "[]"
    @ObservationIgnored @AppStorage("micHotkeyKeyCode", store: DefaultsStore.current) var micHotkeyKeyCode: Int = 15 // kVK_ANSI_R
    @ObservationIgnored @AppStorage("micHotkeyModifiers", store: DefaultsStore.current) var micHotkeyModifiers: Int = 786721 // ⌃⌥⌘
    @ObservationIgnored @AppStorage("micHotkeyEnabled", store: DefaultsStore.current) var micHotkeyEnabled: Bool = false
    @ObservationIgnored @AppStorage("dictationStripSelfCorrections", store: DefaultsStore.current) var dictationStripSelfCorrections: Bool = false
    @ObservationIgnored @AppStorage("dictationPasteDelayMs", store: DefaultsStore.current) var dictationPasteDelayMs: Int = 0
    @ObservationIgnored @AppStorage("dictationContextSelection", store: DefaultsStore.current) var dictationContextSelection: Bool = false
    @ObservationIgnored @AppStorage("dictationContextClipboard", store: DefaultsStore.current) var dictationContextClipboard: Bool = false
    @ObservationIgnored @AppStorage("dictationContextScreen", store: DefaultsStore.current) var dictationContextScreen: Bool = false
    @ObservationIgnored @AppStorage("recordingMaxMinutes", store: DefaultsStore.current) var recordingMaxMinutes: Int = 0
    @ObservationIgnored @AppStorage("showMenuBarExtra", store: DefaultsStore.current) var showMenuBarExtra: Bool = false
    @ObservationIgnored @AppStorage("recordingCountInSeconds", store: DefaultsStore.current) var recordingCountInSeconds: Int = 0
    @ObservationIgnored @AppStorage("autoMuteWhileRecording", store: DefaultsStore.current) var autoMuteWhileRecording: Bool = false
    @ObservationIgnored @AppStorage("autoPauseMediaWhileRecording", store: DefaultsStore.current) var autoPauseMediaWhileRecording: Bool = false
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

    @ObservationIgnored @AppStorage("batchExportFormats", store: DefaultsStore.current) var batchExportFormatsRaw: String = "txt,srt"
    @ObservationIgnored @AppStorage("batchExportToSourceFolder", store: DefaultsStore.current) var batchExportToSourceFolder: Bool = true
    @ObservationIgnored @AppStorage("batchExportIncludeTimestamps", store: DefaultsStore.current) var batchExportIncludeTimestamps: Bool = false
    @ObservationIgnored @AppStorage("batchExportFormatOptions", store: DefaultsStore.current) var batchExportFormatOptionsJSON: String = "{}"

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

    @ObservationIgnored @AppStorage("inputDeviceUID", store: DefaultsStore.current) var inputDeviceUID: String = ""

    var preferredInputDeviceUID: String? {
        inputDeviceUID.isEmpty ? nil : inputDeviceUID
    }

    @ObservationIgnored @AppStorage("selectedModel", store: DefaultsStore.current) var selectedModel: String = "openai_whisper-tiny"
    @ObservationIgnored @AppStorage("selectedLanguageRaw", store: DefaultsStore.current) private var selectedLanguageRaw: String = ""
    @ObservationIgnored @AppStorage("translate", store: DefaultsStore.current) var translate: Bool = false

    @ObservationIgnored private var cachedSelectedModel: String = ""
    @ObservationIgnored private var cachedCapabilities: EngineCapabilities = .whisperKitDefaults

    var selectedModelCapabilities: EngineCapabilities {
        if cachedSelectedModel != selectedModel {
            cachedSelectedModel = selectedModel
            cachedCapabilities = ModelCatalog.staticCapabilities(forID: selectedModel) ?? .whisperKitDefaults
        }
        return cachedCapabilities
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
            applyDictationCleanupPromptChange()
        }
    }

    var correctionRules: [CorrectionRule] = [] {
        didSet { saveCorrectionRules() }
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
            applyDictationEnabledChange()
        }
    }

    var dictationModeRaw: String = DictationMode.pushToTalk.rawValue {
        didSet {
            defaults.set(dictationModeRaw, forKey: "dictationModeRaw")
            applyDictationModeChange()
        }
    }

    var dictationKeyCode: Int = 96 {
        didSet {
            defaults.set(dictationKeyCode, forKey: "dictationKeyCode")
            restartDictation()
        }
    }

    var dictationKeyModifiers: Int = 0 {
        didSet {
            defaults.set(dictationKeyModifiers, forKey: "dictationKeyModifiers")
            restartDictation()
        }
    }

    var dictationModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(dictationKeyModifiers))
            .intersection(.deviceIndependentFlagsMask)
    }

    var dictationIndicatorStyleRaw: String = DictationIndicatorStyle.overlay.rawValue {
        didSet {
            defaults.set(dictationIndicatorStyleRaw, forKey: "dictationIndicatorStyleRaw")
            applyIndicatorStyleChange()
        }
    }

    var dictationMode: DictationMode {
        DictationMode(rawValue: dictationModeRaw) ?? .pushToTalk
    }

    var dictationIndicatorStyle: DictationIndicatorStyle {
        DictationIndicatorStyle(rawValue: dictationIndicatorStyleRaw) ?? .overlay
    }

    // MARK: - Customization

    @ObservationIgnored @AppStorage("appTheme", store: DefaultsStore.current) var appTheme: String = "system"  // "system" | "light" | "dark"
    @ObservationIgnored @AppStorage("monospacedTimestamps", store: DefaultsStore.current) var monospacedTimestamps: Bool = true
    @ObservationIgnored @AppStorage("sidebarDensity", store: DefaultsStore.current) var sidebarDensity: String = "comfortable"  // "comfortable" | "compact"
    @ObservationIgnored @AppStorage(AppAccent.storageKey, store: DefaultsStore.current) var appAccentRaw: String = AppAccent.terracotta.rawValue

    var appAccent: AppAccent {
        get { AppAccent(rawValue: appAccentRaw) ?? .terracotta }
        set { appAccentRaw = newValue.rawValue }
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
            applyDictationCleanupPromptChange()
        }
    }

    var dictationPerAppOverridesJSON: String = "{}" {
        didSet {
            defaults.set(dictationPerAppOverridesJSON, forKey: "dictationPerAppOverridesJSON")
            cachedDictationWorkflows = nil
            applyDictationCleanupPromptChange()
            restartDictation()
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

    @ObservationIgnored let library = LibraryStore()
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
    var librarySortOrder: LibrarySortOrder = .newest {
        didSet { reapplyLibrarySort() }
    }
    @ObservationIgnored var libraryBundleSizes: [String: Int64] = [:]
    @ObservationIgnored var searchTask: Task<Void, Never>?
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

    @ObservationIgnored private var liveSource: AudioSource?
    @ObservationIgnored private var streamingSession: (any StreamingTranscriber)?
    @ObservationIgnored private var streamingConsumer: Task<Void, Never>?
    @ObservationIgnored private var fileTranscribeTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeTranscribeTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeSubsTask: Task<Void, Never>?
    @ObservationIgnored private var lastDownloadPercent: Int = -1

    var canCancel: Bool {
        if batchTask != nil { return true }
        if streamingConsumer != nil { return true }
        if fileTranscribeTask != nil { return true }
        if youtubeTranscribeTask != nil { return true }
        if youtubeSubsTask != nil { return true }
        return false
    }

    func cancelCurrentWork() {
        batchTask?.cancel()
        batchTask = nil
        fileTranscribeTask?.cancel()
        fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel()
        youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel()
        youtubeSubsTask = nil
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
        phase = .idle
    }

    func cancelAllTasks() {
        countdownTask?.cancel(); countdownTask = nil
        batchTask?.cancel(); batchTask = nil
        matchesDebounce?.cancel(); matchesDebounce = nil
        recordingLevelTask?.cancel(); recordingLevelTask = nil
        silenceWatchTask?.cancel(); silenceWatchTask = nil
        recordingAutoStopTask?.cancel(); recordingAutoStopTask = nil
        searchTask?.cancel(); searchTask = nil
        streamingConsumer?.cancel(); streamingConsumer = nil
        fileTranscribeTask?.cancel(); fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel(); youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel(); youtubeSubsTask = nil
    }

    @ObservationIgnored private var testBridge: ParolaAutomationServer?
    private(set) var automationBridgeRunning: Bool = false
    private(set) var automationBridgePort: UInt16?

    @ObservationIgnored @AppStorage("automationBridgeEnabled", store: DefaultsStore.current) var automationBridgeEnabled: Bool = AppModel.defaultBridgeEnabled

    static var defaultBridgeEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Sparkle

    @ObservationIgnored @AppStorage("sparkleChannel", store: DefaultsStore.current) var sparkleChannelRaw: String = SparkleChannel.stable.rawValue {
        didSet { applySparkleChannelChange() }
    }

    @ObservationIgnored @AppStorage("sparkleAutomatic", store: DefaultsStore.current) var sparkleAutomatic: Bool = true {
        didSet { SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic }
    }

    var sparkleChannel: SparkleChannel {
        SparkleChannel(rawValue: sparkleChannelRaw) ?? .stable
    }

    private func applySparkleChannelChange() {
        SparkleUpdater.shared.channel = sparkleChannel
    }

    // MARK: - Live captions translation

    @ObservationIgnored @AppStorage("liveCaptionsTranslate", store: DefaultsStore.current) var liveCaptionsTranslate: Bool = false {
        didSet { applyLiveCaptionsTranslateChange() }
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
        self.dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        self.dictationModeRaw = defaults.string(forKey: "dictationModeRaw") ?? DictationMode.pushToTalk.rawValue
        self.dictationKeyCode = defaults.object(forKey: "dictationKeyCode") == nil ? 96 : defaults.integer(forKey: "dictationKeyCode")
        self.dictationKeyModifiers = defaults.object(forKey: "dictationKeyModifiers") == nil ? 0 : defaults.integer(forKey: "dictationKeyModifiers")
        self.dictationIndicatorStyleRaw = defaults.string(forKey: "dictationIndicatorStyleRaw") ?? DictationIndicatorStyle.overlay.rawValue
        self.dictationCleanupPromptID = defaults.string(forKey: "dictationCleanupPromptID") ?? ""
        self.dictationPerAppOverridesJSON = defaults.string(forKey: "dictationPerAppOverridesJSON") ?? "{}"
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        loadSnippets()
        loadCorrectionRules()
        refreshModelList()
        refreshLibrary()
        wireDictationController()

        let sideEffects = bootstrap.sideEffects
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
        filePicker: FilePicker = SystemFilePicker()
    ) {
        let sideEffects: Set<BootstrapSideEffect> = skipBootstrap ? [] : BootstrapSideEffect.all
        let bootstrap = AppBootstrap(
            mode: .normal,
            defaultsOverride: defaults,
            sideEffects: sideEffects,
            filePicker: filePicker
        )
        self.init(bootstrap: bootstrap)
    }

    deinit {
        recordingLevelTask?.cancel()
        streamingConsumer?.cancel()
    }

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
            } catch {
                // best-effort: transcript stays in memory if library save fails
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
        Task {
            do {
                phase = .downloadingModel(name: name, progress: 0)
                _ = try await store.download(variant: name, progress: { [weak self] frac in
                    Task { @MainActor [weak self] in
                        if case .downloadingModel(let n, _) = self?.phase, n == name {
                            self?.phase = .downloadingModel(name: name, progress: frac)
                        }
                    }
                })
                phase = .idle
                refreshModelList()
            } catch {
                phase = .failed(message: "Download failed: \(error.localizedDescription)")
            }
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
        if fileURL.pathExtension == "parola" {
            openProjectDocument(at: fileURL)
            return
        }
        noteRecentFile(fileURL)
        sourceFileURL = fileURL
        installPlayer(for: fileURL)
        filePartialText = ""

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
                    downloadProgress: makeDownloadProgressHandler(),
                    partialHandler: makeFilePartialHandler()
                )
                try Task.checkCancellation()
                let processed = postProcess(result)
                transcript = processed
                filePartialText = ""
                phase = .ready
                refreshModelList()
                persistToLibrary(processed, audioSource: fileURL)
            } catch {
                filePartialText = ""
                applyTranscriptionError(error)
            }
            self.fileTranscribeTask = nil
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

    private func makeDownloadProgressHandler() -> @Sendable (Double) -> Void {
        let modelName = selectedModel
        lastDownloadPercent = -1
        return { [weak self] frac in
            let percent = Int(frac * 100)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard percent != self.lastDownloadPercent else { return }
                self.lastDownloadPercent = percent
                self.phase = .downloadingModel(name: modelName, progress: frac)
            }
        }
    }

    // MARK: - YouTube URL

    var youtubeSheetOpen: Bool = false
    var ytDlpAvailable: Bool = false
    var ytDlpInstalling: Bool = false
    var ytDlpInstallError: String?

    func refreshYtDlpAvailability() {
        ytDlpAvailable = Self.findYtDlp() != nil
    }

    func installYtDlpViaBrew() {
        guard !ytDlpInstalling else { return }
        guard let brew = Self.findBrew() else {
            ytDlpInstallError = "Homebrew isn't installed. Install it from https://brew.sh, then try again."
            return
        }
        ytDlpInstalling = true
        ytDlpInstallError = nil
        Task { [weak self] in
            let outcome = await Self.runBrewInstall(brewPath: brew, formula: "yt-dlp")
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

    private enum BrewOutcome {
        case success
        case failure(String)
    }

    private static func runBrewInstall(brewPath: String, formula: String) async -> BrewOutcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = ["install", formula]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: Data.self)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                chunkContinuation.finish()
            } else {
                chunkContinuation.yield(chunk)
            }
        }

        let bufferTask = Task<String, Never> {
            var data = Data()
            for await chunk in chunkStream {
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            chunkContinuation.finish()
            return .failure("Could not launch brew: \(error.localizedDescription)")
        }
        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                chunkContinuation.finish()
                Task {
                    let output = await bufferTask.value
                    if p.terminationStatus == 0 {
                        cont.resume(returning: .success)
                    } else {
                        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: .failure(detail.isEmpty ? "brew exited with status \(p.terminationStatus)." : detail))
                    }
                }
            }
        }
    }

    private static func findYtDlp() -> String? {
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let candidate = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func findBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    func transcribeYouTube(urlString: String) {
        guard let url = makeYouTubeURL(urlString) else { return }

        youtubeTranscribeTask?.cancel()
        youtubeTranscribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                phase = .downloadingModel(name: "youtube", progress: 0)
                let source = try YouTubeAudioSource(url: url)
                let audioURL = try await source.prepare()
                try Task.checkCancellation()
                sourceFileURL = audioURL
                installPlayer(for: audioURL)

                phase = .transcribing(file: audioURL)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                try Task.checkCancellation()
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                refreshModelList()
                persistToLibrary(processed, audioSource: audioURL)
            } catch {
                applyTranscriptionError(error)
            }
            self.youtubeTranscribeTask = nil
        }
    }

    func fetchYouTubeSubs(urlString: String) {
        guard let url = makeYouTubeURL(urlString) else { return }

        youtubeSubsTask?.cancel()
        youtubeSubsTask = Task { [weak self] in
            guard let self else { return }
            do {
                phase = .transcribing(file: url)
                let result = try await YouTubeSubsFetcher.fetch(url: url, preferLanguage: selectedLanguage)
                try Task.checkCancellation()
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                persistToLibrary(processed, audioSource: nil)
            } catch {
                applyTranscriptionError(error)
            }
            self.youtubeSubsTask = nil
        }
    }

    private func makeYouTubeURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString), url.isYtDlpSupported else {
            phase = .failed(message: "That URL isn't on a host yt-dlp can fetch.")
            return nil
        }
        youtubeSheetOpen = false
        return url
    }

    private func applyTranscriptionError(_ error: Error) {
        if error is CancellationError || Task.isCancelled {
            phase = .idle
        } else {
            phase = .failed(message: error.localizedDescription)
        }
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

    private func beginRecordingNow(source: RecordSource) {
        if source == .microphone && useStreaming {
            startStreamingMic()
            return
        }
        let config = mediaSessionConfig(allowMute: source == .microphone)
        Task {
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
                phase = .failed(message: error.localizedDescription)
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
        let progress = makeDownloadProgressHandler()
        let config = mediaSessionConfig(allowMute: true)

        streamingConsumer = Task { @MainActor in
            await mediaSession.enterRecording(config: config)
            do {
                let events = try await s.start(options: opts, speakerLabeler: nil, downloadProgress: progress)
                phase = .recording(source: .microphone)
                for await event in events {
                    handleStreamingEvent(event)
                }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            await mediaSession.exitRecording()
        }
    }

    private func handleStreamingEvent(_ event: StreamingEvent) {
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
            phase = .failed(message: msg)
        case .finished(let transcript):
            let processed = postProcess(transcript)
            self.transcript = processed
            self.livePartialText = ""
            self.phase = .ready
            persistToLibrary(processed, audioSource: nil)
        }
    }

    func stopRecordingAndTranscribe() {
        recordingAutoStopTask?.cancel()
        recordingAutoStopTask = nil
        if let s = streamingSession {
            Task { @MainActor in
                await s.stop()
                streamingSession = nil
                streamingConsumer?.cancel()
                streamingConsumer = nil
                stopRecordingLevelObserver()
                stopSilenceWatch()
            }
            return
        }

        guard let source = liveSource else { return }
        Task {
            await mediaSession.exitRecording()
            do {
                let url = try await source.prepare()
                liveSource = nil
                stopRecordingLevelObserver()
                sourceFileURL = url
                installPlayer(for: url)

                phase = .transcribing(file: url)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: url),
                    options: currentOptions
                )
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                refreshModelList()
                persistToLibrary(processed, audioSource: url)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Editing

    func editSegment(id: TranscriptSegment.ID, newText: String) {
        guard var t = transcript else { return }
        guard let idx = t.segments.firstIndex(where: { $0.id == id }) else { return }
        t.segments[idx].text = newText
        transcript = t
    }

    func deleteSegment(id: TranscriptSegment.ID) {
        guard var t = transcript else { return }
        let before = t.segments.count
        t.segments.removeAll { $0.id == id }
        guard t.segments.count != before else { return }
        transcript = t
    }

    func nudgeSegmentStart(id: TranscriptSegment.ID, frames: Int) {
        guard var t = transcript else { return }
        t.segments = SegmentTimingNudge.nudgeStart(
            segments: t.segments, id: id, frameDelta: frames, fps: subtitleFPS
        )
        transcript = t
    }

    func nudgeSegmentEnd(id: TranscriptSegment.ID, frames: Int) {
        guard var t = transcript else { return }
        t.segments = SegmentTimingNudge.nudgeEnd(
            segments: t.segments, id: id, frameDelta: frames, fps: subtitleFPS
        )
        transcript = t
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

    func openProjectDocument(at url: URL) {
        do {
            let doc = try ParolaDocument.read(at: url)
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
                _ = try ParolaDocument.write(transcript: transcript, audioURL: sourceFileURL, to: dest)
            } catch {
                self.phase = .failed(message: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Summary

    var isSummarising: Bool = false
    var summaryError: String?
    @ObservationIgnored private var summaryGeneration: Int = 0

    func summariseTranscript() {
        guard let transcript, !isSummarising else { return }
        isSummarising = true
        summaryError = nil
        summaryGeneration &+= 1
        let generation = summaryGeneration
        let snapshot = transcript
        Task {
            do {
                let summary = try await SummaryService().summarise(snapshot)
                guard generation == summaryGeneration else { return }
                self.transcript?.summary = summary
            } catch {
                guard generation == summaryGeneration else { return }
                summaryError = error.localizedDescription
            }
            if generation == summaryGeneration {
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

    func shareTranscriptViaMail() {
        guard let transcript else { return }
        let title = sourceFileURL?.deletingPathExtension().lastPathComponent ?? "Transcript"
        let body = transcript.segments
            .map { seg -> String in
                let stamp = Timecode.format(seg.start)
                let prefix = seg.speaker.map { "\($0): " } ?? ""
                return "\(stamp)  \(prefix)\(seg.text.trimmingCharacters(in: .whitespaces))"
            }
            .joined(separator: "\n\n")
        var components = URLComponents(string: "mailto:")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyTranscriptToPasteboard(withTimestamps: Bool) {
        guard let transcript else { return }
        let text: String
        if withTimestamps {
            text = TranscriptTimestampedText.render(transcript)
        } else {
            text = transcript.text
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyTranscriptAsFormat(_ format: ExportFormat) {
        guard let transcript else { return }
        guard let data = try? makeExporter(for: format).render(transcript),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func printTranscript() {
        guard let transcript else { return }
        let title = sourceFileURL?.deletingPathExtension().lastPathComponent ?? "Transcript"
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
            do {
                let data = try self.makeExporter(for: format).render(transcript)
                try data.write(to: url, options: .atomic)
            } catch {
                self.phase = .failed(message: "Export failed: \(error.localizedDescription)")
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

