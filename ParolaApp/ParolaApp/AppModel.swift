import CoreGraphics
import Foundation
import SwiftUI
import AVFoundation
import Observation
import UniformTypeIdentifiers
import os
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
        /// yt-dlp downloading a link's audio; nil progress while the site hasn't said how big it is.
        case fetchingLink(title: String?, progress: Double?)
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
        var entrySource: EntrySource {
            switch self {
            case .microphone: return .microphone
            case .systemAudio: return .systemAudio
            }
        }
    }

    enum Route: String, Hashable, CaseIterable {
        case transcript
        case batch
        case queue
        case statistics
        case recentlyDeleted
    }

    var route: Route = .transcript {
        didSet {
            if oldValue == .recentlyDeleted { recentlyDeletedSelection = [] }
        }
    }
    var settingsPane: String = "general"
    var settingsRoutePreview = false  // test-mode only: renders SettingsView in the main window so the bridge can screenshot panes
    // Published by TranscriptPane so the Toggle Inspector command knows which of the two visibility keys to flip.
    var transcriptPaneIsNarrow = false
    var dropDragPayload: DroppedFiles.Kind?
    var dropHighlight: DropHalf?
    var dragOverComposer = false
    var phase: Phase = .idle {
        didSet { forgetFailedSource() }
    }
    var transcript: Transcript? {
        didSet {
            transcriptMatchesLoadedMedia = false
            if transcript == nil, promptOutput != nil { promptOutput = nil }
            currentSegmentIndex = nil
            if !Self.sameText(oldValue, transcript) {
                cachedTranscriptText = nil
                transcriptTextVersion &+= 1
            }
            let speakers = transcript?.uniqueSpeakers ?? []
            if speakers != transcriptSpeakers { transcriptSpeakers = speakers }
            if hasTranscript != (transcript != nil) { hasTranscript = transcript != nil }
            if hasTranslation != (transcript?.translation != nil) { hasTranslation = transcript?.translation != nil }
            transcriptVersion &+= 1
            if findIsOpen { scheduleRecomputeMatches() }
        }
    }
    /// Menu enablement reads this instead of the transcript itself, so a segment edit doesn't rebuild the whole command tree.
    private(set) var hasTranscript: Bool = false
    private(set) var hasTranslation: Bool = false
    private(set) var transcriptSpeakers: [String] = []
    private(set) var transcriptVersion: Int = 0
    /// Moves only when the segment texts or the language change: timing, speakers and chat leave it alone.
    private(set) var transcriptTextVersion: Int = 0
    @ObservationIgnored private var cachedTranscriptText: String?
    /// The full joined transcript, built once per text version instead of once per reader.
    var transcriptText: String {
        guard let transcript else { return "" }
        if let cachedTranscriptText { return cachedTranscriptText }
        let text = transcript.text
        cachedTranscriptText = text
        return text
    }
    /// Compares storage-shared texts in O(1) each, so a timing nudge costs a pass of pointer checks.
    private static func sameText(_ lhs: Transcript?, _ rhs: Transcript?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard lhs.language == rhs.language, lhs.segments.count == rhs.segments.count else { return false }
        return zip(lhs.segments, rhs.segments).allSatisfy { $0.text == $1.text }
    }
    // Short-circuits rather than building Transcript.text just to test for emptiness on every view update.
    var transcriptIsEmpty: Bool {
        guard let transcript else { return false }
        return !transcript.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    /// The import waiting on the "Already in your library" sheet. Nil the rest of the time.
    var duplicateImport: DuplicateImport?
    /// The re-transcription in flight. Nil the rest of the time; the inspector menus watch it.
    var retranscribeRequest: RetranscribeRequest?
    /// How many files the last batch import dropped because the library already had them.
    var batchDuplicatesSkipped: Int = 0
    /// Dropped files still being hashed against the library before they join the batch.
    var batchFilesBeingChecked: Int = 0
    @ObservationIgnored var duplicateCheckTask: Task<Void, Never>?
    @ObservationIgnored var batchImportTask: Task<Void, Never>?
    @ObservationIgnored var watchedImportTask: Task<Void, Never>?
    /// A run the user stopped does not ring when its queue unwinds. Cleared when a wave starts.
    @ObservationIgnored var batchRunCancelled = false
    var currentSegmentID: TranscriptSegment.ID?
    /// A segment a search result asked the transcript to open on. The write lands before the route
    /// builds the transcript view, so the view scrolls to this on appear rather than watching
    /// `currentSegmentID`; it holds the selection against the player's ticks until playback starts.
    var pendingRevealSegmentID: TranscriptSegment.ID?
    var currentWordID: WordTiming.ID?
    var editingSegmentNote: SegmentNoteTarget?
    // Playback-tick cache: index of currentSegmentID in transcript.segments, so the 5 Hz tick
    // validates in O(1) instead of scanning. Nil'd whenever the transcript is replaced.
    @ObservationIgnored var currentSegmentIndex: Int?

    var liveSegments: [TranscriptSegment] = []
    /// The route the running take took; the recording pane reads it.
    private(set) var liveTakeIsStreaming = false
    var livePartialText: String = ""
    var liveVoiceActive: Bool = false
    var filePartialText: String = ""
    /// A link run's video title with the file it was downloaded to, so the pane never names the working file.
    var linkRunTitle: LinkRunTitle?

    struct LinkRunTitle {
        let file: URL
        let title: String
    }
    /// 0–1 fraction of the media transcribed so far, or nil while indeterminate (duration unknown, or the engine reports no progress).
    var fileTranscribeFraction: Double?
    var fileTranscribeStage: TranscribeStage?
    var useStreaming: Bool = true { didSet { defaults.set(useStreaming, forKey: "useStreaming"); if !isReloadingSettings { restartDictation() } } }
    var wordTimestamps: Bool = false { didSet { defaults.set(wordTimestamps, forKey: "wordTimestamps") } }
    var karaokeHighlight: Bool = true { didSet { defaults.set(karaokeHighlight, forKey: "karaokeHighlight") } }
    var initialPrompt: String = "" { didSet { defaults.set(initialPrompt, forKey: "initialPrompt"); if !isReloadingSettings { scheduleDictationRestart() } } }
    var diarize: Bool = false { didSet { defaults.set(diarize, forKey: "diarize") } }
    /// Diarizer speaker-count hint; 0 means auto-detect and threads nil into the options.
    var expectedSpeakersRaw: Int = 0 { didSet { defaults.set(expectedSpeakersRaw, forKey: "expectedSpeakersRaw") } }
    var generatesCardMetadata: Bool = true { didSet { defaults.set(generatesCardMetadata, forKey: "generateCardMetadata") } }
    // Bumps libraryVersion even during a settings reload: a bridge setSetting, an import, or a
    // Reset must repaint rows whose title or excerpt this toggle switches.
    var showAITitles: Bool = true {
        didSet {
            defaults.set(showAITitles, forKey: "showAITitles")
            libraryVersion &+= 1
        }
    }
    var showAISummaries: Bool = true {
        didSet {
            defaults.set(showAISummaries, forKey: "showAISummaries")
            libraryVersion &+= 1
        }
    }
    var customTitlePrompt: String = "" { didSet { defaults.set(customTitlePrompt, forKey: "customTitlePrompt") } }
    var customSummaryPrompt: String = "" { didSet { defaults.set(customSummaryPrompt, forKey: "customSummaryPrompt") } }
    /// Test seam: when set, replaces CardMetadataService so a test never touches the shared mock LLM store.
    @ObservationIgnored var cardMetadataOperation: (@Sendable (Transcript) async -> CardMetadata?)?
    /// The last card job queued; the next one waits for it.
    @ObservationIgnored var cardMetadataTail: Task<Void, Never>?
    @ObservationIgnored var cardJobsPending = 0
    @ObservationIgnored var cardRetryIDs: [LibraryEntry.ID] = []
    @ObservationIgnored var cardRetryTask: Task<Void, Never>?
    @ObservationIgnored var cardMetadataTimeout: Duration = .seconds(30)
    @ObservationIgnored var cardRetryDelay: Duration = .seconds(60)
    /// Test seam: when set, replaces the rule pipeline, so a test controls the one suspension
    /// between the engine returning and the old take being overwritten.
    @ObservationIgnored var postProcessOperation: (@Sendable (Transcript) async -> Transcript)?
    var subtitleFPS: Double = 30 { didSet { defaults.set(subtitleFPS, forKey: "subtitleFPS") } }
    var subtitleCaptionLengthRaw: String = CaptionLength.none.rawValue { didSet { defaults.set(subtitleCaptionLengthRaw, forKey: "subtitleCaptionLength") } }
    var transcriptCompact: Bool = false { didSet { defaults.set(transcriptCompact, forKey: "transcriptCompact") } }
    var showSubtitleQC: Bool = false { didSet { defaults.set(showSubtitleQC, forKey: "showSubtitleQC") } }
    var translationSideBySide: Bool = true { didSet { defaults.set(translationSideBySide, forKey: "translationSideBySide") } }
    /// Stored, not lazily made: the host view reads its published configuration every time the body runs.
    @ObservationIgnored let translationCoordinator = TranslationCoordinator()
    var skipSilences: Bool = false { didSet { defaults.set(skipSilences, forKey: "skipSilences") } }
    var pausePlayerOnAppHidden: Bool = false { didSet { defaults.set(pausePlayerOnAppHidden, forKey: "pausePlayerOnAppHidden") } }
    var markdownTimestamps: Bool = false { didSet { defaults.set(markdownTimestamps, forKey: "markdownTimestamps") } }
    var txtExportTimestamps: Bool = false { didSet { defaults.set(txtExportTimestamps, forKey: "txtExportTimestamps") } }
    var burnFontSizeRaw: String = BurnFontSize.medium.rawValue { didSet { defaults.set(burnFontSizeRaw, forKey: "burnFontSize") } }
    var burnTextColorRaw: String = BurnTextColor.white.rawValue { didSet { defaults.set(burnTextColorRaw, forKey: "burnTextColor") } }
    var burnOutline: Bool = true { didSet { defaults.set(burnOutline, forKey: "burnOutline") } }
    var htmlExportThemeRaw: String = HtmlExportTheme.light.rawValue { didSet { defaults.set(htmlExportThemeRaw, forKey: "htmlExportTheme") } }
    var autoExportFolder: AutoExportFolder? {
        didSet {
            if let autoExportFolder { writeJSON(autoExportFolder, forKey: "autoExportFolder") } else {
                defaults.removeObject(forKey: "autoExportFolder")
            }
        }
    }
    @ObservationIgnored var autoExportNoticeShown = false
    var dictationHudOpacity: Double = 1.0 { didSet { defaults.set(dictationHudOpacity, forKey: "dictationHudOpacity") } }
    var lastFindQuery: String = "" { didSet { defaults.set(lastFindQuery, forKey: "lastFindQuery") } }
    var userPrivacyMode: Bool = false { didSet { defaults.set(userPrivacyMode, forKey: "parola.userPrivacyMode") } }
    var pinnedModel: String = "" { didSet { defaults.set(pinnedModel, forKey: "pinnedModel") } }
    var mainWindowAlwaysOnTop: Bool = false { didSet { defaults.set(mainWindowAlwaysOnTop, forKey: "mainWindowAlwaysOnTop") } }
    var recentFilesRaw: String = "[]" { didSet { defaults.set(recentFilesRaw, forKey: "recentFiles"); cachedRecentFiles = nil } }
    var micHotkeyKeyCode: Int = 15 { didSet { defaults.set(micHotkeyKeyCode, forKey: "micHotkeyKeyCode") } } // kVK_ANSI_R
    var micHotkeyModifiers: Int = 786721 { didSet { defaults.set(micHotkeyModifiers, forKey: "micHotkeyModifiers") } } // ⌃⌥⌘
    var micHotkeyEnabled: Bool = false { didSet { defaults.set(micHotkeyEnabled, forKey: "micHotkeyEnabled") } }
    var dictationStripSelfCorrections: Bool = false {
        didSet {
            defaults.set(dictationStripSelfCorrections, forKey: "dictationStripSelfCorrections")
            if !isReloadingSettings { applyDictationCleanupPromptChange() }
        }
    }
    var dictationPasteDelayMs: Int = 0 {
        didSet {
            defaults.set(dictationPasteDelayMs, forKey: "dictationPasteDelayMs")
            if !isReloadingSettings { scheduleDictationRestart() }
        }
    }
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
    /// Derived from `appVisibilityMode` and never persisted: the stored key is the mode.
    var showMenuBarExtra: Bool = false
    var appVisibilityModeRaw: String = AppVisibilityMode.dockAndMenuBar.rawValue {
        didSet {
            defaults.set(appVisibilityModeRaw, forKey: "appVisibilityMode")
            applyAppVisibilityMode()
        }
    }
    var appVisibilityMode: AppVisibilityMode {
        get { AppVisibilityMode(rawValue: appVisibilityModeRaw) ?? .dockAndMenuBar }
        set { appVisibilityModeRaw = newValue.rawValue }
    }
    /// Set by the app delegate at launch; nil in tests, which have no activation policy to change.
    @ObservationIgnored var activationPolicyApplier: (@MainActor (NSApplication.ActivationPolicy) -> Void)?
    /// A headless launch has no UI to show, so neither half of the mode is applied to it.
    @ObservationIgnored var isHeadless = CommandLine.arguments.contains("--headless")

    var playSoundWhenFinished: Bool = false { didSet { defaults.set(playSoundWhenFinished, forKey: "playSoundWhenFinished") } }
    var duplicateImportPolicyRaw: String = DuplicateImportPolicy.alwaysAsk.rawValue {
        didSet { defaults.set(duplicateImportPolicyRaw, forKey: "duplicateImportPolicy") }
    }
    var duplicateImportPolicy: DuplicateImportPolicy {
        get { DuplicateImportPolicy(rawValue: duplicateImportPolicyRaw) ?? .alwaysAsk }
        set { duplicateImportPolicyRaw = newValue.rawValue }
    }
    /// What the finished sound actually is. Test mode clears it; a test stubs it to count the plays.
    @ObservationIgnored var completionSoundPlayer: (@MainActor () -> Void)? = {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
    /// The answer to a click the app refuses. Test mode clears it; a test stubs it to count them.
    @ObservationIgnored var refusalBeep: (@MainActor () -> Void)? = { NSSound.beep() }
    var recordingCountInSeconds: Int = 0 { didSet { defaults.set(recordingCountInSeconds, forKey: "recordingCountInSeconds") } }
    var autoMuteWhileRecording: Bool = false { didSet { defaults.set(autoMuteWhileRecording, forKey: "autoMuteWhileRecording") } }
    var autoPauseMediaWhileRecording: Bool = false { didSet { defaults.set(autoPauseMediaWhileRecording, forKey: "autoPauseMediaWhileRecording") } }
    var recordingCountdown: Int? = nil
    @ObservationIgnored private(set) var countdownTask: Task<Void, Never>?

    @ObservationIgnored private var cachedRecentFiles: [URL]?
    var recentFiles: [URL] {
        get {
            // The raw read comes first so the Open Recent menu still tracks it on a cache hit.
            let raw = recentFilesRaw
            if let cachedRecentFiles { return cachedRecentFiles }
            var list = RecentFilesList(capacity: 10)
            list.decode(raw)
            cachedRecentFiles = list.urls
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

    var pendingRecovery: RecoveryCheckpoint?
    @ObservationIgnored var recoveryGeneration: Int = 0
    @ObservationIgnored var activeRecoveryGeneration: Int?
    @ObservationIgnored var recordingRecoveryStartedAt: Date?
    @ObservationIgnored var liveRecordingAudioURL: URL?
    @ObservationIgnored var recordingWatchTask: Task<Void, Never>?
    @ObservationIgnored var pendingRecoveryWrite: Task<Void, Never>?
    enum FailureKind {
        case transcription
        case other
    }

    /// Every phase change resets this, so only the transcription paths that opt back in get a named card.
    private(set) var failureKind: FailureKind = .other
    /// A recorded take whose transcription failed; the file backs the error pane's Retry.
    var failedTakeAudioURL: URL?
    /// The file a failed file transcription was reading; the error card retries and reveals it.
    var failedFileURL: URL?
    /// The translate setting the failed run used, so Retry repeats it rather than the current toggle.
    var failedTranslateOverride: Bool?
    var failedLink: DeferredLink?
    var failedLinkDownload: LinkDownloadFailure?
    @ObservationIgnored var failedTakeTitle: String?
    @ObservationIgnored var failedTakeCategory: EntryCategory?
    @ObservationIgnored var failedTakeSource: EntrySource?
    @ObservationIgnored var pendingDictationRestart: Task<Void, Never>?
    @ObservationIgnored var pendingDictationProcessorRebuild: Task<Void, Never>?

    var recordingDiskSpaceLow: Bool = false
    @ObservationIgnored var freeDiskSpaceProvider: @Sendable () -> Int64? = { AppModel.systemFreeDiskSpace() }

    var batchJobs: [BatchJob] = [] {
        didSet {
            batchBuckets = BatchJobBuckets(batchJobs)
            guard !BatchJob.sameQueueShape(oldValue, batchJobs) else { return }
            batchProgress.retain(Set(batchJobs.map(\.id)))
            let active = QueueCount.count(for: batchJobs)
            if active != activeBatchJobCount { activeBatchJobCount = active }
            if batchIsEmpty != batchJobs.isEmpty { batchIsEmpty = batchJobs.isEmpty }
            let running = batchJobs.contains { $0.status == .transcribing }
            if batchIsRunning != running { batchIsRunning = running }
            let hasDone = batchJobs.contains { $0.status == .done }
            if batchHasDoneJob != hasDone { batchHasDoneJob = hasDone }
            saveBatchQueueSnapshot()
        }
    }
    /// Mirrors of `batchJobs` that change only on a status transition, so a progress tick reaches none of their readers.
    private(set) var activeBatchJobCount: Int = 0
    private(set) var batchIsEmpty = true
    private(set) var batchIsRunning = false
    private(set) var batchHasDoneJob = false
    private(set) var batchBuckets = BatchJobBuckets()
    @ObservationIgnored let batchProgress = BatchProgressBoard()
    struct UnsavedBatchJob {
        let jobID: BatchJob.ID
        /// The `derivedArtifactsGeneration` of the install; any later install moves it on.
        let install: Int
    }
    @ObservationIgnored var unsavedBatchJobOnScreen: UnsavedBatchJob?
    @ObservationIgnored var unsavedBatchEdits: Set<BatchJob.ID> = []
    /// The library adds of the finished jobs the closing refresh still has to wait for.
    @ObservationIgnored var batchLibraryAdds: [Task<LibraryEntry?, Never>] = []
    @ObservationIgnored var batchClosingRefresh: Task<Void, Never>?
    /// Where each finished job's sidecars landed, which is not always `<stem>.<ext>`.
    @ObservationIgnored var batchSidecars: [BatchJob.ID: [URL]] = [:]
    var selectedBatchJobID: BatchJob.ID?
    @ObservationIgnored var batchTask: Task<Void, Never>?
    @ObservationIgnored var lastSavedBatchQueueURLs: [URL]?

    var exportPresets: [ExportPreset] = ExportPreset.builtIns { didSet { saveExportPresets() } }
    var batchExportPresetIDs: [UUID] = [] { didSet { writeJSON(batchExportPresetIDs, forKey: "batchExportPresets") } }

    var findIsOpen: Bool = false
    /// Bumped by Edit › Find…; the find bar watches the count, so a second ⌘F puts the caret back too.
    var findFocusRequests: Int = 0
    /// Bumped by every replacement, so the find bar lets go of its field and the next ⌘Z reaches the transcript.
    var findReplacements: Int = 0
    var findQuery: String = "" { didSet { scheduleRecomputeMatches() } }
    var findCaseSensitive: Bool = false { didSet { scheduleRecomputeMatches() } }
    var findReplacement: String = ""
    var matches: [TranscriptMatch] = [] {
        didSet {
            rebuildMatchesIndex()
            if hasMatches != !matches.isEmpty { hasMatches = !matches.isEmpty }
        }
    }
    private(set) var hasMatches: Bool = false
    @ObservationIgnored var matchesBySegment: [Int: [TranscriptMatch]] = [:]
    var currentMatchIndex: Int = 0
    @ObservationIgnored var matchesDebounce: Task<Void, Never>?

    var inputDeviceUID: String = "" { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID"); if !isReloadingSettings { restartDictation() } } }

    var preferredInputDeviceUID: String? {
        inputDeviceUID.isEmpty ? nil : inputDeviceUID
    }

    var selectedModel: String = ModelCatalog.defaultModelID() {
        didSet {
            defaults.set(selectedModel, forKey: "selectedModel")
            if !isReloadingSettings {
                restartDictation()
                applyLiveCaptionsTranslateChange()
            }
        }
    }
    private var selectedLanguageRaw: String = "" { didSet { defaults.set(selectedLanguageRaw, forKey: "selectedLanguageRaw"); if !isReloadingSettings { restartDictation() } } }
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
        let label = AppModel.modelLabel(selectedModel)
        if selectedModelCapabilities.supportedLanguages.isEnglishOnly {
            return String(localized: "\(label) is English-only. Pick a multilingual model (like Whisper) to transcribe other languages.")
        }
        let languageName = LanguageDisplay.name(for: language) ?? language
        return String(localized: "\(label) can't transcribe \(languageName). Pick a multilingual model (like Whisper) to transcribe other languages.")
    }

    /// English-only model on Auto: TranscriptionSession pins the run to English regardless, so this
    /// only explains it — it doesn't touch `selectedLanguage`, unlike the rewrite it replaced.
    var englishOnlyAutoNotice: String? {
        guard selectedLanguage == nil, selectedModelCapabilities.supportedLanguages.isEnglishOnly else { return nil }
        return "\(AppModel.modelLabel(selectedModel)) only transcribes English; transcribing as English."
    }

    /// Set when the loaded transcript's language was a fallback rather than something the engine
    /// heard; nil for a detected language and for entries saved before the field existed.
    var assumedLanguageNotice: String? {
        guard let detection = transcript?.languageDetection, detection.isAssumed else { return nil }
        let name = LanguageDisplay.name(for: detection.code) ?? detection.code.uppercased()
        return String(localized: "Parola couldn't detect the language and assumed \(name). Set it in the toolbar and transcribe again.")
    }

    var diarizeMismatchWarning: String? {
        guard diarize, !selectedModelCapabilities.supportsDiarization else { return nil }
        return "\(AppModel.modelLabel(selectedModel)) can't identify speakers, so Diarize is skipped."
    }

    var translateMismatchWarning: String? {
        guard translate, !selectedModelCapabilities.supportsTranslate else { return nil }
        return "\(AppModel.modelLabel(selectedModel)) can't translate, so transcriptions stay in the source language."
    }

    var selectedLanguage: String? {
        get { selectedLanguageRaw.isEmpty ? nil : selectedLanguageRaw }
        set { selectedLanguageRaw = newValue ?? "" }
    }

    func activateModel(_ id: String) {
        selectedModel = id
    }

    /// Applies the introduction's engine pick, called when the user moves on so clicking a card never starts a download.
    func commitIntroductionEngine() {
        guard let id = introduction.selectedEngineID else { return }
        if let downloading = downloadingModelName, downloading != id,
           introduction.engineChoices.contains(downloading) {
            cancelModelDownload()
        }
        activateModel(id)
        // Back then Continue over a running download must not ask for it a second time.
        guard downloadingModelName != id, !isModelInstalled(id) else { return }
        downloadModel(id)
    }

    func advanceIntroduction() {
        if introduction.step == .engine { commitIntroductionEngine() }
        introduction.advance()
    }

    func restartIntroduction() {
        introduction.restart()
    }

    var availableModels: [ModelInfo] = []

    /// The one answer to "is this model on disk?": the scan when it has landed, the store until then.
    func isModelInstalled(_ id: String) -> Bool {
        availableModels.first(where: { $0.name == id })?.isInstalled ?? store.isInstalled(id)
    }
    var sourceFileURL: URL?

    var player: AVPlayer?
    var hasVideo: Bool = false
    var currentTimeSeconds: Double = 0
    var isPlaying: Bool = false
    @ObservationIgnored var playerTimeObserver: Any?
    @ObservationIgnored var timeControlObserver: NSKeyValueObservation?
    @ObservationIgnored var playerInstallToken: Int = 0
    /// Length of the media the player holds, from the asset or a probe of the file being transcribed.
    @ObservationIgnored var mediaDurationSeconds: Double?
    /// True only while the loaded transcript describes that media; a length measured for any other file must never reach it.
    @ObservationIgnored var transcriptMatchesLoadedMedia = false

    var pendingExport: ExportSpec?
    var exportSheetOpen: Bool = false
    var exportSheetSpec: ExportSpec = .standard(for: .txt)
    @ObservationIgnored var hasChosenExportSpec = false

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
            if !isReloadingSettings { scheduleDictationProcessorRebuild() }
        }
    }

    var correctionRules: [CorrectionRule] = [] {
        didSet {
            saveCorrectionRules()
            if !isReloadingSettings { scheduleDictationProcessorRebuild() }
        }
    }

    // MARK: - People (speakers)

    @ObservationIgnored let peopleStore: PeopleStore
    var showingSpeakersSheet: Bool = false
    var showingPeopleSheet: Bool = false
    /// The people directory, mirrored from the store so views read it without awaiting the actor.
    var people: [Person] = []
    /// Which person the library list is filtered to, set from the sidebar, the filter bar or the bridge.
    var personFilter: UUID?
    var showMostUsedPeople: Bool = true { didSet { defaults.set(showMostUsedPeople, forKey: "showMostUsedPeople") } }
    /// The speaker-map writes in flight, kept in order so the bundle never sees them out of turn.
    @ObservationIgnored var speakerAssignmentWriteTask: Task<Void, Never>?

    // MARK: - Prompt library

    @ObservationIgnored let promptLibrary: PromptLibrary
    var promptOutput: PromptOutput?
    var isRunningPrompt: Bool = false
    var actionItems: [ActionItem] = []
    var isExtractingActionItems: Bool = false
    var actionItemsError: String?
    var smartChapters: [Chapter] = []
    var isExtractingChapters: Bool = false
    var chaptersError: String?
    var entrySpeakerFilters: [String: String] = [:]
    var favoritesOnly: Bool = false

    /// Nil while the on-device model can serve requests; otherwise the reason to show the user.
    var aiUnavailableReason: String?
    var isAIAvailable: Bool { aiUnavailableReason == nil }

    struct PromptOutput: Identifiable {
        let id = UUID()
        let promptName: String
        let text: String
        var failure: String?
    }

    // MARK: - Auto-export rules

    var autoExportRules: [AutoExportRule] = [] {
        didSet { saveAutoExportRules() }
    }

    // MARK: - AI services

    /// Written only through `setAIServices(_:)`.
    var aiServices: [AIServiceConfig] = []
    /// Written only through `setLanguageModelSelection(_:)`.
    var languageModelSelection: LanguageModelSelection = .onDevice
    /// Written only through `acknowledgeRemoteAI()`.
    var remoteAIAcknowledged: Bool = false

    // MARK: - Send To

    /// Written only through `setDestinations(_:)`.
    var destinations: [AnyDestination] = []
    var deliveryNotice: DeliveryNotice?
    var exportNotice: ExportNotice?
    @ObservationIgnored lazy var deliveryEngine: DeliveryEngine = makeDeliveryEngine()
    @ObservationIgnored var volumeMountObservation: NotificationObservation?

    // MARK: - Watched folders

    @ObservationIgnored lazy var watchedFolders: WatchedFoldersStore = WatchedFoldersStore { [weak self] url in
        self?.handleWatchedArrival(url)
    }

    /// Nobody opened this file, so a copy the library holds follows the batch rule whether Parola is idle
    /// or busy: skipped and counted with the batch's duplicates, never a sheet or a jump to the stored entry.
    func handleWatchedArrival(_ url: URL) {
        let previous = watchedImportTask
        let deadline = fileReadDeadline
        let skipsDuplicates = duplicateImportPolicy.batchSkipsDuplicates
        watchedImportTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var lookup: DuplicateNotice.Lookup?
            if skipsDuplicates {
                lookup = await DuplicateNotice.lookup(for: url, in: self.library, deadline: deadline)
            }
            let digest = lookup?.digest
            if lookup?.entry != nil {
                guard !Task.isCancelled else { return }
                self.batchDuplicatesSkipped += 1
                ParolaLog.info(.library, "skipped a watched-folder file the library already holds")
                return
            }
            guard !Task.isCancelled else { return }
            self.startWatchedArrival(url, sourceDigest: digest)
        }
    }

    // A user opening a file replaces the current run, but folder arrivals must not: two files
    // landing together would cancel each other and only the last one would be transcribed.
    private func startWatchedArrival(_ url: URL, sourceDigest: String?) {
        if transcribeTaskRunning || phaseDefersArrivals || batchIsRunning {
            deferredArrivals.append(url)
            return
        }
        introduction.defer()
        beginFileTranscription(fileURL: url, translateOverride: nil, sourceDigest: sourceDigest)
    }

    /// Waits for the duplicate check a watched arrival goes through before it runs or waits its turn.
    func awaitWatchedImport() async {
        while let task = watchedImportTask {
            await task.value
            if watchedImportTask == task { watchedImportTask = nil }
        }
    }

    // MARK: - Live captions

    @ObservationIgnored weak var liveCaptions: LiveCaptionsController?

    /// Nil when the selected model can stream live captions; otherwise the user-facing reason.
    var liveCaptionsUnavailableReason: String? {
        guard !ModelCatalog.canStream(id: selectedModel) else { return nil }
        return "\(AppModel.modelLabel(selectedModel)) can't stream Live Captions. Pick a Whisper model first."
    }

    func toggleLiveCaptions() {
        introduction.defer()
        guard features.isEnabled(.liveCaptions) else { return }
        guard let liveCaptions else { return }
        if !liveCaptions.isActive, let reason = liveCaptionsUnavailableReason {
            switch phase {
            case .idle, .ready, .failed:
                phase = .failed(message: reason)
            default:
                break
            }
            return
        }
        let device = inputDeviceUID.isEmpty ? nil : inputDeviceUID
        Task { await liveCaptions.toggle(options: makeOptions(task: .transcribe, model: selectedModel, language: selectedLanguage), deviceUID: device) }
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
            guard oldValue != dictationKeyCode else { return }
            defaults.set(dictationKeyCode, forKey: "dictationKeyCode")
            if !isReloadingSettings { restartDictation() }
        }
    }

    var dictationKeyModifiers: Int = 0 {
        didSet {
            guard oldValue != dictationKeyModifiers else { return }
            defaults.set(dictationKeyModifiers, forKey: "dictationKeyModifiers")
            if !isReloadingSettings { restartDictation() }
        }
    }

    var dictationModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(dictationKeyModifiers))
            .intersection(.deviceIndependentFlagsMask)
    }

    var dictationIndicatorStyleRaw: String = DictationIndicatorStyle.nearField.rawValue {
        didSet {
            defaults.set(dictationIndicatorStyleRaw, forKey: "dictationIndicatorStyleRaw")
            if !isReloadingSettings { applyIndicatorStyleChange() }
        }
    }

    var dictationMode: DictationMode {
        DictationMode(rawValue: dictationModeRaw) ?? .pushToTalk
    }

    var dictationIndicatorStyle: DictationIndicatorStyle {
        DictationIndicatorStyle(rawValue: dictationIndicatorStyleRaw) ?? .nearField
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
    @ObservationIgnored private(set) var activeSideEffects: Set<BootstrapSideEffect> = []
    @ObservationIgnored let features: FeatureSet
    @ObservationIgnored let introduction: IntroductionController

    private func themeKeySnapshot() -> [String] {
        [appTheme, appAccentRaw, String(themeIsCustom), themeCustomPaletteJSON]
    }

    /// Re-reads every persisted setting into its observed property after a Reset or Import, suppressing the
    /// side-effecting didSets during the bulk read, then re-applying the side effects once. Avoids a relaunch.
    /// The one place persisted settings are read into their observed properties.
    /// Both init and reloadSettings call this inside an isReloadingSettings bracket,
    /// so a key added here is automatically covered by Reset and Import.
    private func readPersistedSettings() {
        self.dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        self.dictationModeRaw = defaults.string(forKey: "dictationModeRaw") ?? DictationMode.pushToTalk.rawValue
        self.dictationKeyCode = defaults.object(forKey: "dictationKeyCode") == nil ? 96 : defaults.integer(forKey: "dictationKeyCode")
        self.dictationKeyModifiers = defaults.object(forKey: "dictationKeyModifiers") == nil ? 0 : defaults.integer(forKey: "dictationKeyModifiers")
        self.dictationIndicatorStyleRaw = defaults.string(forKey: "dictationIndicatorStyleRaw") ?? DictationIndicatorStyle.nearField.rawValue
        self.dictationCleanupPromptID = defaults.string(forKey: "dictationCleanupPromptID") ?? ""
        self.dictationPerAppOverridesJSON = defaults.string(forKey: "dictationPerAppOverridesJSON") ?? "{}"
        self.transcriptDisplayModeRaw = defaults.string(forKey: "transcriptDisplayMode") ?? TranscriptDisplayMode.transcript.rawValue
        self.useStreaming = readBool("useStreaming", default: true)
        self.wordTimestamps = defaults.bool(forKey: "wordTimestamps")
        self.karaokeHighlight = readBool("karaokeHighlight", default: true)
        self.initialPrompt = defaults.string(forKey: "initialPrompt") ?? ""
        self.diarize = defaults.bool(forKey: "diarize")
        self.expectedSpeakersRaw = defaults.integer(forKey: "expectedSpeakersRaw")
        self.generatesCardMetadata = readBool("generateCardMetadata", default: true)
        self.showAITitles = readBool("showAITitles", default: true)
        self.showAISummaries = readBool("showAISummaries", default: true)
        self.customTitlePrompt = defaults.string(forKey: "customTitlePrompt") ?? ""
        self.customSummaryPrompt = defaults.string(forKey: "customSummaryPrompt") ?? ""
        self.summaryOptions = readJSON(SummaryOptions.self, forKey: "summaryOptions") ?? .default
        self.autostartSummary = readBool("autostartSummary", default: false)
        self.meetingCaptureAppOnly = defaults.bool(forKey: "meetingCaptureAppOnly")
        self.subtitleFPS = readDouble("subtitleFPS", default: 30)
        self.subtitleCaptionLengthRaw = defaults.string(forKey: "subtitleCaptionLength") ?? CaptionLength.none.rawValue
        self.transcriptCompact = defaults.bool(forKey: "transcriptCompact")
        self.showSubtitleQC = defaults.bool(forKey: "showSubtitleQC")
        self.translationSideBySide = readBool("translationSideBySide", default: true)
        self.skipSilences = defaults.bool(forKey: "skipSilences")
        self.pausePlayerOnAppHidden = defaults.bool(forKey: "pausePlayerOnAppHidden")
        self.markdownTimestamps = defaults.bool(forKey: "markdownTimestamps")
        self.txtExportTimestamps = defaults.bool(forKey: "txtExportTimestamps")
        self.burnFontSizeRaw = defaults.string(forKey: "burnFontSize") ?? BurnFontSize.medium.rawValue
        self.burnTextColorRaw = defaults.string(forKey: "burnTextColor") ?? BurnTextColor.white.rawValue
        self.burnOutline = readBool("burnOutline", default: true)
        self.htmlExportThemeRaw = defaults.string(forKey: "htmlExportTheme") ?? HtmlExportTheme.light.rawValue
        self.autoExportFolder = readJSON(AutoExportFolder.self, forKey: "autoExportFolder")
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
        let visibility = AppModel.storedVisibilityMode(in: defaults)
        defaults.set(visibility.rawValue, forKey: "appVisibilityMode")
        // The old toggle has had its say; leaving it behind would let it out-vote a later reset.
        defaults.removeObject(forKey: "showMenuBarExtra")
        self.appVisibilityModeRaw = visibility.rawValue
        applyAppVisibilityMode()
        self.playSoundWhenFinished = defaults.bool(forKey: "playSoundWhenFinished")
        self.duplicateImportPolicyRaw = defaults.string(forKey: "duplicateImportPolicy") ?? DuplicateImportPolicy.alwaysAsk.rawValue
        self.recordingCountInSeconds = defaults.integer(forKey: "recordingCountInSeconds")
        self.autoMuteWhileRecording = defaults.bool(forKey: "autoMuteWhileRecording")
        self.autoPauseMediaWhileRecording = defaults.bool(forKey: "autoPauseMediaWhileRecording")
        self.inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? ModelCatalog.defaultModelID()
        self.selectedLanguageRaw = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        self.translate = defaults.bool(forKey: "translate")
        self.appTheme = defaults.string(forKey: "appTheme") ?? "system"
        self.monospacedTimestamps = readBool("monospacedTimestamps", default: true)
        self.sidebarDensity = defaults.string(forKey: "sidebarDensity") ?? "comfortable"
        self.appAccentRaw = defaults.string(forKey: AppAccent.storageKey) ?? AppAccent.defaultAccent.rawValue
        self.themeIsCustom = defaults.bool(forKey: "themeIsCustom")
        self.themeCustomPaletteJSON = defaults.string(forKey: "themeCustomPaletteJSON") ?? ""
        self.automationBridgeEnabled = readBool("automationBridgeEnabled", default: AppModel.defaultBridgeEnabled)
        self.sparkleChannelRaw = defaults.string(forKey: "sparkleChannel") ?? SparkleChannel.stable.rawValue
        self.sparkleAutomatic = readBool("sparkleAutomatic", default: true)
        self.liveCaptionsTranslate = defaults.bool(forKey: "liveCaptionsTranslate")
        self.remoteAIAcknowledged = defaults.bool(forKey: "remoteAIAcknowledged")
        self.showMostUsedPeople = readBool("showMostUsedPeople", default: true)
        self.openEntriesInNewWindow = defaults.bool(forKey: "openEntriesInNewWindow")
        introduction.reloadFromDefaults()
    }

    func reloadSettings() {
        let themeBefore = themeKeySnapshot()

        isReloadingSettings = true
        readPersistedSettings()
        loadAutoExportRules()
        loadAIServices()
        loadDestinations()
        loadExportPresets()
        loadBatchExportSelection()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        loadSnippets()
        loadCorrectionRules()
        isReloadingSettings = false

        refreshModelList()
        Task { await refreshPeople() }
        if themeKeySnapshot() != themeBefore {
            repaintTheme()
        }
        // Re-apply only the side effects this launch actually wired (skipped under skipBootstrap tests).
        if !dictationEnabled {
            turnOffDictation()
        } else if activeSideEffects.contains(.dictationHotkey) {
            stopDictation()
            startDictation()
        }
        if activeSideEffects.contains(.sparkle) {
            applySparkleChannelChange()
            SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic
        }
        if activeSideEffects.contains(.liveCaptionsTranslateRestore) {
            applyLiveCaptionsTranslateChange()
        }
        if activeSideEffects.contains(.meetingDetector) {
            meetingDetector.reloadFromDefaults()
        }
        switch AppModel.bridgeReloadAction(
            sideEffects: activeSideEffects,
            mode: mode,
            enabled: automationBridgeEnabled,
            running: automationBridgeRunning
        ) {
        case .start: startAutomationBridge()
        case .stop: stopAutomationBridge()
        case .keep: break
        }
        if activeSideEffects.contains(.watchedFolders) {
            watchedFolders.reloadFromDefaults()
        }
    }
    var appAccentRaw: String = AppAccent.defaultAccent.rawValue { didSet { defaults.set(appAccentRaw, forKey: AppAccent.storageKey) } }

    var appAccent: AppAccent {
        get { AppAccent(rawValue: appAccentRaw) ?? .defaultAccent }
        set { appAccentRaw = newValue.rawValue }
    }

    var themeIsCustom: Bool = false { didSet { defaults.set(themeIsCustom, forKey: "themeIsCustom") } }
    var themeCustomPaletteJSON: String = "" { didSet { defaults.set(themeCustomPaletteJSON, forKey: "themeCustomPaletteJSON") } }

    /// Bumped on every theme change. The window root keys `.id` off it so the whole tree repaints —
    /// most leaf views read DS.Color.* statically and would not otherwise re-render on a palette swap.
    private(set) var themeRevision: Int = 0

    /// What the colour wells are showing while an edit is still going; the rest of the app waits for it.
    private(set) var paletteDraft: ThemePalette?
    @ObservationIgnored private var paletteDraftTask: Task<Void, Never>?

    var editablePalette: ThemePalette { paletteDraft ?? DS.theme }

    var themeSelection: ThemeSelection {
        if themeIsCustom, let palette = decodedCustomPalette() {
            return .custom(palette)
        }
        return .preset(ThemePreset(rawValue: appAccentRaw) ?? .defaultPreset)
    }

    @discardableResult
    func applyTheme() -> ThemePalette {
        let palette = themeSelection.palette
        DS.theme = palette
        DockIcon.refresh()
        return palette
    }

    func selectThemePreset(_ raw: String) {
        appAccentRaw = raw
        themeIsCustom = false
        repaintTheme()
    }

    func applyCustomPalette(_ palette: ThemePalette) {
        guard let data = try? AppModel.sharedJSONEncoder.encode(palette),
              let json = String(data: data, encoding: .utf8) else { return }
        themeCustomPaletteJSON = json
        themeIsCustom = true
        repaintTheme()
    }

    func resetToPresetTheme() {
        themeIsCustom = false
        repaintTheme()
    }

    /// Re-enables custom colors with the saved palette. Returns false when nothing
    /// saved decodes, so the caller can seed a fresh palette instead.
    func resumeCustomPalette() -> Bool {
        guard decodedCustomPalette() != nil else { return false }
        themeIsCustom = true
        repaintTheme()
        return true
    }

    /// Saved at once but painted only when the edit ends: repainting mid-edit pulls the well from under the open colour panel.
    func previewCustomPalette(_ palette: ThemePalette) {
        guard let data = try? AppModel.sharedJSONEncoder.encode(palette),
              let json = String(data: data, encoding: .utf8) else { return }
        themeCustomPaletteJSON = json
        themeIsCustom = true
        paletteDraft = palette
        paletteDraftTask?.cancel()
        paletteDraftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !Self.colorPanelIsVisible else { return }
            self?.commitPaletteDraft()
        }
    }

    /// Repaints the app with the wells' palette once the colour panel closes or the wells go away.
    func commitPaletteDraft() {
        guard paletteDraft != nil else { return }
        repaintTheme()
    }

    /// Waits for the check that lands an edit made without the colour panel open.
    func awaitPaletteDraft() async {
        await paletteDraftTask?.value
    }

    private func repaintTheme() {
        paletteDraftTask?.cancel()
        paletteDraftTask = nil
        paletteDraft = nil
        applyTheme()
        themeRevision &+= 1
    }

    private static var colorPanelIsVisible: Bool {
        NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
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
    @ObservationIgnored let dictationPermissions = DictationPermissions()
    @ObservationIgnored let capturePermissions = SystemCapturePermissions()

    var dictationState: DictationCoordinator.State = .idle
    /// The meter the take in progress writes; set once per take, never per buffer.
    private(set) var recordingLevelMeter: LevelMeter?
    var recordingIsSilent: Bool = false
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
    var meetingCaptureAppOnly: Bool = false { didSet { defaults.set(meetingCaptureAppOnly, forKey: "meetingCaptureAppOnly") } }
    @ObservationIgnored var pendingRecordingCategory: EntryCategory = .transcription
    /// Where the take in flight is listening, for the manifest a persist writes after the phase has moved on.
    @ObservationIgnored var pendingRecordingSource: EntrySource = .microphone
    @ObservationIgnored var pendingCaptureBundleIDs: Set<String>?
    @ObservationIgnored lazy var meetingDetector: MeetingDetector = MeetingDetector { [weak self] appName in
        guard let self else { return }
        // Never prompt over in-flight work: accepting would stomp a live recording.
        switch self.phase {
        case .idle, .ready, .failed:
            // A presented alert's title never updates, so keep the first prompt — accept
            // and decline must act on the app name the user is actually reading.
            if self.meetingDetectedApp == nil { self.meetingDetectedApp = appName }
        default: break
        }
    }

    // MARK: - Library

    @ObservationIgnored let library: LibraryStore
    var libraryEntries: [LibraryEntry] = [] {
        didSet {
            rebuildLibraryIndex()
            libraryVersion &+= 1
            let counts = Self.personUsageCounts(in: libraryEntries)
            if counts != personUsageCounts { personUsageCounts = counts }
            updateSelectedEntryHasFavorites()
        }
    }
    /// How many speaker labels across the library stand for each person. Read off the maps, so an assignment an undo takes back stops counting.
    private(set) var personUsageCounts: [UUID: Int] = [:]
    private(set) var libraryVersion: Int = 0
    var deletedEntries: [LibraryEntry] = []
    /// What Recently Deleted's bulk actions act on. It lives here so the page's header and the bridge read one selection.
    var recentlyDeletedSelection: Set<LibraryEntry.ID> = []
    /// The open query's hits, best first. Ids, not entries: a row resolves against the library, so a hit that was renamed or deleted shows as it is now.
    var searchRanking: [LibraryEntry.ID]? {
        didSet {
            searchResultsVersion &+= 1
            if hasSearchResults != (searchRanking != nil) { hasSearchResults = searchRanking != nil }
        }
    }
    /// Whether a query's results are up, for readers that don't care which results they are.
    private(set) var hasSearchResults = false
    var searchResults: [LibraryEntry]? {
        searchRanking.map { $0.compactMap(libraryEntry(id:)) }
    }
    /// Lets a waiter tell "the query finished" from "the query returned what the last one did".
    @ObservationIgnored private(set) var searchResultsVersion: Int = 0
    var searchQuery: String = ""
    /// Bumped by Edit › Search Library; the toolbar field watches the count rather than a flag the menu would have to clear.
    var librarySearchFocusRequests: Int = 0
    /// True while the content area shows a library list instead of the phase machine's panes.
    var isBrowsingLibrary: Bool {
        guard route == .transcript, batchIsEmpty else { return false }
        switch phase {
        case .idle, .ready:
            // Results the transcript did not come from take the content area; clearing them gives it back.
            if hasTranscript { return hasSearchResults && !openedFromSearch }
            return hasSearchResults || libraryFilter != nil || libraryBrowsingAll
        default: return false
        }
    }

    private var openedFromSearch: Bool {
        if case .search = transcriptOrigin { return true }
        return false
    }

    /// The origin belongs to the entry it was recorded for, so an import, a recording or a document arrives with none.
    var transcriptOrigin: LibraryOrigin? {
        guard let selectedEntryID, selectedEntryID == libraryOriginEntryID else { return nil }
        return libraryOrigin
    }

    /// The transcript is a drill-down only when it stands alone; in a batch the list is already beside it.
    var canReturnToOrigin: Bool {
        hasTranscript && batchIsEmpty && route == .transcript && !isBrowsingLibrary
    }
    /// Why each result matched, keyed by entry: the snippet the results list shows under the row.
    var searchMatches: [String: LibrarySearchIndex.Match] = [:]
    /// The results whose snippet is built or on its way; the rest wait until the list shows them.
    @ObservationIgnored var searchSnippetIDs: Set<LibraryEntry.ID> = []
    /// The query the published results were run for.
    @ObservationIgnored var searchResultsQuery: String?
    var selectedEntryID: LibraryEntry.ID? {
        didSet {
            guard oldValue != selectedEntryID else { return }
            transcriptPaneMode = .transcript
            updateSelectedEntryHasFavorites()
        }
    }
    /// The menus read this rather than `favoriteSegmentIDs`, which would tie them to every library write.
    private(set) var selectedEntryHasFavorites = false

    // MARK: - Transcript windows

    @ObservationIgnored let entryWindows = EntryWindowRegistry()
    @ObservationIgnored var openEntryWindowAction: ((LibraryEntry.ID) -> Void)?
    var keyViewerEntryIDs: Set<LibraryEntry.ID> = []
    var openEntriesInNewWindow: Bool = false {
        didSet { defaults.set(openEntriesInNewWindow, forKey: "openEntriesInNewWindow") }
    }

    @ObservationIgnored private var libraryEntriesByID: [String: LibraryEntry] = [:]

    private func rebuildLibraryIndex() {
        libraryEntriesByID = Dictionary(uniqueKeysWithValues: libraryEntries.map { ($0.id, $0) })
    }

    private func updateSelectedEntryHasFavorites() {
        let hasFavorites = selectedEntryID
            .flatMap { libraryEntriesByID[$0] }
            .map { !$0.manifest.favoriteSegments.isEmpty } ?? false
        if selectedEntryHasFavorites != hasFavorites { selectedEntryHasFavorites = hasFavorites }
    }

    func libraryEntry(id: LibraryEntry.ID) -> LibraryEntry? {
        // The index is @ObservationIgnored, so readers only repaint if they also touch the version it is rebuilt with.
        _ = libraryVersion
        return libraryEntriesByID[id]
    }

    struct FilterVocabulary {
        var labels: [String] = []
        var languages: [String] = []
        var personIDs: [UUID] = []
    }

    @ObservationIgnored private var cachedVocabulary: [EntryCategory?: FilterVocabulary] = [:]
    @ObservationIgnored private var cachedVocabularyVersion: Int = -1

    /// The labels in use in one category, sorted. The inspector and the filter bar both read it several times per body.
    func knownLabels(in category: EntryCategory?) -> [String] { vocabulary(in: category).labels }

    /// The language codes in use in one category, sorted.
    func knownLanguages(in category: EntryCategory?) -> [String] { vocabulary(in: category).languages }

    /// Every label in the library. Label suggestions are not scoped to the category the entry happens to be in.
    var allKnownLabels: [String] { knownLabels(in: nil) }

    /// The people with at least one entry in one category, in the order every people list shows them.
    func knownPeople(in category: EntryCategory?) -> [Person] {
        let ids = Set(vocabulary(in: category).personIDs)
        return peopleByUse.filter { ids.contains($0.id) }
    }

    private func vocabulary(in category: EntryCategory?) -> FilterVocabulary {
        let version = libraryVersion
        if cachedVocabularyVersion != version {
            cachedVocabulary.removeAll(keepingCapacity: true)
            cachedVocabularyVersion = version
        }
        if let cached = cachedVocabulary[category] { return cached }
        var seenLabels = Set<String>()
        var seenLanguages = Set<String>()
        var seenPeople = Set<UUID>()
        var found = FilterVocabulary()
        for entry in libraryEntries where category == nil || entry.category == category {
            for label in entry.labels where seenLabels.insert(label).inserted {
                found.labels.append(label)
            }
            if let code = LanguageDisplay.code(for: entry.language), seenLanguages.insert(code).inserted {
                found.languages.append(code)
            }
            for id in entry.personIDs where seenPeople.insert(id).inserted {
                found.personIDs.append(id)
            }
        }
        found.labels.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        found.languages.sort()
        cachedVocabulary[category] = found
        return found
    }
    var libraryFilter: EntryCategory?
    /// True when the "All" chip is showing the flat all-categories list. Distinguishes All from Home, which both leave libraryFilter nil.
    var libraryBrowsingAll: Bool = false
    /// Which list the open transcript was opened from; read it through `transcriptOrigin`, which pairs it with the entry.
    var libraryOrigin: LibraryOrigin?
    var libraryOriginEntryID: LibraryEntry.ID?
    var librarySortOrder: LibrarySortOrder = .newest {
        didSet {
            reapplyLibrarySort()
            // This is the one order that reads a field `sameEntries` masks, so it sorts on manifests it must re-read first.
            if librarySortOrder == .lastOpened { refreshLibrary() }
        }
    }
    // Observed on purpose: the settings pane reads these, and refreshBundleSizes fills them asynchronously, so the assignment must re-render.
    var libraryBundleSizes: [String: Int64] = [:] {
        didSet { libraryBundleSizesVersion &+= 1 }
    }
    /// The library list watches this instead of diffing a dictionary with one key per entry.
    private(set) var libraryBundleSizesVersion: Int = 0
    /// The opening of each entry's transcript, read from the search index so a row never opens a bundle.
    var libraryExcerpts: [LibraryEntry.ID: String] = [:] {
        didSet { libraryExcerptsVersion &+= 1 }
    }
    private(set) var libraryExcerptsVersion: Int = 0
    @ObservationIgnored var libraryExcerptsTask: Task<Void, Never>?
    @ObservationIgnored var libraryExcerptsGeneration = 0
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var libraryRefreshTask: Task<Void, Never>?
    /// How many scans `refreshLibrary()` has started, so a test can bound them.
    @ObservationIgnored var libraryRefreshes = 0
    @ObservationIgnored var pendingTranscriptSaveTask: Task<Void, Never>?
    @ObservationIgnored var pendingTranscriptSaveGeneration: Int = 0
    @ObservationIgnored private var pendingSaveTextChanged = false
    @ObservationIgnored weak var undoManager: UndoManager?
    static let trashRetentionDays = 30

    // MARK: - Engine

    @ObservationIgnored let session = TranscriptionSession()
    @ObservationIgnored private let store = ModelStore.shared
    @ObservationIgnored let mediaSession = MediaSession()

    func mediaSessionConfig(allowMute: Bool) -> MediaSessionConfig {
        MediaSessionConfig(
            muteSystemAudio: allowMute && autoMuteWhileRecording,
            pausePlayback: autoPauseMediaWhileRecording
        )
    }

    /// System-audio takes get an inert config: pausing or muting media would silence
    /// the very audio being recorded.
    func recordingMediaConfig(for source: RecordSource) -> MediaSessionConfig {
        source == .microphone ? mediaSessionConfig(allowMute: true) : .none
    }

    @ObservationIgnored var liveSource: AudioSource?
    @ObservationIgnored var deferredArrivals: [URL] = []
    @ObservationIgnored var deferredLinks: [DeferredLink] = []
    @ObservationIgnored var pendingOpenedFiles: [URL] = []
    var pendingLargeDrop: PendingLargeDrop?
    @ObservationIgnored var openedFilesFlushTask: Task<Void, Never>?
    @ObservationIgnored private var streamingSession: (any StreamingTranscriber)?
    @ObservationIgnored var streamingConsumer: Task<Void, Never>?
    @ObservationIgnored var fileTranscribeTask: Task<Void, Never>?
    @ObservationIgnored var fileRunLanding: FileRunLanding?
    @ObservationIgnored let fileReadDeadline: Duration
    @ObservationIgnored private var cancelPass = 0
    @ObservationIgnored private var unsettledInPass = 0
    /// Bumped by every file run. An abandoned run's engine can keep emitting after the slot has
    /// moved on, and its partials would land in the pane the next run is filling.
    @ObservationIgnored private(set) var fileRunGeneration = 0
    @ObservationIgnored var recordingOutcomeWaiters: [CheckedContinuation<String, any Error>] = []
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeTranscribeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var youtubeSubsTask: Task<Void, Never>?
    @ObservationIgnored private var recordingStartInFlight = false
    @ObservationIgnored private var stopRequestedDuringStart = false
    @ObservationIgnored var derivedArtifactsGeneration = 0
    @ObservationIgnored var loadEntryGeneration = 0
    @ObservationIgnored var launchPurgeTask: Task<Void, Never>?

    /// A fresh token for a file run's handlers; an older one belongs to a run that has been replaced.
    func nextFileRunToken() -> Int {
        fileRunGeneration &+= 1
        return fileRunGeneration
    }

    /// An ended run stops matching its own token: a cancelled engine can keep emitting after the run lets go.
    func retireFileRun(_ runToken: Int) {
        guard fileRunGeneration == runToken else { return }
        fileRunGeneration &+= 1
    }

    /// Whatever run holds the token loses it, and what it last painted goes with it.
    private func retireCurrentFileRun() {
        fileRunGeneration &+= 1
        if !filePartialText.isEmpty { filePartialText = "" }
        fileTranscribeFraction = nil
        fileTranscribeStage = nil
    }

    var transcribeTaskRunning: Bool {
        fileTranscribeTask != nil || youtubeTranscribeTask != nil || youtubeSubsTask != nil
            || duplicateCheckTask != nil
    }

    /// The runs that paint a phase of their own. A duplicate-check digest is not one: it hashes the
    /// file before its run claims the phase, so a bar behind it is still the download's to hand back.
    var runOwnsPhase: Bool {
        fileTranscribeTask != nil || youtubeTranscribeTask != nil || youtubeSubsTask != nil
            || batchTask != nil
    }

    /// A stop held for the startup window: no transcribe task yet, but the take still resolves an outcome.
    var stopHeldForStartup: Bool {
        recordingStartInFlight && stopRequestedDuringStart
    }

    /// A user-initiated start (file open, YouTube, recording) replaces whichever of these runs
    /// is in flight; letting the old one finish would stomp the new run's transcript later.
    private func cancelTranscriptionRuns(keepingDuplicateCheck: Bool = false) {
        if !keepingDuplicateCheck {
            duplicateCheckTask?.cancel()
            duplicateCheckTask = nil
        }
        if fileTranscribeTask != nil { retireCurrentFileRun() }
        fileTranscribeTask?.cancel()
        fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel()
        youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel()
        youtubeSubsTask = nil
    }

    var canCancel: Bool {
        hasForegroundWork || burnTask != nil
    }

    /// Everything Cancel stops ahead of a burn, which runs beside the rest and has its own Cancel.
    private var hasForegroundWork: Bool {
        batchTask != nil || streamingConsumer != nil || fileTranscribeTask != nil || downloadTask != nil
            || youtubeTranscribeTask != nil || youtubeSubsTask != nil
    }

    private func teardownActiveCapture() {
        if recordingStartInFlight, liveSource == nil { stopRequestedDuringStart = true }
        stopSilenceWatch()
        clearRecordingLevelMeter()
        stopRecordingWatch()
        endActiveRecovery()
        liveRecordingAudioURL = nil
        cancelAndTrack(&streamingConsumer)
        if let s = streamingSession {
            streamingSession = nil
            Task { await s.cancel() }
        }
        if let source = liveSource {
            liveSource = nil
            Task { await source.cancel() }
        }
        Task { await mediaSession.exitRecording() }
        pendingRecordingCategory = .transcription
    }

    func cancelCurrentWork() {
        let hadWork = hasForegroundWork || liveSource != nil
        // A new pass reports on its own runs only: one abandoned an hour ago must not make an
        // honest cancel look like it never finished.
        cancelPass &+= 1
        unsettledInPass = 0
        cancelAllInFlightBatchJobs()
        deferredArrivals = []
        deferredLinks = []
        cancelAndTrack(&downloadTask)
        cancelAndTrack(&fileTranscribeTask)
        retireCurrentFileRun()
        cancelAndTrack(&youtubeTranscribeTask)
        cancelAndTrack(&youtubeSubsTask)
        // Cancel stops what the window shows; a burn behind a run is stopped from its own strip.
        if !hadWork { cancelBurn() }
        teardownActiveCapture()
        resolveRecordingOutcome(.failure(IntentActionError.cancelled))
        if hadWork || phase != .ready { phase = .idle }
    }

    func cancelAndTrack(_ task: inout Task<Void, Never>?) {
        guard let running = task else { return }
        running.cancel()
        task = nil
        let pass = cancelPass
        unsettledInPass += 1
        Task { [weak self] in
            await running.value
            guard let self, self.cancelPass == pass else { return }
            self.unsettledInPass -= 1
        }
    }

    /// True once every run this pass asked to stop has actually unwound. A run parked in a
    /// blocking read has not, and calling that cancelled is how the wedge went unnoticed.
    var cancelSettled: Bool { unsettledInPass == 0 }

    func awaitCancelSettled(within budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while !cancelSettled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return cancelSettled
    }

    func cancelAllTasks() {
        countdownTask?.cancel(); countdownTask = nil
        batchTask?.cancel(); batchTask = nil
        matchesDebounce?.cancel(); matchesDebounce = nil
        silenceWatchTask?.cancel(); silenceWatchTask = nil
        recordingAutoStopTask?.cancel(); recordingAutoStopTask = nil
        recordingWatchTask?.cancel(); recordingWatchTask = nil
        searchTask?.cancel(); searchTask = nil
        downloadTask?.cancel(); downloadTask = nil
        fileTranscribeTask?.cancel(); fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel(); youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel(); youtubeSubsTask = nil
        burnTask?.cancel(); burnTask = nil
        teardownActiveCapture()
        resolveRecordingOutcome(.failure(IntentActionError.cancelled))
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
        // Same capability gate as makeOptions: engines that can't translate would
        // otherwise get .translate re-instated by the captions controller.
        let enabled = liveCaptionsTranslate && selectedModelCapabilities.supportsTranslate
        Task { await liveCaptions?.setTranslate(enabled) }
    }

    enum BridgeReloadAction: Equatable { case start, stop, keep }

    // Test-mode bridges are launch-owned: the harness that issued the import/reset is talking through one.
    static func bridgeReloadAction(
        sideEffects: Set<BootstrapSideEffect>,
        mode: AppBootstrap.Mode,
        enabled: Bool,
        running: Bool
    ) -> BridgeReloadAction {
        guard sideEffects.contains(.automationBridge), mode == .normal, enabled != running else { return .keep }
        return enabled ? .start : .stop
    }

    func startAutomationBridge() {
        guard testBridge == nil else { return }
        // A unit-test host must not serve the bridge: it would overwrite the discovery files
        // and expose the tests' AppModels to whatever harness connects mid-run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let auditLog = AutomationAuditLog()
        let bridge: ParolaAutomationServer
        do {
            bridge = try ParolaAutomationServer(model: self, auditLog: auditLog)
        } catch {
            ParolaLog.error(.appBridge, "bridge server could not be created", [.error: .error(error)])
            return
        }
        Task(priority: .utility) { await auditLog.sweep() }
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
    @ObservationIgnored let managedConfiguration: ManagedConfiguration
    @ObservationIgnored let apiKeyStore: any APIKeyStore

    // MARK: - Bootstrap

    init(bootstrap: AppBootstrap) {
        let defaults = bootstrap.defaults
        self.defaults = defaults
        let managed = ManagedConfiguration(storage: defaults)
        self.managedConfiguration = managed
        // A sandbox or a test must never reach the real keychain, so test mode keeps keys in memory.
        self.apiKeyStore = bootstrap.apiKeyStore
            ?? (bootstrap.mode == .test ? InMemoryAPIKeyStore() : KeychainAPIKeyStore.shared)
        self.features = bootstrap.enabledFeaturesOverride.map(FeatureSet.init(enabled:))
            ?? FeatureSet.resolve(managed: managed)
        let engineChoices = IntroductionEngineChoices.compute(
            catalog: ModelCatalog.all,
            managed: managed,
            isInstalled: { ModelStore.shared.isInstalled($0) }
        )
        self.introduction = IntroductionController(
            defaults: defaults,
            mode: bootstrap.mode,
            showsInTestMode: bootstrap.showsIntroduction,
            hasEngineChoice: !engineChoices.isEmpty,
            engineChoices: engineChoices.map(\.id)
        )
        self.filePicker = bootstrap.filePicker
        self.linkFetcher = bootstrap.linkFetcher ?? YtDlpLinkFetcher(features: features)
        self.mode = bootstrap.mode
        self.clock = bootstrap.clock
        self.fileReadDeadline = bootstrap.fileReadDeadline
        self.library = LibraryStore(libraryURL: bootstrap.library ?? LibraryStore.defaultLibraryURL)
        // Takes must outlive a failed transcription, a crash, and the OS temp purge.
        RecordingScratch.setDirectory(library.libraryURL.appendingPathComponent("inflight", isDirectory: true))
        // A --library override (tests, sandbox) must keep people suggestions out of the real store too.
        self.peopleStore = PeopleStore(
            storageURL: bootstrap.library.map { $0.appendingPathComponent("People.json") }
                ?? PeopleStore.defaultStorageURL
        )
        self.promptLibrary = PromptLibrary(
            storageURL: bootstrap.library.map { $0.appendingPathComponent("Prompts.json") }
                ?? PromptLibrary.defaultStorageURL
        )
        if bootstrap.mode == .test {
            self.completionSoundPlayer = nil
            self.refusalBeep = nil
        }
        // Suppress the settings didSets during the bulk read: side effects (notably startDictation)
        // must wait until after wireDictationController + the gated side-effect block below, or the
        // dictation coordinator is built before appModel is wired.
        isReloadingSettings = true
        readPersistedSettings()
        isReloadingSettings = false
        applyTheme()
        loadAutoExportRules()
        loadAIServices()
        loadDestinations()
        // Built here, not on first send: its init reloads the queue from disk and re-arms the
        // timers, so a delivery queued by an earlier launch does not wait for an unrelated send.
        if features.isEnabled(.destinations) {
            _ = deliveryEngine
            observeVolumeMounts()
        }
        loadExportPresets()
        loadBatchExportSelection()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        loadSnippets()
        loadCorrectionRules()
        refreshModelList()
        Task { await refreshPeople() }
        Task { [library] in await library.warmSearchIndex() }
        refreshLibrary()
        restoreBatchQueue()
        loadPendingRecovery()
        sweepInflightRecordings()
        if features.isEnabled(.dictation) {
            wireDictationController()
        }

        let sideEffects = bootstrap.sideEffects.subtracting(features.excludedSideEffects(mode: bootstrap.mode))
        self.activeSideEffects = sideEffects
        ParolaLog.info(
            .appLifecycle,
            "side effects \(TokenList(sideEffects)), features \(TokenList(features.enabled))"
        )
        if sideEffects.contains(.refreshYtDlp) {
            refreshYtDlpAvailability()
            Task { try? await AppModel.offMainIO(qos: .utility) { LinkDownloadFolders.removeStale() } }
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
            launchPurgeTask = Task { [weak self, library] in
                let purge = await library.purgeDeletedOlderThan(
                    days: AppModel.trashRetentionDays, now: Date()
                )
                guard purge.purged > 0 || purge.failed > 0 else { return }
                ParolaLog.info(
                    .library, "recently deleted purged on launch",
                    [.count: .int(purge.purged), .failed: .int(purge.failed)]
                )
                self?.refreshLibrary()
            }
        }
        if sideEffects.contains(.modelsPathSync),
           let override = UserDefaults.standard.string(forKey: ModelStore.storageOverrideKey),
           !override.trimmingCharacters(in: .whitespaces).isEmpty,
           !FileManager.default.fileExists(atPath: ModelStore.sharedOverrideFileURL.path) {
            // A custom models folder chosen before the shared file existed only lives in this
            // process's defaults; mirror it once so the CLI resolves the same folder.
            ModelStore.writeSharedOverride(override)
        }
        Task { [weak self] in
            await self?.refreshDictationTriggerPrompts()
        }
    }

    convenience init(
        skipBootstrap: Bool = false,
        defaults: UserDefaults = .standard,
        filePicker: FilePicker = SystemFilePicker(),
        libraryURL: URL? = nil,
        features: Set<ParolaFeature>? = nil,
        apiKeyStore: (any APIKeyStore)? = nil
    ) {
        let sideEffects: Set<BootstrapSideEffect> = skipBootstrap ? [] : BootstrapSideEffect.all
        let bootstrap = AppBootstrap(
            mode: .normal,
            library: libraryURL,
            defaultsOverride: defaults,
            sideEffects: sideEffects,
            filePicker: filePicker,
            enabledFeaturesOverride: features,
            // A test that skips bootstrap must not reach the real keychain either.
            apiKeyStore: apiKeyStore ?? (skipBootstrap ? InMemoryAPIKeyStore() : nil)
        )
        self.init(bootstrap: bootstrap)
    }

    deinit {
        recordingWatchTask?.cancel()
        streamingConsumer?.cancel()
        libraryRefreshTask?.cancel()
    }

    /// A non-fatal warning (e.g. a failed library save) shown without replacing the open transcript.
    var nonFatalWarning: String?

    /// Each main-actor turn a finished run lands in: the install, the saved entry, the AI card.
    static let landingSignposter = OSSignposter(subsystem: "app.parola.app", category: "landing")

    /// `activate: false` saves without taking the selection, auto-titling, or running
    /// auto-exports — for interrupted or failed takes that only need to survive.
    @discardableResult
    func persistToLibrary(
        _ result: Transcript,
        audioSource: URL?,
        source: EntrySource,
        title: String? = nil,
        activate: Bool = true,
        sourceDigest: String? = nil,
        playsCompletionSound: Bool = true,
        consumesAudio: Bool = false
    ) -> Task<LibraryEntry, any Error> {
        let category = pendingRecordingCategory
        pendingRecordingCategory = .transcription
        let navigationGeneration = loadEntryGeneration
        let adding = Task { [library] in
            try await library.add(
                transcript: result,
                audioSource: audioSource,
                category: category,
                title: title,
                sourceDigest: sourceDigest,
                source: source,
                consumesAudio: consumesAudio
            )
        }
        Task { [weak self] in
            guard let self else { return }
            var persisted: LibraryEntry?
            do {
                let entry = try await adding.value
                persisted = entry
                let landing = Self.landingSignposter.beginInterval("entry")
                landLibraryEntry(entry)
                // library.add copies media for seconds; if the user navigated meanwhile,
                // taking the selection would repoint their next edits at this new entry.
                if activate, loadEntryGeneration == navigationGeneration, selectedEntryID == nil {
                    selectedEntryID = entry.id
                }
                Self.landingSignposter.endInterval("entry", landing)
            } catch {
                ParolaLog.error(.library, "transcript could not be saved to the library", [.error: .error(error)])
                nonFatalWarning = "The transcript is still open, but Parola couldn't save it to your library. \(error.localizedDescription)"
            }
            // Exports read nothing the AI writes, so they don't wait for the card.
            if activate {
                runAutoExports(transcript: result, audioSource: audioSource, source: source, entry: persisted, title: title)
            }
            guard activate, let entry = persisted else { return }
            if playsCompletionSound { playCompletionSound() }
            let card = enqueueCardMetadata(for: entry.id, transcript: result)
            if autostartSummary,
               features.isEnabled(.ai),
               loadEntryGeneration == navigationGeneration, selectedEntryID == entry.id,
               result.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= CardMetadataService.minimumCharacters {
                summariseTranscript()
            }
            // Delivery sends the AI title, so only a send waits for the card.
            guard hasAutoSendDestination else { return }
            await card.value
            await autoSendEntry(entry.id)
        }
        return adding
    }

    /// One transcription, one batch run or one re-run has landed in the library.
    func playCompletionSound() {
        guard playSoundWhenFinished, let completionSoundPlayer else { return }
        completionSoundPlayer()
    }

    // MARK: - Model list

    var modelSizes: [String: Int64] = [:]
    var modelsBeingDeleted: Set<String> = []
    /// Last model download/delete failure, surfaced as a banner in the Models pane —
    /// the shared phase error renders in the main window, invisible behind Settings.
    var modelActionError: String?

    /// Count and bytes of models with an actual disk footprint, measured when available.
    /// Apple Speech reports installed but owns no files, so it's excluded. Both the
    /// Models pane and About read this — the two stats must never disagree.
    var modelsOnDiskSummary: (count: Int, bytes: Int64) {
        let onDisk = availableModels.filter { $0.isInstalled && $0.installedURL != nil }
        let bytes = onDisk.reduce(Int64(0)) { total, info in
            total + (modelSizes[info.name] ?? info.approximateSizeBytes.map(Int64.init) ?? 0)
        }
        return (onDisk.count, bytes)
    }

    @ObservationIgnored private var modelScanTask: Task<Void, Never>?

    /// Republishes the model list, off the main actor unless the store can replay a scan it already
    /// has. Launch and the bridge's post-`setSetting` reload both land here, so it must not block.
    func refreshModelList() {
        if let scan = store.cachedScan() {
            applyModelScan(scan)
            return
        }
        let store = self.store
        let previous = modelScanTask
        modelScanTask = Task { [weak self] in
            _ = await previous?.value
            guard let scan = try? await AppModel.offMainIO({ store.scan() }) else { return }
            self?.applyModelScan(scan)
        }
    }

    /// Waits for a pending off-main scan. The UI redraws when the list lands; tests need the seam.
    func awaitModelListRefresh() async {
        while let task = modelScanTask {
            await task.value
            if modelScanTask == task { modelScanTask = nil }
        }
    }

    private func applyModelScan(_ scan: ModelScan) {
        let curated = scan.listedCatalog
        let extra = scan.installed.filter { ent in
            !curated.contains { $0.name == ent.name }
        }
        availableModels = curated + extra

        if let corrected = AppModel.correctedSelectedModel(
            selectedModel, in: availableModels, downloading: downloadingModelName
        ) {
            selectedModel = corrected
        }
        refreshModelSizes()
    }

    /// The model `downloadModel` is fetching, or nil — a scan mid-download must not correct it away as if uninstalled.
    private var downloadingModelName: String? {
        if case .downloadingModel(let name, _) = phase { return name }
        return nil
    }

    /// nil when `current` is installed or still downloading, else the default — a deliberate pick must survive a scan landing mid-download.
    nonisolated static func correctedSelectedModel(
        _ current: String,
        in availableModels: [ModelInfo],
        downloading: String? = nil,
        defaultModelID: @autoclosure () -> String = ModelCatalog.defaultModelID()
    ) -> String? {
        if current == downloading { return nil }
        let installed = availableModels.filter(\.isInstalled)
        if installed.contains(where: { $0.name == current }) { return nil }
        return defaultModelID()
    }

    /// Drops orphan folders `ModelStore` surfaces for deletion — they aren't real choices, since they fail the catalog-id check by definition.
    nonisolated static func selectableModels(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { ModelCatalog.variant(id: $0.name) != nil }
    }

    nonisolated static func selectableModelNames(_ models: [ModelInfo]) -> [String] {
        selectableModels(models).map(\.name)
    }

    func refreshModelSizes() {
        let installed = availableModels.filter(\.isInstalled).compactMap { info in
            info.installedURL.map { (info.name, $0) }
        }
        let store = self.store
        Task { [weak self] in
            guard let sizes = try? await AppModel.offMainIO(qos: .utility, {
                var sizes: [String: Int64] = [:]
                for (name, url) in installed {
                    if let size = store.sizeOnDisk(at: url) {
                        sizes[name] = Int64(size)
                    }
                }
                return sizes
            }) else { return }
            self?.modelSizes = sizes
        }
    }

    func deleteModel(_ name: String) {
        guard !modelsBeingDeleted.contains(name) else { return }
        modelsBeingDeleted.insert(name)
        let store = self.store
        Task { [weak self] in
            let failure: (any Error)?
            do {
                // One row per model here and no leftovers list, so Delete frees every copy —
                // the CLI splits the two into `models rm` and `models rm --leftovers`.
                try await AppModel.offMainIO {
                    try AppModel.removeModelCopies(name, using: store)
                }
                failure = nil
            } catch {
                failure = error
            }
            guard let self else { return }
            self.modelsBeingDeleted.remove(name)
            self.refreshModelList()
            if let failure {
                let message = "Could not delete \(name): \(failure.localizedDescription)"
                self.phase = .failed(message: message)
                self.modelActionError = message
            }
        }
    }

    // Freeing the superseded copy alone still frees the disk, so only both removals failing is a failure.
    nonisolated static func removeModelCopies(_ name: String, using store: ModelStore) throws {
        let freedLeftovers = (try? store.deleteLeftovers(variant: name)) != nil
        do {
            try store.deleteAny(idOrPath: name)
        } catch {
            if !freedLeftovers { throw error }
        }
    }

    func prewarmSelectedModel() {
        let name = selectedModel
        guard store.isInstalled(name) else { return }
        Task.detached { [session] in
            await session.prewarm(modelName: name)
        }
    }

    /// Non-nil when a download would take over UI that another job is using. Downloads render
    /// through the shared phase, so starting one mid-take replaces the recording controls —
    /// Stop included — and hands the phase back as `.idle` when it finishes.
    var downloadBlockedReason: String? {
        if recordingActive { return "Stop the recording before downloading a model." }
        switch phase {
        case .transcribing, .loadingModel, .fetchingLink:
            return "Wait for the current job to finish before downloading a model."
        default:
            return nil
        }
    }

    /// A pick that never starts downloading, or stops without installing, must not stick as the
    /// selection — nothing besides a scan otherwise re-applies `correctedSelectedModel`.
    private func correctSelectionIfNeeded() {
        if let corrected = AppModel.correctedSelectedModel(
            selectedModel, in: availableModels, downloading: downloadingModelName
        ) {
            selectedModel = corrected
        }
    }

    @discardableResult
    func downloadModel(_ name: String) -> Bool {
        guard downloadTask == nil else {
            modelActionError = "Another download is already running. Wait for it to finish."
            correctSelectionIfNeeded()
            return false
        }
        if let reason = downloadBlockedReason {
            modelActionError = reason
            correctSelectionIfNeeded()
            return false
        }
        let progress = makeDownloadProgressHandler(for: name)
        downloadTask = Task {
            do {
                phase = .downloadingModel(name: name, progress: 0)
                // Cold launch reaches here before any transcribe has registered the engines,
                // and an empty registry silently swaps in the generic HuggingFace downloader.
                await ParolaCoreBootstrap.registerBuiltInEngines()
                _ = try await store.download(variant: name, progress: progress)
                finishModelDownload()
            } catch {
                if !Task.isCancelled {
                    let message = Self.offlineMessage(for: error)
                        ?? "Download failed: \(error.localizedDescription)"
                    phase = .failed(message: message)
                    modelActionError = message
                    correctSelectionIfNeeded()
                }
            }
            if !Task.isCancelled { downloadTask = nil }
        }
        return true
    }

    /// Hands the phase back only while it is still the download's: a run, a take or a batch owns it too.
    func finishModelDownload() {
        if !runOwnsPhase, case .downloadingModel = phase { phase = .idle }
        refreshModelList()
    }

    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloadingModel = phase { phase = .idle }
        refreshModelList()
    }

    // MARK: - File transcription

    func presentOpenPanel() {
        Task { [weak self] in
            guard let self else { return }
            let urls = await self.filePicker.chooseInputFiles(
                allowedTypes: [.audio, .movie] + Self.subtitleContentTypes,
                allowsMultiple: true
            )
            self.receive(urls) { [weak self] in self?.handleIncomingFiles($0) }
        }
    }

    // Arrivals must never stomp an active capture or batch (drops, watched folders, Services, URL scheme).
    var phaseDefersArrivals: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// A batch runs on the global translate setting, so the override only reaches a single-file run.
    func handleIncomingFiles(_ urls: [URL], translateOverride: Bool? = nil) {
        let files = DroppedFiles.classify(urls)
        guard !files.isEmpty else { return }
        introduction.defer()
        for url in files.subtitles { importSubtitle(fileURL: url) }
        takeLinks(files.links, behindMedia: !files.media.isEmpty)
        guard !files.media.isEmpty else {
            for project in files.projects {
                Task { [weak self] in await self?.openProjectDocument(at: project) }
            }
            return
        }
        if batchIsRunning {
            importBatchFiles(files.media)
        } else if files.media.count > 1, features.isEnabled(.batch) {
            importBatchFiles(files.media)
        } else {
            transcribe(fileURL: files.media[0], translateOverride: translateOverride)
            deferredArrivals.append(contentsOf: files.media.dropFirst())
        }
    }

    // MARK: - Subtitle import

    nonisolated static let subtitleImportExtensions: Set<String> = ["srt", "vtt"]

    nonisolated static func isSubtitleImport(_ url: URL) -> Bool {
        subtitleImportExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static var subtitleContentTypes: [UTType] {
        subtitleImportExtensions.sorted().flatMap {
            UTType.types(tag: $0, tagClass: .filenameExtension, conformingTo: nil)
        }
    }

    func importSubtitle(fileURL: URL) {
        if phaseDefersArrivals {
            deferredArrivals.append(fileURL)
            return
        }
        if batchIsRunning {
            deferredArrivals.append(fileURL)
            return
        }
        noteRecentFile(fileURL)
        let imported: Transcript
        do {
            imported = try Self.parseSubtitleFile(at: fileURL)
        } catch {
            phase = .failed(message: "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return
        }
        guard !imported.segments.isEmpty else {
            phase = .failed(message: "No subtitles found in \(fileURL.lastPathComponent).")
            return
        }
        let processed = postProcess(imported)
        let landing = Self.landingSignposter.beginInterval("install")
        defer { Self.landingSignposter.endInterval("install", landing) }
        clearDerivedArtifacts()
        selectedEntryID = nil
        sourceFileURL = fileURL
        tearDownPlayer()
        transcript = processed
        phase = .ready
        persistToLibrary(
            processed,
            audioSource: nil,
            source: .file,
            title: fileURL.deletingPathExtension().lastPathComponent,
            playsCompletionSound: false
        )
    }

    nonisolated static func parseSubtitleFile(at url: URL) throws -> Transcript {
        if url.pathExtension.lowercased() == "vtt" {
            var transcript = try VttImporter.parse(contentsOf: url)
            transcript.modelName = "imported-vtt"
            return transcript
        }
        return try SrtImporter.parse(contentsOf: url)
    }

    func transcribe(fileURL: URL, translateOverride: Bool? = nil) {
        introduction.defer()
        guard fileURL.isFileURL else {
            transcribeYouTube(urlString: fileURL.absoluteString)
            return
        }
        if phaseDefersArrivals {
            deferredArrivals.append(fileURL)
            return
        }
        if fileURL.pathExtension == "parola" {
            Task { [weak self] in await self?.openProjectDocument(at: fileURL) }
            return
        }
        if Self.isSubtitleImport(fileURL) {
            importSubtitle(fileURL: fileURL)
            return
        }
        if batchIsRunning {
            importBatchFiles([fileURL])
            return
        }
        startFileImport(fileURL: fileURL, translateOverride: translateOverride)
    }

    /// The run itself, past the routing and the duplicate check an arriving file goes through:
    /// Retry means this file, now. A link's download lands here too, and Retry then means the link.
    func beginFileTranscription(
        fileURL: URL, translateOverride: Bool?, sourceDigest: String? = nil, fetchedLink: FetchedLink? = nil
    ) {
        // Before the new token: cancelling retires the old run's token; a file opened mid-download keeps its duplicate check.
        cancelTranscriptionRuns(keepingDuplicateCheck: fetchedLink != nil)
        let runToken = nextFileRunToken()
        if fetchedLink == nil { noteRecentFile(fileURL) }
        if let fetchedLink, let title = fetchedLink.media.metadata.title {
            linkRunTitle = LinkRunTitle(file: fileURL, title: title)
        }
        sourceFileURL = fileURL
        installPlayer(for: fileURL)
        let probeSource = FileAudioSource(url: fileURL)
        let deadline = fileReadDeadline
        Task { [weak self] in
            let probe = await BoundedFileRead.run(deadline: deadline) {
                probeSource.synchronousDuration()
            }
            guard let self, self.fileRunGeneration == runToken else { return }
            guard case .done(let duration) = probe else {
                self.failFileReadTimeout(fileURL, fetchedLink: fetchedLink)
                return
            }
            if let duration, self.mediaDurationSeconds == nil { self.mediaDurationSeconds = duration }
        }
        filePartialText = ""
        fileTranscribeFraction = nil
        fileTranscribeStage = nil

        let task: TranscriptionTask = (translateOverride ?? translate) ? .translate : .transcribe
        let recoveryToken = fetchedLink.map {
            beginFileTranscribeRecovery(sourceURL: $0.link, title: $0.media.metadata.title, source: .web)
        } ?? beginFileTranscribeRecovery(sourceURL: fileURL)

        fileTranscribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                phase = store.isInstalled(selectedModel)
                    ? .loadingModel(name: selectedModel)
                    : .downloadingModel(name: selectedModel, progress: 0)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: fileURL),
                    options: makeOptions(task: task, model: selectedModel, language: selectedLanguage),
                    downloadProgress: makeDownloadProgressHandler(for: selectedModel),
                    partialHandler: makeFilePartialHandler(runToken: runToken),
                    progressHandler: makeFileProgressHandler(runToken: runToken),
                    stageHandler: makeFileStageHandler(fileURL: fileURL, runToken: runToken)
                )
                try Task.checkCancellation()
                var processed = await postProcessDetached(result)
                if let fetchedLink { processed.sourceURL = fetchedLink.media.metadata.webpageURL ?? fetchedLink.link }
                let landing = Self.landingSignposter.beginInterval("install")
                defer { Self.landingSignposter.endInterval("install", landing) }
                clearDerivedArtifacts()
                selectedEntryID = nil
                restorePlaybackSource(fileURL)
                transcript = processed
                adoptLoadedMediaDuration()
                filePartialText = ""
                fileTranscribeFraction = nil
                fileTranscribeStage = nil
                endRecovery(recoveryToken)
                phase = .ready
                let ownedDownload = fetchedLink.flatMap { $0.media.workingDirectory == nil ? nil : $0 }
                let entry = persistToLibrary(
                    processed,
                    audioSource: fileURL,
                    source: fetchedLink == nil ? .file : .web,
                    title: fetchedLink.map { $0.media.metadata.title ?? LibraryEntryDisplay.webVideoTitle(createdAt: Date()) },
                    sourceDigest: sourceDigest,
                    consumesAudio: ownedDownload != nil
                )
                fileRunLanding = FileRunLanding(runToken: runToken, text: processed.text, entry: entry)
                if let ownedDownload { followLinkAudioIntoLibrary(ownedDownload, entry: entry) }
                retireFileRun(runToken)
            } catch {
                endRecovery(recoveryToken)
                // Retry and recovery fetch the link again, so the download has no further use.
                fetchedLink?.media.discard()
                // A run a newer one replaced leaves the newer one's pane alone.
                if fileRunGeneration == runToken {
                    filePartialText = ""
                    fileTranscribeFraction = nil
                    fileTranscribeStage = nil
                    retireFileRun(runToken)
                }
                if !Task.isCancelled {
                    applyTranscriptionError(
                        error,
                        source: fetchedLink == nil ? fileURL : nil,
                        translateOverride: translateOverride,
                        link: fetchedLink?.retry
                    )
                }
            }
            if !Task.isCancelled {
                self.fileTranscribeTask = nil
                self.drainDeferredArrivals()
            }
        }
    }

    /// A probe that never came back means the file itself is out of reach, so the run reading the
    /// same bytes is not going to report anything of its own.
    private func failFileReadTimeout(_ fileURL: URL, fetchedLink: FetchedLink?) {
        guard fileTranscribeTask != nil else { return }
        cancelAndTrack(&fileTranscribeTask)
        applyTranscriptionError(
            ParolaError.fileReadTimedOut(name: fileURL.lastPathComponent),
            source: fetchedLink == nil ? fileURL : nil,
            link: fetchedLink?.retry
        )
    }

    func makeFilePartialHandler(runToken: Int) -> @Sendable (String) -> Void {
        let coalescer = makeFilePartialCoalescer(runToken: runToken)
        return { coalescer.send($0) }
    }

    func makeFilePartialCoalescer(runToken: Int) -> MainActorCoalescer<String> {
        MainActorCoalescer { [weak self] text in
            guard let self, self.fileRunGeneration == runToken, self.filePartialText != text else { return }
            self.filePartialText = text
        }
    }

    func makeFileStageHandler(fileURL: URL, runToken: Int) -> @Sendable (TranscribeStage) -> Void {
        return { [weak self] stage in
            Task { @MainActor in
                guard let self, self.fileRunGeneration == runToken else { return }
                self.fileTranscribeStage = stage
                // First stage event means the model finished loading/downloading; until then the
                // phase keeps showing that wait instead of jumping straight to "transcribing".
                switch self.phase {
                case .loadingModel, .downloadingModel:
                    self.phase = .transcribing(file: fileURL)
                default:
                    break
                }
            }
        }
    }

    var currentOptions: TranscriptionOptions {
        makeOptions(task: translate ? .translate : .transcribe, model: selectedModel, language: selectedLanguage)
    }

    func makeOptions(task: TranscriptionTask, model modelName: String, language: String?) -> TranscriptionOptions {
        // Translate and speaker labels would fail the run; the session drops a prompt or word timings itself.
        let caps = ModelCatalog.staticCapabilities(forID: modelName) ?? .whisperKitDefaults
        return TranscriptionOptions(
            model: modelName,
            language: language,
            task: (task == .translate && !caps.supportsTranslate) ? .transcribe : task,
            wordTimestamps: wordTimestamps,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt,
            diarize: diarize && caps.supportsDiarization,
            expectedSpeakers: expectedSpeakersRaw > 0 ? expectedSpeakersRaw : nil
        )
    }

    /// `ModelStore.download` calls this once per whole percent, never going backwards.
    func makeDownloadProgressHandler(for modelName: String) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only the download's own phase is the bar's to paint; a take or a run owns it outright.
                if case .downloadingModel = self.phase {
                    self.phase = .downloadingModel(name: modelName, progress: fraction)
                }
                if fraction >= 1 { self.refreshModelList() }
            }
        }
    }

    @MainActor private final class FileProgressThrottle {
        var lastPercent = -1
        var lastFraction: Double = 0
    }

    func makeFileProgressHandler(runToken: Int) -> @Sendable (Double) -> Void {
        let coalescer = makeFileProgressCoalescer(runToken: runToken)
        return { coalescer.send($0) }
    }

    func makeFileProgressCoalescer(runToken: Int) -> MainActorCoalescer<Double> {
        let throttle = FileProgressThrottle()
        return MainActorCoalescer { [weak self] seconds in
            guard let self, self.fileRunGeneration == runToken,
                  let duration = self.mediaDurationSeconds, duration > 0 else { return }
            let fraction = min(1, max(throttle.lastFraction, seconds / duration))
            let percent = Int(fraction * 100)
            guard percent != throttle.lastPercent else { return }
            throttle.lastPercent = percent
            throttle.lastFraction = fraction
            self.fileTranscribeFraction = fraction
        }
    }

    // MARK: - YouTube URL

    var youtubeSheetOpen: Bool = false
    var youtubeURLError: String?
    var ytDlpAvailable: Bool = false
    var ytDlpInstalling: Bool = false
    var ytDlpInstallError: String?
    @ObservationIgnored var ytDlpPath: String?
    var ytDlpVersion: YtDlpVersion?
    var ytDlpUpdateRoute: YtDlpInstaller.UpdateRoute?
    var ytDlpUpdating: Bool = false
    var ytDlpUpdateError: String?
    @ObservationIgnored var ytDlpVersionTask: Task<Void, Never>?
    @ObservationIgnored var ytDlpUpdateTask: Task<Void, Never>?
    @ObservationIgnored var ytDlpUpdateDeadline: Duration = YtDlpInstaller.upgradeDeadline
    @ObservationIgnored var ytDlpLocator: () -> String? = { YtDlpInstaller.locate() }
    @ObservationIgnored var linkFetcher: any LinkFetcher

    var ytDlpIsStale: Bool {
        ytDlpVersion?.isStale(asOf: Date()) ?? false
    }

    func refreshYtDlpAvailability() {
        let path = ytDlpLocator()
        ytDlpPath = path
        ytDlpAvailable = path != nil
        if ytDlpAvailable { ytDlpInstallError = nil }
        let route = path.map { YtDlpInstaller.updateRoute(ytDlpPath: $0) }
        if route != ytDlpUpdateRoute { ytDlpUpdateRoute = route }
        if path == nil, ytDlpVersion != nil { ytDlpVersion = nil }
    }

    /// Availability plus `yt-dlp --version`, which costs a Python start-up, so only the Integrations pane asks for it.
    func refreshYtDlpStatus() {
        refreshYtDlpAvailability()
        guard let path = ytDlpPath, !ytDlpUpdating else { return }
        ytDlpVersionTask?.cancel()
        ytDlpVersionTask = Task { [weak self] in
            let version = await YtDlpVersion.installed(at: path)
            guard !Task.isCancelled, let self, !self.ytDlpUpdating else { return }
            if version != self.ytDlpVersion { self.ytDlpVersion = version }
            if let version, !version.isStale(asOf: Date()), self.ytDlpUpdateError != nil { self.ytDlpUpdateError = nil }
        }
    }

    func updateYtDlpViaBrew() {
        guard !ytDlpUpdating, case .homebrew(let brew)? = ytDlpUpdateRoute else { return }
        ytDlpUpdating = true
        ytDlpUpdateError = nil
        ytDlpVersionTask?.cancel()
        let deadline = ytDlpUpdateDeadline
        ytDlpUpdateTask = Task { [weak self] in
            let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew, deadline: deadline)
            guard let self else { return }
            guard outcome != .cancelled else {
                self.ytDlpUpdateTask = nil
                self.ytDlpUpdating = false
                self.refreshYtDlpStatus()
                return
            }
            self.refreshYtDlpAvailability()
            var version: YtDlpVersion?
            if let path = self.ytDlpPath { version = await YtDlpVersion.installed(at: path) }
            self.ytDlpUpdateTask = nil
            self.ytDlpVersion = version
            self.ytDlpUpdating = false
            self.ytDlpUpdateError = self.ytDlpUpdateProblem(after: outcome, deadline: deadline)
        }
    }

    private func ytDlpUpdateProblem(after outcome: YtDlpInstaller.Outcome, deadline: Duration) -> String? {
        switch outcome {
        case .success where !ytDlpAvailable:
            return String(localized: "Homebrew finished, but yt-dlp still isn't on the expected path.")
        case .success where ytDlpVersion == nil:
            return String(localized: "Homebrew finished, but Parola couldn't read yt-dlp's version.")
        case .success where ytDlpIsStale:
            return String(localized: "Homebrew finished, but yt-dlp is still out of date.")
        case .success, .cancelled:
            return nil
        case .failure(let message):
            return message
        case .timedOut:
            return Self.ytDlpUpdateTimedOutMessage(deadline)
        }
    }

    func cancelYtDlpUpdate() {
        ytDlpUpdateTask?.cancel()
    }

    nonisolated static func ytDlpUpdateTimedOutMessage(_ deadline: Duration, bundle: Bundle = .main) -> String {
        let minutes = Int(deadline.components.seconds / 60)
        return String(localized: "Homebrew didn't finish within \(minutes) minutes, so Parola stopped the update.", bundle: bundle)
    }

    func installYtDlpViaBrew() {
        guard !ytDlpInstalling else { return }
        guard let brew = YtDlpInstaller.locateBrew() else {
            ytDlpInstallError = String(localized: "Homebrew isn't installed. Install it from https://brew.sh, then try again.")
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
                self.refreshYtDlpStatus()
                if !self.ytDlpAvailable {
                    self.ytDlpInstallError = String(localized: "Homebrew finished, but yt-dlp still isn't on the expected path.")
                }
            case .failure(let message):
                self.ytDlpInstallError = message
            case .timedOut, .cancelled:
                break
            }
        }
    }

    /// What became of a handed-over link: a run started, the link waits for the current work to end, or it was refused.
    enum LinkHandoff {
        case started
        case parked
        case rejected
    }

    /// A link parked by a take or a run in flight, kept with the action it was handed to.
    enum DeferredLink: Equatable {
        case transcribe(String)
        case subtitles(String)
    }

    /// A link run's download, handed to the file run that transcribes it.
    struct FetchedLink {
        /// What the user handed over: Retry and recovery replay it.
        let link: URL
        let media: FetchedMedia

        var retry: DeferredLink { .transcribe(link.absoluteString) }
    }

    /// What the fetch pane shows, folded from yt-dlp's events as they come.
    struct LinkFetchReadout: Equatable, Sendable {
        var title: String?
        var progress: Double?

        mutating func apply(_ event: LinkFetchEvent) {
            switch event {
            case .metadata(let metadata): title = metadata.title ?? title
            case .downloading(let fraction): progress = fraction
            case .processing: progress = nil
            }
        }
    }

    /// Only a real launch warms the model while a link downloads: a test's model must never load a real one.
    private var prewarmsDuringLinkFetch: Bool { activeSideEffects.contains(.refreshYtDlp) }

    /// A batch in flight owns the phase until its last job ends, so a link waits for it the way a file does.
    var linkArrivalsDeferred: Bool {
        phaseDefersArrivals || transcribeTaskRunning
            || (batchTask != nil && batchJobs.contains { $0.status == .pending || $0.status == .transcribing })
    }

    @discardableResult
    func transcribeYouTube(urlString: String) -> LinkHandoff {
        guard features.isEnabled(.youtube) else {
            phase = .failed(message: ParolaError.featureDisabled(.youtube).description)
            return .rejected
        }
        guard let url = makeYouTubeURL(urlString) else { return .rejected }
        // The download flips phase off .recording, and every stop affordance is keyed on it.
        if linkArrivalsDeferred {
            deferredLinks.append(.transcribe(url.absoluteString))
            return .parked
        }

        cancelTranscriptionRuns()
        let runToken = nextFileRunToken()
        let recoveryToken = beginFileTranscribeRecovery(sourceURL: url, source: .web)
        let fetcher = linkFetcher
        let progress = makeLinkFetchHandler(runToken: runToken)
        phase = .fetchingLink(title: nil, progress: nil)
        // A cold model load then overlaps the download instead of following it.
        if prewarmsDuringLinkFetch { prewarmSelectedModel() }
        youtubeTranscribeTask = Task { [weak self] in
            do {
                let media = try await fetcher.fetchAudio(url: url, progress: progress)
                // A download that finished just as it was cancelled still owns a folder.
                guard !Task.isCancelled, let self else {
                    media.discard()
                    throw CancellationError()
                }
                self.youtubeTranscribeTask = nil
                // A re-run started during the download is the newer start: the link gives way to it.
                guard self.fileTranscribeTask == nil else {
                    media.discard()
                    self.endRecovery(recoveryToken)
                    return
                }
                self.beginFileTranscription(
                    fileURL: media.fileURL, translateOverride: nil, fetchedLink: FetchedLink(link: url, media: media)
                )
            } catch {
                guard let self else { return }
                self.endRecovery(recoveryToken)
                self.retireFileRun(runToken)
                guard !Task.isCancelled else { return }
                self.applyTranscriptionError(error, link: .transcribe(url.absoluteString))
                self.youtubeTranscribeTask = nil
                self.drainDeferredArrivals()
            }
        }
        return .started
    }

    /// A re-run replaces a link's download the way a newer file run replaces an older one.
    func cancelLinkFetch() {
        guard youtubeTranscribeTask != nil else { return }
        cancelAndTrack(&youtubeTranscribeTask)
    }

    /// Playback follows the download into its entry before the folder goes; a failed save keeps the folder playing.
    private func followLinkAudioIntoLibrary(_ fetched: FetchedLink, entry adding: Task<LibraryEntry, any Error>) {
        Task { [weak self, library] in
            guard let entry = try? await adding.value else { return }
            let audio = try? await library.load(entry.id).document.audioURL
            if let self, let audio, self.sourceFileURL == fetched.media.fileURL {
                self.movePlayback(to: audio)
            }
            fetched.media.discard()
        }
    }

    /// Folds yt-dlp's events into what the pane shows, so the newest hop always carries the title too.
    func makeLinkFetchHandler(runToken: Int) -> @Sendable (LinkFetchEvent) -> Void {
        let readout = OSAllocatedUnfairLock(initialState: LinkFetchReadout())
        let coalescer = MainActorCoalescer<LinkFetchReadout> { [weak self] readout in
            guard let self, self.fileRunGeneration == runToken, case .fetchingLink = self.phase else { return }
            let next = Phase.fetchingLink(title: readout.title, progress: readout.progress)
            if self.phase != next { self.phase = next }
        }
        return { event in
            // Sent under the lock: the coalescer keeps the newest value, so it must get them in folding order.
            readout.withLock { state in
                state.apply(event)
                coalescer.send(state)
            }
        }
    }

    @discardableResult
    func fetchYouTubeSubs(urlString: String) -> LinkHandoff {
        guard features.isEnabled(.youtube) else {
            phase = .failed(message: ParolaError.featureDisabled(.youtube).description)
            return .rejected
        }
        guard let url = makeYouTubeURL(urlString) else { return .rejected }
        if linkArrivalsDeferred {
            deferredLinks.append(.subtitles(url.absoluteString))
            return .parked
        }

        cancelTranscriptionRuns()
        let fetcher = linkFetcher
        youtubeSubsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                phase = .transcribing(file: url)
                let result = try await fetcher.fetchCaptions(url: url, language: selectedLanguage)
                try Task.checkCancellation()
                let processed = await postProcessDetached(result.transcript)
                let landing = Self.landingSignposter.beginInterval("install")
                defer { Self.landingSignposter.endInterval("install", landing) }
                installFetchedSubtitles(processed)
                phase = .ready
                persistToLibrary(
                    processed,
                    audioSource: nil,
                    source: .web,
                    title: result.videoTitle ?? LibraryEntryDisplay.webVideoTitle(createdAt: Date()),
                    playsCompletionSound: false
                )
            } catch {
                if !Task.isCancelled { applyTranscriptionError(error, link: .subtitles(url.absoluteString)) }
            }
            if !Task.isCancelled {
                self.youtubeSubsTask = nil
                self.drainDeferredArrivals()
            }
        }
        return .started
    }

    private func makeYouTubeURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString), url.isYtDlpSupported else {
            // While the sheet is up, a phase failure would render behind the modal; show it inline.
            if youtubeSheetOpen {
                youtubeURLError = Self.unsupportedURLMessage()
            } else {
                phase = .failed(message: Self.unsupportedURLMessage())
            }
            return nil
        }
        youtubeURLError = nil
        youtubeSheetOpen = false
        return url
    }

    func applyTranscriptionError(
        _ error: Error, source: URL? = nil, translateOverride: Bool? = nil, link: DeferredLink? = nil
    ) {
        if error is CancellationError || Task.isCancelled {
            phase = .idle
        } else {
            phase = .failed(message: Self.transcriptionFailureMessage(for: error))
            // After the phase: its didSet forgets whatever the last failure left behind.
            failureKind = .transcription
            failedFileURL = source
            failedTranslateOverride = translateOverride
            failedLink = link
            if case ParolaError.linkDownloadFailed(let failure) = error {
                if !failure.isWorthRetrying { failedLink = nil }
                failedLinkDownload = failure
                noteYtDlp(from: failure)
            }
        }
    }

    /// The error card names the failure in its title, so the message drops its own lead-in.
    nonisolated static func errorDetail(from message: String, bundle: Bundle = .main) -> String {
        let prefix = String(localized: "Transcription failed: \("")", bundle: bundle)
        guard message.hasPrefix(prefix) else { return message }
        return String(message.dropFirst(prefix.count))
    }

    nonisolated static func transcriptionFailureMessage(for error: Error, bundle: Bundle = .main) -> String {
        if case ParolaError.transcriptionFailed(let reason) = error {
            return String(localized: "Transcription failed: \(reason)", bundle: bundle)
        }
        if case ParolaError.linkDownloadFailed(let failure) = error {
            return linkFailureMessage(failure, bundle: bundle)
        }
        if let offline = offlineMessage(for: error, bundle: bundle) { return offline }
        return error.localizedDescription
    }

    /// Model downloads are the only network dependency, so name them when the network is the problem.
    nonisolated static func offlineMessage(for error: Error, bundle: Bundle = .main) -> String? {
        let code = (error as NSError).code
        let domain = (error as NSError).domain
        guard domain == NSURLErrorDomain,
              [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
               NSURLErrorCannotConnectToHost, NSURLErrorTimedOut].contains(code) else { return nil }
        return String(
            localized: "Parola needs to download the speech model, and the network isn't reachable. Connect to the internet and try again — after that, transcription runs fully offline.",
            bundle: bundle
        )
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

    /// Live takes capture to a temp file whose UUID name would otherwise leak into the
    /// library title when auto-titling is unavailable.
    nonisolated static func liveRecordingTitle(category: EntryCategory, endedAt: Date) -> String {
        let stamp = AppFormat.dateAndTime(endedAt)
        return category == .meeting ? "Meeting \(stamp)" : "Recording \(stamp)"
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
            return LibraryEntryDisplay.title(for: entry)
        }
        if let sourceFileURL {
            return sourceFileURL.deletingPathExtension().lastPathComponent
        }
        return entry.map { LibraryEntryDisplay.title(for: $0) } ?? fallback
    }

    private nonisolated static func sourceBelongsToEntry(_ source: URL?, bundleURL: URL) -> Bool {
        guard let source else { return false }
        // Match the entry's unique <id>.parola bundle by name; a full-path compare breaks on the test sandbox's /tmp symlink.
        return source.deletingLastPathComponent().lastPathComponent == bundleURL.lastPathComponent
    }

    func dismissError() {
        if ytDlpUpdateOffer == .updating { cancelYtDlpUpdate() }
        // Back to the transcript when one is loaded: a failed export or prompt shouldn't cost the user their place.
        phase = transcript == nil ? .idle : .ready
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
        introduction.defer()
        let needed: ParolaFeature = source == .microphone ? .micRecording : .meetings
        guard features.isEnabled(needed) else {
            phase = .failed(message: ParolaError.featureDisabled(needed).description)
            return
        }
        guard !recordingActive else { return }
        let diskCheck = startDiskSpaceCheck()
        let countIn = max(0, recordingCountInSeconds)
        // The countdown overlay renders only in the main window; with no window visible
        // (global hotkey, menu bar) it would delay the take invisibly and uncancellably.
        let overlayVisible = mode == .test || NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if countIn > 0, overlayVisible {
            beginCountIn(seconds: countIn) { [weak self] in
                self?.beginRecordingNow(source: source, diskCheck: diskCheck)
            }
            refuseDuringCountIn(diskCheck)
        } else {
            beginRecordingNow(source: source, diskCheck: diskCheck)
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
    /// Non-WhisperKit engines can't stream either — those record the take first, then transcribe.
    func shouldUseStreamingMic() async -> Bool {
        guard useStreaming, ModelCatalog.canStream(id: selectedModel) else { return false }
        return await MockAudioSourceRegistry.shared.resolve(for: .mic) == nil
    }

    /// True from the moment a take is requested until its capture is torn down; the guard in
    /// `startRecording` uses it so a second trigger (menu bar, intent, meeting banner) can't
    /// silently discard the running take and leak its capture.
    var recordingActive: Bool {
        if recordingStartInFlight || liveSource != nil || streamingSession != nil { return true }
        if recordingCountdown != nil { return true }
        if case .recording = phase { return true }
        return false
    }

    private func beginRecordingNow(source: RecordSource, diskCheck: Task<Int64?, Never>) {
        pendingRecordingSource = source.entrySource
        let config = recordingMediaConfig(for: source)
        recordingStartInFlight = true
        stopRequestedDuringStart = false
        Task {
            defer {
                recordingStartInFlight = false
                stopRequestedDuringStart = false
            }
            // Before anything is cancelled: a take refused for space leaves what was running alone.
            guard await passesPreRecordingDiskCheck(diskCheck) else {
                resolveRecordingOutcome(.failure(IntentActionError.failed(Self.diskSpaceRefusalMessage())))
                return
            }
            // A recording replaces any transcription in flight, like a user file-open does;
            // otherwise the old run would finish later and stomp the new take's transcript.
            cancelTranscriptionRuns()
            let captureTargets = pendingCaptureBundleIDs ?? []
            pendingCaptureBundleIDs = nil
            if source == .microphone, mode == .normal, await AVCaptureDevice.requestAccess(for: .audio) == false {
                ParolaLog.notice(.appPermissions, "microphone access request was denied")
                let message = Self.microphoneAccessOffMessage()
                phase = .failed(message: message)
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)))
                return
            }
            if source == .microphone, await shouldUseStreamingMic() {
                // The streaming path never reaches adoptLiveSource, so it has to honour the stop itself.
                guard !stopRequestedDuringStart else {
                    recordingStartInFlight = false
                    phase = .idle
                    resolveRecordingOutcome(.failure(IntentActionError.cancelled))
                    drainDeferredArrivals()
                    return
                }
                startStreamingMic()
                return
            }
            await mediaSession.enterRecording(config: config)
            do {
                liveTakeIsStreaming = false
                phase = .recording(source: source)
                switch source {
                case .microphone:
                    let mic = await LiveAudioSourceFactory.makeMicrophone(
                        deviceUID: preferredInputDeviceUID,
                        clock: clock
                    )
                    try await mic.start()
                    guard await adoptLiveSource(mic) else { return }
                case .systemAudio:
                    let sys = await LiveAudioSourceFactory.makeSystem(targetBundleIDs: captureTargets, clock: clock)
                    // Tap setup blocks indefinitely while macOS waits for the System Audio
                    // Recording consent; abandon it after 20s so Stop never goes dead.
                    let started: Result<Void, any Error>? = await AsyncTimeout.run(.seconds(20)) {
                        do { try await sys.start(); return .success(()) } catch { return .failure(error) }
                    }
                    switch started {
                    case .success:
                        break
                    case .failure(let error):
                        throw error
                    case nil:
                        Task { await sys.cancel() }
                        throw ParolaError.captureUnavailable(
                            "system audio capture did not start. Allow System Audio Recording for Parola in System Settings → Privacy & Security, then try again."
                        )
                    }
                    guard await adoptLiveSource(sys) else { return }
                }
                scheduleRecordingAutoStop()
                startRecordingWatch(checkpoints: false)
            } catch {
                await mediaSession.exitRecording()
                stopRecordingWatch()
                let message = Self.recordingFailureMessage(for: error, source: source)
                // Startup can take 20s; anything that already moved the phase on owns it now.
                if case .recording = phase { phase = .failed(message: message) }
                recordingStartInFlight = false
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)))
                drainDeferredArrivals()
            }
        }
    }

    /// Drops a capture that came up after the user's Stop — a system-audio take waits up to 20s on consent.
    private func adoptLiveSource(_ source: any LiveAudioSource) async -> Bool {
        guard stopRequestedDuringStart else {
            liveSource = source
            recordingLevelMeter = source.levelMeter
            // One audio-only checkpoint per take: a crash mid-recording leaves a
            // pointer to the in-flight file instead of losing the take outright.
            liveRecordingAudioURL = await source.inFlightURL()
            if liveRecordingAudioURL != nil {
                beginRecordingRecovery()
                writeRecordingCheckpoint()
            }
            return true
        }
        clearRecordingLevelMeter()
        stopRecordingWatch()
        await source.cancel()
        await mediaSession.exitRecording()
        pendingRecordingCategory = .transcription
        if case .recording = phase { phase = .idle }
        // Clear before draining: a drained batch reads recordingActive to decide whether it owns the phase.
        recordingStartInFlight = false
        resolveRecordingOutcome(.failure(IntentActionError.cancelled))
        drainDeferredArrivals()
        return false
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

    private func clearRecordingLevelMeter() {
        if recordingLevelMeter != nil { recordingLevelMeter = nil }
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
        let s = StreamingTranscriberFactory.make(clock: clock, deviceUID: preferredInputDeviceUID, persistAudio: true)
        streamingSession = s
        recordingLevelMeter = s.levelMeter
        liveTakeIsStreaming = true
        liveSegments = []
        livePartialText = ""
        liveVoiceActive = false
        phase = .recording(source: .microphone)
        startSilenceWatch()
        scheduleRecordingAutoStop()
        beginRecordingRecovery()
        startRecordingWatch(checkpoints: true)

        let opts = currentOptions
        let progress = makeDownloadProgressHandler(for: selectedModel)
        let config = mediaSessionConfig(allowMute: true)

        streamingConsumer = Task { @MainActor in
            await mediaSession.enterRecording(config: config)
            let labeler = await streamingSpeakerLabeler()
            do {
                let events = try await s.start(options: opts, speakerLabeler: labeler, downloadProgress: progress)
                liveRecordingAudioURL = await s.recordingAudioURL()
                writeRecordingCheckpoint()
                phase = .recording(source: .microphone)
                for await event in events {
                    await handleStreamingEvent(event)
                    // Self-cancellation inside the .failed handler races the stream's buffer;
                    // a buffered late .finished must not resurrect the torn-down take.
                    if case .failed = event { break }
                }
            } catch {
                teardownStreaming()
                let message = Self.transcriptionFailureMessage(for: error)
                phase = .failed(message: message)
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)))
                drainDeferredArrivals()
            }
            await mediaSession.exitRecording()
        }
    }

    /// Session-local speaker labels for streaming mic recordings. When the diarizer models
    /// aren't downloaded yet, this recording stays unlabeled and the fetch runs in the
    /// background so the next one can label.
    private func streamingSpeakerLabeler() async -> (any StreamingSpeakerLabeler)? {
        guard diarize else { return nil }
        if IncrementalSpeakerLabeler.modelsInstalled() {
            return try? await IncrementalSpeakerLabeler.loadInstalled()
        }
        if mode == .normal {
            Task.detached { try? await IncrementalSpeakerLabeler.downloadModels() }
        }
        return nil
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
        clearRecordingLevelMeter()
        stopSilenceWatch()
        stopRecordingWatch()
        endActiveRecovery()
        liveRecordingAudioURL = nil
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
            let streaming = streamingSession
            let confirmed = liveSegments
            teardownStreaming()
            let audioURL = await streaming?.recordingAudioURL()
            var message = msg
            let takeCategory = pendingRecordingCategory
            let takeSource = pendingRecordingSource
            let takeTitle = Self.liveRecordingTitle(category: takeCategory, endedAt: Date())
            let savedPartial = !confirmed.isEmpty || audioURL != nil
            if savedPartial {
                let finished = await StreamingTranscriptionSession.finishedTake(
                    segments: confirmed, options: currentOptions, modelName: selectedModel, audioURL: audioURL
                )
                let partial = await postProcessDetached(finished)
                persistToLibrary(
                    partial,
                    audioSource: audioURL,
                    source: takeSource,
                    title: takeTitle + " (interrupted)",
                    activate: false
                )
                message += " " + String(localized: "The recording up to this point was saved to your library.")
            }
            liveSegments = []
            livePartialText = ""
            phase = .failed(message: message)
            // After the phase: its didSet forgets whatever the last failure left behind.
            if savedPartial, let audioURL {
                failureKind = .transcription
                failedTakeAudioURL = audioURL
                failedTakeTitle = takeTitle
                failedTakeCategory = takeCategory
                failedTakeSource = takeSource
            }
            resolveRecordingOutcome(.failure(IntentActionError.failed(message)))
            drainDeferredArrivals()
        case .finished(let transcript):
            stopRecordingWatch()
            endActiveRecovery()
            let processed = await postProcessDetached(transcript)
            self.livePartialText = ""
            self.liveSegments = []
            // A take stopped before capture came up (say, during the first model download) has nothing to keep.
            guard !processed.segments.isEmpty || processed.sourceURL != nil else {
                phase = .idle
                resolveRecordingOutcome(.success(processed.text))
                drainDeferredArrivals()
                return
            }
            let landing = Self.landingSignposter.beginInterval("install")
            defer { Self.landingSignposter.endInterval("install", landing) }
            clearDerivedArtifacts()
            self.selectedEntryID = nil
            self.transcript = processed
            self.phase = .ready
            if let audioURL = processed.sourceURL {
                sourceFileURL = audioURL
                installPlayer(for: audioURL)
                adoptLoadedMediaDuration()
            }
            persistToLibrary(
                processed,
                audioSource: processed.sourceURL,
                source: pendingRecordingSource,
                title: Self.liveRecordingTitle(category: pendingRecordingCategory, endedAt: Date())
            )
            resolveRecordingOutcome(.success(processed.text))
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
                clearRecordingLevelMeter()
                stopSilenceWatch()
                stopRecordingWatch()
                // Both no-op when .finished already ran; they cover a stream that ends without one.
                endActiveRecovery()
                liveRecordingAudioURL = nil
                resolveRecordingOutcome(.failure(IntentActionError.failed("The recording ended without a transcript.")))
            }
            return
        }

        guard let source = liveSource else {
            if recordingStartInFlight { stopRequestedDuringStart = true }
            return
        }
        // Hand off synchronously so a racing auto-stop or second click can't start a duplicate run.
        liveSource = nil
        stopRecordingWatch()
        fileTranscribeTask?.cancel()
        fileTranscribeTask = Task {
            await mediaSession.exitRecording()
            do {
                let url = try await source.prepare()
                clearRecordingLevelMeter()
                await transcribeRecordedTake(
                    url: url,
                    title: Self.liveRecordingTitle(category: pendingRecordingCategory, endedAt: Date()),
                    source: pendingRecordingSource
                )
            } catch {
                clearRecordingLevelMeter()
                endActiveRecovery()
                liveRecordingAudioURL = nil
                let message = Self.transcriptionFailureMessage(for: error)
                phase = .failed(message: message)
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)))
            }
            if !Task.isCancelled {
                self.fileTranscribeTask = nil
                self.drainDeferredArrivals()
            }
        }
    }

    /// Transcribes a finished take from its in-flight file. Unlike a user-opened file the
    /// audio is irreplaceable, so a failure saves it to the library and arms the error
    /// pane's Retry instead of leaving the file orphaned.
    func transcribeRecordedTake(url: URL, title: String, source: EntrySource) async {
        liveRecordingAudioURL = nil
        let recoveryToken = beginFileTranscribeRecovery(sourceURL: url, title: title, source: source)
        sourceFileURL = url
        installPlayer(for: url)
        phase = .transcribing(file: url)
        do {
            let result = try await session.transcribe(
                source: FileAudioSource(url: url),
                options: currentOptions
            )
            let processed = await postProcessDetached(result)
            let landing = Self.landingSignposter.beginInterval("install")
            defer { Self.landingSignposter.endInterval("install", landing) }
            clearDerivedArtifacts()
            selectedEntryID = nil
            restorePlaybackSource(url)
            transcript = processed
            adoptLoadedMediaDuration()
            endRecovery(recoveryToken)
            phase = .ready
            persistToLibrary(processed, audioSource: url, source: source, title: title)
            resolveRecordingOutcome(.success(processed.text))
        } catch {
            endRecovery(recoveryToken)
            var message = Self.transcriptionFailureMessage(for: error)
            let recoverable = !(error is CancellationError) && !Task.isCancelled
            if recoverable {
                let category = pendingRecordingCategory
                persistToLibrary(
                    Transcript(
                        segments: [],
                        language: currentOptions.language ?? "auto",
                        modelName: selectedModel,
                        sourceURL: url
                    ),
                    audioSource: url,
                    source: source,
                    title: title + " (transcription failed)",
                    activate: false
                )
                message += " " + String(localized: "The audio was saved to your library.")
                phase = .failed(message: message)
                // After the phase: its didSet forgets whatever the last failure left behind.
                failureKind = .transcription
                failedTakeAudioURL = url
                failedTakeTitle = title
                failedTakeCategory = category
                failedTakeSource = source
            } else {
                phase = .failed(message: message)
            }
            resolveRecordingOutcome(.failure(IntentActionError.failed(message)))
        }
    }

    /// A phase change means the last failure's file is no longer what the error card is about.
    private func forgetFailedSource() {
        if failureKind != .other { failureKind = .other }
        if failedFileURL != nil { failedFileURL = nil }
        if failedTranslateOverride != nil { failedTranslateOverride = nil }
        if failedLink != nil { failedLink = nil }
        if failedLinkDownload != nil { failedLinkDownload = nil }
        if failedTakeAudioURL != nil { failedTakeAudioURL = nil }
        failedTakeTitle = nil
        failedTakeCategory = nil
        failedTakeSource = nil
    }

    var canRetryFailedTranscription: Bool {
        failureKind == .transcription && (failedTakeAudioURL != nil || failedFileURL != nil || failedLink != nil)
    }

    /// What the error card names: a recorded take by its title, an opened file by its file name.
    var failedSourceName: String? {
        guard failureKind == .transcription else { return nil }
        if failedTakeAudioURL != nil { return failedTakeTitle }
        return failedFileURL?.lastPathComponent
    }

    func retryFailedTranscription() {
        if failedTakeAudioURL != nil {
            retryFailedTake()
            return
        }
        if let link = failedLink {
            switch link {
            case .transcribe(let urlString): transcribeYouTube(urlString: urlString)
            case .subtitles(let urlString): fetchYouTubeSubs(urlString: urlString)
            }
            return
        }
        guard let url = failedFileURL else { return }
        beginFileTranscription(fileURL: url, translateOverride: failedTranslateOverride)
    }

    func revealFailedFile() {
        guard let url = failedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Re-runs transcription of the take a failure left behind.
    func retryFailedTake() {
        guard let url = failedTakeAudioURL else { return }
        let title = failedTakeTitle ?? Self.liveRecordingTitle(category: .transcription, endedAt: Date())
        let source = failedTakeSource ?? .microphone
        pendingRecordingCategory = failedTakeCategory ?? .transcription
        fileTranscribeTask?.cancel()
        fileTranscribeTask = Task {
            await transcribeRecordedTake(url: url, title: title, source: source)
            if !Task.isCancelled {
                self.fileTranscribeTask = nil
                self.drainDeferredArrivals()
            }
        }
    }

    /// Schedules a debounced (~1 s) persist of the current transcript. Rapid edits coalesce: only the
    /// latest snapshot (identified by the generation counter) is written; earlier tasks cancel themselves.
    func persistCurrentTranscriptIfLoaded(textChanged: Bool = true) {
        guard let id = selectedEntryID, let transcript else {
            keepUnsavedBatchEdit()
            return
        }
        if textChanged { pendingSaveTextChanged = true }
        pendingTranscriptSaveGeneration &+= 1
        let generation = pendingTranscriptSaveGeneration
        pendingTranscriptSaveTask?.cancel()
        let clock = clock
        pendingTranscriptSaveTask = Task { [weak self, library] in
            try? await Task.sleep(for: .seconds(1), clock: clock)
            guard !Task.isCancelled else { return }
            guard self?.pendingTranscriptSaveGeneration == generation else { return }
            // Read at fire time: a duration correction may have patched the transcript since the edit was scheduled.
            let pending: (transcript: Transcript, reindex: Bool) = await MainActor.run { [weak self] in
                let flag = self?.pendingSaveTextChanged ?? false
                self?.pendingSaveTextChanged = false
                let latest = self?.selectedEntryID == id ? self?.transcript : nil
                return (latest ?? transcript, flag)
            }
            try? await library.updateTranscript(pending.transcript, for: id, reindex: pending.reindex)
            await MainActor.run { [weak self] in
                if self?.pendingTranscriptSaveGeneration == generation {
                    self?.pendingTranscriptSaveTask = nil
                }
            }
        }
    }

    /// Flushes a pending debounced transcript write immediately. Call at entry-switch or batch-select.
    /// With nothing edited it writes nothing: `updatedAt` and the search index must not move on browsing.
    func flushPendingTranscriptSave() async {
        let hadEdit = pendingTranscriptSaveTask != nil
        pendingTranscriptSaveTask?.cancel()
        pendingTranscriptSaveTask = nil
        let reindex = pendingSaveTextChanged
        pendingSaveTextChanged = false
        guard hadEdit, let id = selectedEntryID, let transcript else { return }
        try? await library.updateTranscript(transcript, for: id, reindex: reindex)
    }

    /// Synchronously cancels a pending debounced save and returns the snapshot to write.
    /// Used by AppDelegate.applicationWillTerminate, which cannot await async functions.
    func cancelAndDrainPendingTranscriptSave() -> (id: LibraryEntry.ID, transcript: Transcript)? {
        let hadEdit = pendingTranscriptSaveTask != nil
        pendingTranscriptSaveTask?.cancel()
        pendingTranscriptSaveTask = nil
        pendingSaveTextChanged = false
        guard hadEdit, let id = selectedEntryID, let transcript else { return nil }
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
            closeFind()
        }
    }

    /// The query belongs to the transcript it was typed against, so a new entry starts with Find shut.
    func closeFind() {
        findIsOpen = false
        findQuery = ""
        matches = []
        currentMatchIndex = 0
    }

    /// Opens Find on `word`. Order matters: a query set while Find is closed is discarded by the recompute.
    func findWord(_ word: String) {
        if !findIsOpen { toggleFind() }
        findQuery = word
    }

    // MARK: - Project document

    /// Continuation + GCD, not Task.detached: a detached job resuming a main-actor task
    /// around NSURL-bridging Foundation calls has crashed with EXC_ARM_DA_ALIGN before
    /// (same class as the watched-folder bookmark and duration-probe fixes).
    nonisolated static func offMainIO<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    func openProjectDocument(at url: URL) async {
        do {
            let doc = try await Self.offMainIO { try ParolaDocument.read(at: url) }
            // Like every other transcript-install path: drop the library selection first, or
            // the debounced save pairs the stale entry id with this document's transcript.
            loadEntryGeneration &+= 1
            let pending = cancelAndDrainPendingTranscriptSave()
            if let pending {
                Task { [library] in
                    try? await library.updateTranscript(pending.transcript, for: pending.id)
                }
            }
            selectedEntryID = nil
            sourceFileURL = doc.audioURL
            installStoredTranscript(doc.transcript)
            if let audio = doc.audioURL {
                installPlayer(for: audio)
                adoptLoadedMediaDuration()
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
        // A copy of a link's entry is still a link; with nothing loaded the writer derives it as before.
        let entrySource = libraryEntries.first { $0.id == selectedEntryID }?.manifest.source
        Task { [weak self] in
            guard let self else { return }
            guard let dest = await self.filePicker.chooseSaveDestination(suggestedName: suggested, allowedTypes: []) else { return }
            do {
                try await AppModel.offMainIO {
                    _ = try ParolaDocument.write(
                        transcript: transcript, audioURL: sourceFileURL, to: dest, entrySource: entrySource
                    )
                }
            } catch {
                ParolaLog.error(.export, "document save failed", [.error: .error(error)])
                self.phase = .failed(message: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Summary

    var isSummarising: Bool = false
    var summaryError: String?
    @ObservationIgnored var summaryGeneration: Int = 0
    /// Test seam: when set, replaces the on-device SummaryService so summarise timing is deterministic.
    @ObservationIgnored var summariseOperation: (@Sendable (Transcript, SummaryOptions) async throws -> Summary)?

    var summaryOptions: SummaryOptions = .default {
        didSet { writeJSON(summaryOptions, forKey: "summaryOptions") }
    }

    var autostartSummary: Bool = false {
        didSet { defaults.set(autostartSummary, forKey: "autostartSummary") }
    }

    // MARK: - Transcript pane mode

    var transcriptPaneMode: TranscriptPaneMode = .transcript

    // MARK: - Burn subtitles into video

    var burnSheetOpen: Bool = false
    /// The burn running beside everything else, or how the last one ended until it is dismissed.
    var burnJob: BurnJob?
    @ObservationIgnored private var burnTask: Task<Void, Never>?
    /// Test seam: replaces SubtitleBurner.burn so burn timing and progress are deterministic.
    @ObservationIgnored var burnOperation: (@Sendable (Transcript, URL, URL, SubtitleBurner.Style, @escaping @Sendable (Double) -> Void) async throws -> Void)?

    var burnFontSize: BurnFontSize { BurnFontSize(rawValue: burnFontSizeRaw) ?? .medium }
    var burnTextColor: BurnTextColor { BurnTextColor(rawValue: burnTextColorRaw) ?? .white }
    var burnIsRunning: Bool { burnJob?.isRunning == true }

    func requestBurnSubtitles() {
        guard transcript != nil, burnTask == nil else { return }
        burnSheetOpen = true
    }

    /// Burns the open transcript as it is now: opening another entry or starting a run leaves it going.
    func burnSubtitlesIntoVideo() {
        guard let transcript, burnTask == nil else { return }
        let style = SubtitleBurner.Style.make(fontSize: burnFontSize, textColor: burnTextColor, outline: burnOutline)
        let options = exportSpec(for: .srt).options
        let burn = burnOperation ?? { transcript, video, output, style, progress in
            try await SubtitleBurner.burn(
                transcript: transcript, video: video, to: output, style: style, options: options, progress: progress
            )
        }
        burnTask = Task { [weak self] in
            guard let self else { return }
            let inputURLs = await self.filePicker.chooseInputFiles(
                allowedTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                allowsMultiple: false,
                message: "Pick the video to burn subtitles into."
            )
            guard let videoURL = inputURLs.first else { self.burnTask = nil; return }
            let suggested = videoURL.deletingPathExtension().lastPathComponent + " (captioned).mp4"
            guard let outputURL = await self.filePicker.chooseSaveDestination(
                suggestedName: suggested,
                allowedTypes: [.mpeg4Movie]
            ) else { self.burnTask = nil; return }

            let job = BurnJob(id: UUID(), output: outputURL, state: .running(progress: 0))
            self.burnJob = job
            let startedAt = ContinuousClock.now
            do {
                try await burn(transcript, videoURL, outputURL, style) { [weak self] fraction in
                    Task { @MainActor in self?.updateBurn(job.id, to: .running(progress: fraction)) }
                }
                self.updateBurn(job.id, to: .finished)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputURL)
                if self.burnJob?.id == job.id { self.burnJob = nil }
            } catch {
                ParolaLog.error(
                    .export, "burn failed",
                    [.elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error)]
                )
                self.updateBurn(job.id, to: .failed(message: Self.burnFailureMessage(for: error)))
            }
            if !Task.isCancelled { self.burnTask = nil }
        }
    }

    /// A progress report that arrives after its burn ended must not bring it back.
    private func updateBurn(_ id: BurnJob.ID, to state: BurnJob.State) {
        guard burnJob?.id == id else { return }
        if case .running = state, burnJob?.isRunning != true { return }
        burnJob?.state = state
    }

    func cancelBurn() {
        cancelAndTrack(&burnTask)
    }

    func dismissBurnJob() {
        guard !burnIsRunning else { return }
        burnJob = nil
    }

    nonisolated static func burnFailureMessage(for error: Error, bundle: Bundle = .main) -> String {
        String(localized: "Burn failed: \(error.localizedDescription)", bundle: bundle)
    }
}

extension AppModel.Phase: LogSafe {
    /// The case name only: `failed`'s message and `transcribing`'s file are not loggable.
    var logToken: String {
        switch self {
        case .idle: return "idle"
        case .downloadingModel: return "downloadingModel"
        case .loadingModel: return "loadingModel"
        case .fetchingLink: return "fetchingLink"
        case .transcribing: return "transcribing"
        case .recording: return "recording"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}
