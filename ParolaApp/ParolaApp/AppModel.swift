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
        /// System-audio takes are what the meetings feature gates.
        var feature: ParolaFeature {
            switch self {
            case .microphone: return .micRecording
            case .systemAudio: return .meetings
            }
        }
        /// What the meter under a take is listening to.
        var meterLabel: String {
            switch self {
            case .microphone: return String(localized: "Microphone")
            case .systemAudio: return String(localized: "System audio")
            }
        }
    }

    /// A take between Record and its first captured audio, when the pane shows a wait instead of a clock.
    enum TakeArming: Equatable {
        /// The input is starting; system audio can wait here on macOS's consent.
        case startingCapture
        /// A live take's model loads first, and downloads first when `download` has a fraction.
        case preparingModel(name: String, download: Double?)
    }

    /// What a take carries from Record to its entry, so the next take can't overwrite it.
    struct TakeContext: Equatable {
        let id: Int
        let source: RecordSource
        /// Changes only while the take is the active one, through `setTakeCategory`.
        var category: EntryCategory
        let captureTargets: Set<String>
        var sourceAppBundleID: String?
        /// The take's own checkpoint once it has one, so its end never touches whichever run is active by then.
        var recovery: Int?
        var recoveryStartedAt: Date?
        /// Set once the take asks its capture to start; a Stop before then waits for the start to drop it.
        var captureRequested = false
        /// Its Record asked for a meeting, so a switch to Note before its capture comes up keeps your microphone's track, as one after does.
        var askedForMeeting = false
    }

    /// What a take's session holds for its entry: the name it showed, a title the user typed, and the moments they marked.
    struct TakeAnnotations: Equatable {
        var generatedTitle: String?
        var typedTitle: String?
        var markers: [TimeInterval] = []
        var sourceAppBundleID: String?

        /// The name the take showed, or one stamped now for a take that never had a session to show it.
        func title(for category: EntryCategory) -> String {
            generatedTitle ?? AppModel.liveRecordingTitle(category: category, endedAt: Date())
        }
    }

    /// How long a take stays quiet before the pane warns: a mic soon, Mac audio only past a pause, unless it has heard nothing yet.
    struct SilenceRule {
        var microphone: TimeInterval = 8
        var macAudioBeforeSound: TimeInterval = 10
        var macAudioAfterSound: TimeInterval = 60
    }

    /// A take's title with the file it was recorded to, so no pane names the working file; the take it was, so no later take is mistaken for it.
    struct RecordedTake: Equatable {
        let file: URL
        let title: String
        let takeID: Int?
    }

    /// A take's transcription run, the take it belongs to and the file it reads.
    struct TakeTranscription: Equatable {
        let run: Int
        let takeID: Int
        let file: URL
    }

    /// The answers the quit prompt offers while a take is capturing.
    enum QuitDuringTake {
        case stopAndSave
        case keepRecording
        case discard
    }

    enum Route: String, Hashable, CaseIterable {
        case transcript
        case batch
        case queue
        case statistics
        case recentlyDeleted
        /// The take's Stage, from Record until the take is in the library or gone; a failed one stays until dismissed.
        case recording
    }

    var route: Route = .transcript {
        didSet {
            if oldValue == .recentlyDeleted { recentlyDeletedSelection = [] }
            if routeLandsTake { routeLandsTake = false }
            if route != oldValue {
                holdSavedToastBehindStage()
                dropTakeSavedOnceLeft()
            }
        }
    }
    /// Set as a take's own landing replaces its Stage with its transcript, so the window plays that change as a landing; the next route change clears it.
    private(set) var routeLandsTake = false
    var settingsPane: String = "general"
    var settingsRoutePreview = false  // test-mode only: renders SettingsView in the main window so the bridge can screenshot panes
    // Published by TranscriptPane so the Show/Hide Inspector command knows which of the two visibility keys to flip.
    var transcriptPaneIsNarrow = false
    var dropDragPayload: DroppedFiles.Kind?
    var dropHighlight: DropHalf?
    var dragOverComposer = false
    /// The chat composer has the keyboard, so ⌘⏎ sends there instead of stopping a take; the composer sets it, so the menu needs no focused value.
    var chatComposerHasFocus = false
    var phase: Phase = .idle {
        didSet { forgetFailedSource() }
    }
    var transcript: Transcript? {
        didSet {
            transcriptMatchesLoadedMedia = false
            if transcript == nil, promptOutput != nil { promptOutput = nil }
            if transcript == nil, !inspectorOutline.isEmpty { inspectorOutline = [] }
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
    var duplicateImport: DuplicateImport? {
        didSet { if oldValue != nil, duplicateImport == nil { foregroundLetGo() } }
    }
    /// The re-transcription in flight. Nil the rest of the time; the inspector menus watch it.
    var retranscribeRequest: RetranscribeRequest?
    /// The re-run waiting on the "Transcribe again?" alert.
    var pendingRetranscribe: RetranscribeAsk?
    /// How many files the last batch import dropped because the library already had them.
    var batchDuplicatesSkipped: Int = 0
    /// Dropped files still being hashed against the library before they join the batch.
    var batchFilesBeingChecked: Int = 0
    @ObservationIgnored var duplicateCheckTask: Task<Void, Never>? {
        didSet { if oldValue != nil, duplicateCheckTask == nil { foregroundLetGo() } }
    }
    /// What each file or link run goes back in line as when a take cuts it off.
    @ObservationIgnored private var requeues: [Task<Void, Never>: RunRetry] = [:]
    @ObservationIgnored var batchImportTask: Task<Void, Never>?
    /// A run the user stopped does not ring when its queue unwinds. Cleared when a wave starts.
    @ObservationIgnored var batchRunCancelled = false
    var currentSegmentID: TranscriptSegment.ID? {
        didSet {
            if hasCurrentSegment != (currentSegmentID != nil) { hasCurrentSegment = currentSegmentID != nil }
            if let pending = pendingSegmentEditID, pending != currentSegmentID { pendingSegmentEditID = nil }
        }
    }
    /// Transcript ▸ Edit Segment names its segment here; the card opens its field when it shows, then clears it.
    var pendingSegmentEditID: TranscriptSegment.ID?
    /// What the menus read, so a playing transcript's segment ticks don't redraw them.
    private(set) var hasCurrentSegment = false
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
    /// The take the surfaces show, from its count-in until the next take; it outlives the capture while the take finishes.
    private(set) var recording: RecordingSession? {
        didSet {
            let countdown = Self.countIn(of: recording)
            if countdown != recordingCountdown { recordingCountdown = countdown }
            refreshStageHoldsTake()
            if oldValue?.isRunning == true, !takeIsRunning {
                foregroundLetGo()
                // First: clearing the strip below brings back what waits under it.
                if coveredNotice?.whileTakeRuns == true { coveredNotice = nil }
                if exportNotice?.whileTakeRuns == true { exportNotice = nil }
            }
            if route == .recording, !Self.stageHasSomethingToShow(recording) { route = .transcript }
            if let coveredTake = coveredNotice?.takeID, coveredTake == oldValue?.takeID, coveredTake != recording?.takeID { coveredNotice = nil }
            // A notice goes with its take's session; one about a take already let go stays while the next take records.
            if let noticeTake = exportNotice?.takeID, noticeTake == oldValue?.takeID, noticeTake != recording?.takeID { exportNotice = nil }
        }
    }
    /// The main window's sidebar, which a take folds away and gives back as it was.
    @ObservationIgnored let mainSidebar: MainSidebar
    /// The take's levels at ten a second, for as long as its session lasts; `takeLevelTick` moves with each one.
    @ObservationIgnored private(set) var takeLevels: TakeLevelHistory?
    /// A meeting's microphone levels, sampled with `takeLevels` and as many: the "You" meter beside "System audio".
    @ObservationIgnored var takeMicLevels: TakeLevelHistory?
    /// Where a meeting's microphone track stands; nil for a take that records none.
    var takeMicTrackState: MicTrackState?
    /// The take's Mac audio capture ended by itself; while the take still captures, your microphone records on. Lasts as long as the session.
    var takeMacAudioStopped = false
    /// Why the take stopped without a Stop, because what it recorded ended by itself: its notice's sentence. Lasts as long as the session.
    var takeStopReason: String?
    var takeStoppedOnItsOwn: Bool { takeStopReason != nil }
    private(set) var takeLevelTick = 0
    /// The running take's clock in whole seconds, pauses left out, turned over by the sampler's tick; the Dock badge, the menu bar item, the pill, the Stage clock and the sidebar row read their seconds off it.
    private(set) var takeClockSeconds = 0
    /// When the newest of the take's levels came in; the Stage's band slides from here until the next one.
    @ObservationIgnored private(set) var takeLevelTickAt = Date.distantPast
    @ObservationIgnored private var takeSampler: Task<Void, Never>?
    /// The take whose meter, trace and sampler are up, so a late clear from an older take leaves them alone.
    @ObservationIgnored private var takeReadoutsOwner: Int?
    /// When the take's capture came up: its silence watch runs from here, and its clock falls back to it.
    @ObservationIgnored private var captureStart: CaptureStart?
    /// Test seam: when set, stands in for the capture a take records to a file, so a test decides when it comes up and what it meters.
    @ObservationIgnored var takeCaptureOverride: (@MainActor (RecordSource) -> any LiveAudioSource)?
    /// Test seam: whether Screen Recording is granted when a system-audio capture fails.
    @ObservationIgnored var screenRecordingCheck: () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// A meeting take's microphone track, from the moment it is asked for until Stop; nil for every other take.
    @ObservationIgnored var micTrack: MicTrack?
    /// Test seam: when set, stands in for a meeting's microphone track; nil from it means this process has no microphone.
    @ObservationIgnored var micTrackCaptureOverride: (@MainActor () -> (any LiveAudioSource)?)?
    /// Test seam: the name CoreAudio gives the input a take records from, by its device UID; a device that's gone leaves the mic on the default input.
    @ObservationIgnored var takeInputNameLookup: @Sendable (String?) -> String? = { uid in
        let devices = AudioDevices.inputDevices()
        return AudioDevices.name(forUID: uid, in: devices) ?? AudioDevices.name(forUID: nil, in: devices)
    }
    /// Test seam: the input devices CoreAudio reports to the menu bar's and Settings' microphone pickers.
    @ObservationIgnored var inputDevicesLookup: @Sendable () -> [AudioInputDevice] = { AudioDevices.inputDevices() }
    /// Test seam: when set, answers the microphone permission prompt in its place, for any capture.
    @ObservationIgnored var micAccessRequest: (@MainActor () async -> Bool)?
    /// Test seam: when set, stands in for the microphone permission as it stood before a meeting's take asked.
    @ObservationIgnored var micAccessStatus: (@MainActor () -> AVAuthorizationStatus)?
    /// The take that has already said its microphone isn't in the recording.
    @ObservationIgnored var micTrackNoticeTake: Int?
    /// Sampler ticks in which the Mac audio moved on and the microphone didn't, before its track counts as stopped.
    @ObservationIgnored var micTrackStallTicks = 30
    /// How long Stop, a quit or a Discard waits on the mic before going on with what it wrote.
    @ObservationIgnored var micTrackFinishLimit: Duration = .seconds(5)
    @ObservationIgnored private var micTrackPauseWrites: Task<Void, Never>?
    /// A meeting's mix files while a fold or a run still reads them.
    @ObservationIgnored var meetingScratchInUse: Set<URL> = []
    /// Mic tracks a fold couldn't add, by their take's file, until the take's entry can hold a record of them.
    @ObservationIgnored var pendingMicTracks: [URL: StoppedMicTrack] = [:]
    /// Mic tracks waiting in a record of their own to be folded into their entry, by entry.
    @ObservationIgnored var micTrackRecords: [LibraryEntry.ID: MicTrackRecord] = [:]
    /// The launch's folds of mic tracks that waited for their entries.
    @ObservationIgnored var micTrackFolds: Task<Void, Never>?
    /// Test seam: runs after each step of a fold; false stops the fold there, as a crash would.
    @ObservationIgnored var foldStepHook: (@MainActor (FoldStep) async -> Bool)?

    private struct CaptureStart {
        let takeID: Int
        let at: ContinuousClock.Instant
    }

    /// How long a take whose capture is up waits for a metered buffer before its clock starts from the capture anyway.
    nonisolated static let firstBufferWait: Duration = .seconds(2)
    nonisolated static let takeSampleInterval: Duration = .milliseconds(100)
    /// How late a tick may land, so the kernel can wake for it with other timers.
    nonisolated static let takeSampleTolerance: Duration = .milliseconds(10)
    /// How far past each step of the take's clock a tick aims, so one that lands on time never reads the second before.
    nonisolated static let takeClockLag: Duration = .milliseconds(2)
    nonisolated static let silenceCheckTicks = 8
    /// The route the running take took; the recording pane reads it.
    var liveTakeIsStreaming: Bool { recording?.isStreaming ?? false }
    /// When the take in progress began capturing; the pane, the toolbar and the Dock all count from it.
    var recordingStartedAt: Date? {
        guard let recording, recording.isRunning else { return nil }
        return recording.startedAt
    }
    /// What the take waits on before its first audio; nil once it captures.
    var takeArming: TakeArming? {
        guard case .arming(let arming) = recording?.state else { return nil }
        switch arming {
        case .countIn: return nil
        case .startingCapture: return .startingCapture
        case .preparingModel(let name, let download): return .preparingModel(name: name, download: download)
        }
    }
    /// The take transcribing or just transcribed. Matched by file, so a stale one names nothing.
    private(set) var recordedTake: RecordedTake?
    /// The take's title field has the keyboard, so Esc edits the title instead of cancelling a take that is still starting.
    var takeTitleHasFocus = false
    /// A take that landed on its own Stage, for the toast that says where it went; it goes on its own once seen, unless the pointer holds it.
    var takeSavedNotice: TakeSavedNotice? {
        didSet {
            // A pointer that left as the toast's window hid sends no exit, so the hold goes with the toast.
            if takeSavedNotice == nil { takeSavedHeld = false }
            if takeSavedNotice != oldValue {
                takeSavedSeen = false
                takeSavedWasSeen = false
                restartTakeSavedExpiry()
            }
        }
    }
    /// Test seam: how long the saved-take toast stays once nothing holds it.
    @ObservationIgnored var takeSavedLifetime: Duration = TakeSavedNotice.lifetime
    /// VoiceOver running keeps the saved-take toast up until it is dismissed, and has the Stage's band say each new level. The app delegate follows the system's setting; a model it doesn't bind, as a test's, starts with it off.
    var voiceOverIsRunning = false {
        didSet { if voiceOverIsRunning != oldValue { restartTakeSavedExpiry() } }
    }
    @ObservationIgnored private var takeSavedExpiry: Task<Void, Never>?
    @ObservationIgnored private var takeSavedHeld = false
    @ObservationIgnored private var takeSavedSeen = false
    /// Seen at least once: a Stage covering the toast clears `takeSavedSeen` to stop its time, never this.
    @ObservationIgnored private var takeSavedWasSeen = false
    /// True while a quit waits for takes to reach the library; the window says so.
    private(set) var savingTakesBeforeQuit = false
    /// A quit already winding the takes down; the app delegate answers any other quit with a no.
    @ObservationIgnored var quitPending = false {
        didSet { if quitPending { cancelRecordingCountdown() } }
    }
    /// How long a quit waits, on the model's clock, for its takes to reach the library.
    @ObservationIgnored var quitSaveLimit: Duration = .seconds(30)
    @ObservationIgnored private var takeCounter = 0
    /// The take that owns the capture, the clock and the checkpoint; work an older take left running checks it first.
    @ObservationIgnored private(set) var activeTake: TakeContext?
    @ObservationIgnored private var takeRunCounter = 0
    /// The take transcription in flight, so Stop Transcribing and a new take act on that run alone.
    @ObservationIgnored private(set) var takeRun: Int?
    /// The take transcription that new work (a take, a file, a link) stopped, so its save can say why.
    @ObservationIgnored var takeRunStoppedByNewWork: Int?
    /// The take transcription Stop Transcribing ended, so its save can note it too.
    @ObservationIgnored var takeRunStoppedByStopTranscribing: Int?
    @ObservationIgnored private var takeWorkCounter = 0
    @ObservationIgnored private var renameCheckpoint: Task<Void, Never>?
    /// A take's prepare and transcription, which a quit stops so the take is saved rather than lost with the process.
    @ObservationIgnored private var takeTask: Task<Void, Never>?
    /// A live take a cancel let go while its last decode ran, as it stood then: its final transcript lands with these.
    private struct FinishingAlone {
        let take: TakeContext
        let annotations: TakeAnnotations
    }
    @ObservationIgnored private var liveTakesFinishingAlone: [Int: FinishingAlone] = [:]
    /// A live take finishing and every take's save, until its entry exists: what a quit waits for.
    @ObservationIgnored private var takeWork: [Int: Task<Void, Never>] = [:]
    var livePartialText: String = ""
    var liveVoiceActive: Bool = false
    var filePartialText: String = ""
    /// The take run the Stage shows while it transcribes; nil once the run ends or is stopped, so its late callbacks land nowhere.
    private(set) var takeTranscription: TakeTranscription? {
        didSet { refreshStageHoldsTake() }
    }
    private(set) var takePartialText: String = ""
    private(set) var takeTranscribeStage: TranscribeStage?
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
            if librarySortOrder == .titleAZ || librarySortOrder == .titleZA { reapplyLibrarySort() }
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
    /// Folders whose files are cleared later, so nothing is written beside them. A test seam.
    @ObservationIgnored var sweptFolders: @MainActor () -> [URL] = {
        [FileManager.default.temporaryDirectory, RecordingScratch.directory]
    }
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
    /// Set by the app delegate at launch; nil in tests, which must not put a Settings window up.
    @ObservationIgnored var settingsWindowOpener: (@MainActor () -> Void)?
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
    /// Whether Parola is the app in front, which a count-in needs; a test model counts as such unless its test says otherwise.
    @ObservationIgnored var appIsActive: @MainActor () -> Bool = { NSApp.isActive }
    var recordingCountInSeconds: Int = 0 { didSet { defaults.set(recordingCountInSeconds, forKey: "recordingCountInSeconds") } }
    var autoMuteWhileRecording: Bool = false { didSet { defaults.set(autoMuteWhileRecording, forKey: "autoMuteWhileRecording") } }
    var autoPauseMediaWhileRecording: Bool = false { didSet { defaults.set(autoPauseMediaWhileRecording, forKey: "autoPauseMediaWhileRecording") } }
    var showRecordingStatusItem: Bool = true { didSet { defaults.set(showRecordingStatusItem, forKey: "showRecordingStatusItem") } }
    var showRecordingPill: Bool = true { didSet { defaults.set(showRecordingPill, forKey: "showRecordingPill") } }
    /// The count-in's number, mirrored from the session so the window's overlay redraws only when it moves.
    private(set) var recordingCountdown: Int?
    /// The Stage has a take on it, by the rule its page draws by: the sidebar row, Show Recording and `showStage()` all go by this. Mirrored so the sidebar redraws only when it flips.
    private(set) var stageHoldsTake = false
    /// The Stage on screen with a take has no room for the page's notices and toasts; they wait for the page after it.
    var noticesWaitForStage: Bool { route == .recording && stageHoldsTake }
    @ObservationIgnored private(set) var countdownTask: Task<Void, Never>?

    /// A take that ended, or is in the library now, leaves nothing on its Stage.
    private static func stageHasSomethingToShow(_ session: RecordingSession?) -> Bool {
        guard let session else { return false }
        if case .done = session.state { return false }
        return true
    }

    private static func countIn(of session: RecordingSession?) -> Int? {
        guard case .arming(.countIn(let remaining)) = session?.state else { return nil }
        return remaining
    }

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
        guard !TranscribeFileIntent.isIntentScratch(url) else { return }
        var list = RecentFilesList(capacity: 10)
        list.decode(recentFilesRaw)
        list.note(url)
        recentFilesRaw = list.encoded
    }

    func clearRecentFiles() {
        recentFilesRaw = "[]"
    }

    func toggleMicRecording() {
        if let take = recording, take.isRunning {
            if take.source == .microphone { stopTake() }
            return
        }
        switch phase {
        case .idle, .ready, .failed:
            startRecording(source: .microphone)
        case .downloadingModel where downloadTask != nil:
            startRecording(source: .microphone)
        default:
            // A take still transcribing gives way to the next one, whatever else holds the phase.
            if takeRun != nil { startRecording(source: .microphone) }
        }
    }

    var micHotkeyModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(micHotkeyModifiers))
            .intersection(.deviceIndependentFlagsMask)
    }

    var pendingRecovery: RecoveryCheckpoint?
    @ObservationIgnored var recoveryGeneration: Int = 0
    /// How many checkpoints have been queued for the disk, so a test can bound them.
    @ObservationIgnored var checkpointWrites = 0
    @ObservationIgnored var activeRecoveryGeneration: Int?
    /// Each live generation's checkpoint file, named for its id; a generation missing here has ended.
    @ObservationIgnored var recoveryFileIDs: [Int: UUID] = [:]
    /// What each live generation's checkpoint last said, so a step can rewrite one field of it.
    @ObservationIgnored var recoveryCheckpoints: [Int: RecoveryCheckpoint] = [:]
    /// Checkpoints a take's run or save still needs: cleanup leaves them on disk until the entry exists.
    @ObservationIgnored var recoveryHeldByTake: Set<Int> = []
    /// Working files the checkpoints on disk point at, which the sweep leaves for the offer to settle.
    @ObservationIgnored var recoveryReferencedFiles: Set<String> = []
    /// This instance's lock on the library; a checkpoint it writes carries its id.
    @ObservationIgnored var recoveryOwner: RecoveryOwner?
    /// Where a claimed checkpoint was read from, when that isn't its own name: the legacy recovery.json, say.
    @ObservationIgnored var recoveryLoadedFiles: [UUID: URL] = [:]
    @ObservationIgnored var inflightSweep: Task<Void, Never>?
    /// Working files whose take is on its way to the library.
    @ObservationIgnored var takeFilesBeingSaved: [URL: Int] = [:]
    @ObservationIgnored var takeFileHeartbeat: Task<Void, Never>?
    @ObservationIgnored var takeFileScratchObserver: NSObjectProtocol?
    @ObservationIgnored var takeFileQuietTicks = 0
    @ObservationIgnored var takeFileHeartbeatTicks = 0
    @ObservationIgnored var takeFileHeartbeatID: UUID?
    @ObservationIgnored var recordingRecoveryStartedAt: Date?
    @ObservationIgnored var liveRecordingAudioURL: URL?
    /// A meeting's microphone track while it records beside the take, and how far into the take's audio it starts.
    @ObservationIgnored var liveCompanionAudioURL: URL?
    @ObservationIgnored var liveCompanionStartOffset: TimeInterval?
    @ObservationIgnored var recordingWatchTask: Task<Void, Never>?
    @ObservationIgnored var pendingRecoveryWrite: Task<Void, Never>?
    enum FailureKind {
        case transcription
        case other
    }

    /// Every phase change resets this, so only the transcription paths that opt back in get a named card.
    private(set) var failureKind: FailureKind = .other
    /// A take's run that failed with no session to show it, a recovered take's or a Retry's: the error card's Retry.
    var failedTakeRetry: RecordingSession.Failure?
    /// The file a failed file transcription was reading; the error card retries and reveals it.
    var failedFileURL: URL?
    /// The translate setting the failed run used, so Retry repeats it rather than the current toggle.
    var failedTranslateOverride: Bool?
    var failedLink: DeferredLink?
    var failedLinkDownload: LinkDownloadFailure?
    @ObservationIgnored var pendingDictationRestart: Task<Void, Never>?
    @ObservationIgnored var pendingDictationProcessorRebuild: Task<Void, Never>?

    var recordingDiskSpaceLow: Bool = false
    @ObservationIgnored var freeDiskSpaceProvider: @Sendable () -> Int64? = { AppModel.systemFreeDiskSpace() }

    var batchJobs: [BatchJob] = [] {
        didSet {
            batchBuckets = BatchJobBuckets(batchJobs)
            guard !BatchJob.sameQueueShape(oldValue, batchJobs) else { return }
            batchProgress.retain(Set(batchJobs.map(\.id)))
            if batchIsEmpty != batchJobs.isEmpty { batchIsEmpty = batchJobs.isEmpty }
            let running = batchJobs.contains { $0.status == .transcribing }
            if batchIsRunning != running { batchIsRunning = running }
            stampBatchFailures()
            refreshSidebarActivity()
            saveBatchQueueSnapshot()
        }
    }
    /// Mirrors of `batchJobs` that change only on a status transition, so a progress tick reaches none of their readers.
    private(set) var batchIsEmpty = true
    private(set) var batchIsRunning = false
    private(set) var sidebarActivity: SidebarActivity?
    var sidebarShowsActivity: Bool { sidebarActivity != nil }
    /// When each failed job failed, so the Activity row lets a failure go a day later.
    @ObservationIgnored private(set) var batchFailedAt: [BatchJob.ID: Date] = [:]
    @ObservationIgnored private var sidebarActivityExpiry: Task<Void, Never>?

    private func stampBatchFailures(now: Date = Date()) {
        let failed = Set(batchJobs.lazy.filter { $0.status == .failed }.map(\.id))
        batchFailedAt = batchFailedAt.filter { failed.contains($0.key) }
        for id in failed where batchFailedAt[id] == nil { batchFailedAt[id] = now }
    }

    /// Settles the Activity row for `now`, and comes back when its oldest failure still counted leaves the window.
    func refreshSidebarActivity(now: Date = Date()) {
        let activity = SidebarActivity.current(jobs: batchJobs, failedAt: batchFailedAt, now: now)
        if activity != sidebarActivity { sidebarActivity = activity }
        sidebarActivityExpiry?.cancel()
        sidebarActivityExpiry = nil
        guard case .failed = activity, let expiry = SidebarActivity.nextExpiry(failedAt: batchFailedAt, now: now) else { return }
        let clock = clock
        sidebarActivityExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(expiry.timeIntervalSince(now)), clock: clock)
            guard !Task.isCancelled else { return }
            self?.refreshSidebarActivity()
        }
    }

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
    @ObservationIgnored var batchLibraryAdds: [Task<LibraryEntry, any Error>] = []
    @ObservationIgnored var batchClosingRefresh: Task<Void, Never>?
    /// Where each finished job's sidecars landed, which is not always `<stem>.<ext>`.
    @ObservationIgnored var batchSidecars: [BatchJob.ID: [URL]] = [:]
    var selectedBatchJobID: BatchJob.ID?
    /// The file of the job whose run `phase` shows; nil once the batch lets go of the phase.
    @ObservationIgnored var batchPhaseFile: URL?
    @ObservationIgnored var batchTask: Task<Void, Never>? {
        didSet {
            if oldValue == nil, batchTask != nil { foregroundClaimedSession() }
            if oldValue != nil, batchTask == nil { foregroundLetGo() }
        }
    }
    @ObservationIgnored var lastSavedBatchQueueURLs: [URL]?

    var exportPresets: [ExportPreset] = ExportPreset.builtIns { didSet { saveExportPresets() } }
    var batchExportPresetIDs: [UUID] = [] { didSet { writeJSON(batchExportPresetIDs, forKey: "batchExportPresets") } }

    var findIsOpen: Bool = false
    /// Bumped by Edit › Find…; the find bar watches the count, so a second ⌘F puts the caret back too.
    var findFocusRequests: Int = 0
    /// Bumped by Edit › Find… while Chat shows; the chat pane opens its message filter on each.
    var chatSearchRequests: Int = 0
    /// Bumped by the Transcript menu and the title's Rename…; the transcript page opens the matching popover or alert on each.
    var jumpToTimeRequests: Int = 0
    var renameRequests: Int = 0
    /// The section the inspector scrolls to once it shows; it clears the request when it has.
    var inspectorReveal: InspectorAnchor?
    /// Bumped by every replacement, so the find bar lets go of its field and the next ⌘Z reaches the transcript.
    var findReplacements: Int = 0
    var findQuery: String = "" { didSet { scheduleRecomputeMatches() } }
    var findCaseSensitive: Bool = false { didSet { scheduleRecomputeMatches() } }
    var findWholeWords: Bool = false { didSet { scheduleRecomputeMatches() } }
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

    /// What Apple Speech says it can transcribe; nil until its language list is first opened.
    var appleSpeechLanguageCodes: Set<String>?

    @ObservationIgnored private var cachedSelectedModel: String = ""
    @ObservationIgnored private var cachedCapabilities: EngineCapabilities = .whisperKitDefaults

    var selectedModelCapabilities: EngineCapabilities {
        if cachedSelectedModel != selectedModel {
            cachedSelectedModel = selectedModel
            cachedCapabilities = ModelCatalog.staticCapabilities(forID: selectedModel) ?? .whisperKitDefaults
        }
        return cachedCapabilities
    }

    func loadAppleSpeechLanguages() async {
        guard appleSpeechLanguageCodes == nil else { return }
        let codes = await AppleSpeechLanguages.shared.codes()
        if !codes.isEmpty { appleSpeechLanguageCodes = codes }
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
        return String(localized: "Parola couldn't detect the language and assumed \(name). Pick the language in the inspector to transcribe it again.")
    }

    var diarizeMismatchWarning: String? {
        guard diarize, !selectedModelCapabilities.supportsDiarization else { return nil }
        return String(localized: "\(AppModel.modelLabel(selectedModel)) can't detect speakers, so speaker detection is skipped.")
    }

    var translateMismatchWarning: String? {
        guard translate, !selectedModelCapabilities.supportsTranslate else { return nil }
        return String(localized: "\(AppModel.modelLabel(selectedModel)) can't translate, so transcriptions stay in the source language.")
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

    var pendingRuleImport: PendingRuleImport?

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
    var showingPeopleSheet: Bool = false {
        didSet { if !showingPeopleSheet { peopleSheetRequest = nil } }
    }
    /// What the directory asks first when it opens: set from a sidebar person's menu, taken by the sheet.
    var peopleSheetRequest: PeopleSheetRequest?
    /// The people directory, mirrored from the store so views read it without awaiting the actor.
    var people: [Person] = [] {
        didSet { rebuildPeopleOrder() }
    }
    /// The directory in the order every list shows it: most assigned, then most recently used.
    private(set) var peopleByUse: [Person] = []
    @ObservationIgnored private(set) var peopleByName: [Person] = []
    #if DEBUG
    @ObservationIgnored private(set) var peopleOrderBuilds = 0
    #endif

    /// Which person the library list is filtered to, set from the sidebar, the filter bar or the bridge.
    var personFilter: UUID?
    /// Bumped when a sidebar pick opens nothing; @Observable skips the same-value writes such a pick makes, so this makes the list look again.
    var sidebarRefusedPicks = 0
    var showMostUsedPeople: Bool = true { didSet { defaults.set(showMostUsedPeople, forKey: "showMostUsedPeople") } }
    /// The speaker-map writes in flight, kept in order so the bundle never sees them out of turn.
    @ObservationIgnored var speakerAssignmentWriteTask: Task<Void, Never>?
    /// The person renames in flight, run in order so a quick undo and redo never interleave their rewrites.
    @ObservationIgnored var personRenameTask: Task<Void, Never>?
    @ObservationIgnored var personRenameCascadeHook: (@MainActor () async -> Void)?
    @ObservationIgnored var speakerAssignmentWriteHook: (@MainActor () async -> Void)?
    /// The newest speaker-map write queued per entry; an older write that lands after it must not patch the list.
    @ObservationIgnored var speakerAssignmentWriteSerials: [LibraryEntry.ID: Int] = [:]

    // MARK: - Prompt library

    @ObservationIgnored let promptLibrary: PromptLibrary
    var promptOutput: PromptOutput?
    let aiJobs = AIJobRegistry()
    var actionItems: [ActionItem] = []
    var actionItemsError: String?
    var smartChapters: [Chapter] = []
    /// The open inspector's outline of the transcript on screen, cleared when another loads.
    var inspectorOutline: [TranscriptOutline.Entry] = []
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
    var exportNotice: ExportNotice? {
        didSet {
            guard exportNotice == nil, let covered = coveredNotice else { return }
            coveredNotice = nil
            exportNotice = covered
        }
    }
    /// A notice waiting to be dismissed that a newer one went over: it comes back once the strip is clear again. One deep, never a queue.
    @ObservationIgnored var coveredNotice: ExportNotice?
    @ObservationIgnored lazy var deliveryEngine: DeliveryEngine = makeDeliveryEngine()
    @ObservationIgnored var volumeMountObservation: NotificationObservation?

    // MARK: - Watched folders

    @ObservationIgnored lazy var watchedFolders: WatchedFoldersStore = {
        let store = WatchedFoldersStore(defaults: defaults, baselineDirectory: watchedFoldersDirectory) { [weak self] url in
            self?.handleWatchedArrival(url)
        }
        store.onFolderWatching = { [weak self] in self?.retryUnreachableArrivals() }
        return store
    }()

    /// Nil when this launch doesn't watch folders, so a view never builds the store and starts its watchers.
    var watchedFoldersIfWatching: WatchedFoldersStore? {
        activeSideEffects.contains(.watchedFolders) ? watchedFolders : nil
    }

    /// Nil when this launch doesn't watch folders, so quitting never builds the store just to flush it.
    func watchedFolderBaselineFlush() -> (@Sendable () async -> Void)? {
        guard activeSideEffects.contains(.watchedFolders) else { return nil }
        return watchedFolders.pendingBaselineFlush()
    }

    /// Watched-folder files waiting their turn, the one running included; each leaves when it lands or fails.
    @ObservationIgnored var watchedArrivals: [WatchedArrival] = [] {
        didSet {
            guard watchedArrivals != oldValue else { return }
            saveWatchedArrivals(urgent: Self.needsPromptSave(from: oldValue, to: watchedArrivals))
            if !unsavedLandings.isEmpty {
                let waiting = Set(watchedArrivals.map(\.id))
                unsavedLandings = unsavedLandings.filter { waiting.contains($0.key) }
            }
        }
    }
    @ObservationIgnored lazy var watchedArrivalsFile = WatchedArrivalsFile(url: watchedArrivalsFileURL)
    /// Transcripts whose save failed, kept so Retry saves them again instead of transcribing; this launch only.
    @ObservationIgnored var unsavedLandings: [WatchedArrival.ID: UnsavedLanding] = [:]
    /// Test seam: when set, replaces telling the watchers that a file they handed over couldn't be used.
    @ObservationIgnored var offerWatchedFileAgain: (@MainActor (URL) -> Void)?
    @ObservationIgnored var watchedLaneTask: Task<Void, Never>?
    @ObservationIgnored var backgroundArrivalID: WatchedArrival.ID?
    @ObservationIgnored var laneOwesRing = false
    /// Set when a failure that isn't the file's own stopped the lane: the number of foreground claims at that moment.
    @ObservationIgnored var watchedLanePausedAt: Int?
    @ObservationIgnored var foregroundClaims = 0
    /// Files whose folder didn't answer: they keep their place and wait for the folder to come back.
    @ObservationIgnored var unreachableArrivalIDs: Set<WatchedArrival.ID> = []
    @ObservationIgnored var watchedFolderReturns = 0
    /// Test seam: where a watched file stands, given the folder it came from.
    @ObservationIgnored var watchedFileReach: @Sendable (URL, URL) -> WatchedArrival.Reach = WatchedArrival.reach
    @ObservationIgnored var visibleArrivalID: WatchedArrival.ID?
    var arrivalNotice: ArrivalNotice?
    var runningArrivalNotice: ArrivalNotice?

    /// A `--library` override keeps the watchers' baselines next to that library, like the delivery queue.
    var watchedFoldersDirectory: URL {
        library.libraryURL == LibraryStore.defaultLibraryURL
            ? URL.applicationSupportDirectory.appending(path: "Parola/Watched Folders", directoryHint: .isDirectory)
            : library.libraryURL.appendingPathComponent("Watched Folders", isDirectory: true)
    }

    // MARK: - Live captions

    @ObservationIgnored weak var liveCaptions: LiveCaptionsController? {
        didSet {
            liveCaptions?.openPermission = { [capturePermissions] permission in
                Self.openCaptionPermission(permission, using: capturePermissions)
            }
            liveCaptions?.optionsProvider = { [weak self] in
                guard let self else { return TranscriptionOptions() }
                return makeOptions(task: .transcribe, model: selectedModel, language: selectedLanguage)
            }
            liveCaptions?.unavailableReason = { [weak self] in self?.liveCaptionsUnavailableReason }
        }
    }

    /// Screen Recording goes through the request the Allow… button makes, so a first ask raises the system prompt; the rest open their pane.
    static func openCaptionPermission(
        _ permission: RecordingSession.Permission, using permissions: SystemCapturePermissions,
        openPane: (RecordingSession.Permission) -> Void = { $0.openSettings() }
    ) {
        switch permission {
        case .screenRecording:
            permissions.refresh()
            // A failure that isn't a refusal (a start that timed out) has nothing to request; the pane is the way on.
            if permissions.screenRecordingGranted { openPane(permission) } else { permissions.requestScreenRecording() }
        case .systemAudioRecording, .microphone:
            openPane(permission)
        }
    }

    /// Nil when the selected model can show live captions; otherwise the user-facing reason.
    var liveCaptionsUnavailableReason: String? {
        guard ModelCatalog.canCaption(id: selectedModel) else { return unsupportedCaptionReason }
        if ModelCatalog.variant(id: selectedModel)?.engineID == .parakeet { return languageMismatchWarning }
        return nil
    }

    private var unsupportedCaptionReason: String {
        String(localized: "\(AppModel.modelLabel(selectedModel)) can't show Live Captions. Pick a Whisper or Parakeet model.")
    }

    func toggleLiveCaptions() {
        introduction.defer()
        guard features.isEnabled(.liveCaptions) else { return }
        guard let liveCaptions else { return }
        if !liveCaptions.isActive, let reason = liveCaptionsUnavailableReason {
            guard !takeIsRunning else { return }
            switch phase {
            case .idle, .ready, .failed:
                phase = .failed(message: reason)
            default:
                break
            }
            return
        }
        Task { await liveCaptions.toggle(options: makeOptions(task: .transcribe, model: selectedModel, language: selectedLanguage), source: liveCaptionsSource) }
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
    var serifTranscript: Bool = false { didSet { defaults.set(serifTranscript, forKey: "serifTranscript") } }

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

    /// The palette's keys only: Light and Dark are NSApp.appearance's, and need no repaint.
    private func themeKeySnapshot() -> [String] {
        [appAccentRaw, String(themeIsCustom), themeCustomPaletteJSON]
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
        self.meetingRecordsMicrophone = readBool("meetingRecordsMicrophone", default: true)
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
        self.showRecordingStatusItem = readBool("showRecordingStatusItem", default: true)
        self.showRecordingPill = readBool("showRecordingPill", default: true)
        self.inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? ModelCatalog.defaultModelID()
        self.selectedLanguageRaw = defaults.string(forKey: "selectedLanguageRaw") ?? ""
        self.translate = defaults.bool(forKey: "translate")
        self.appTheme = defaults.string(forKey: "appTheme") ?? "system"
        self.monospacedTimestamps = readBool("monospacedTimestamps", default: true)
        self.serifTranscript = readBool("serifTranscript", default: false)
        self.appAccentRaw = Self.migratedAccentRaw(from: defaults)
        self.themeIsCustom = defaults.bool(forKey: "themeIsCustom")
        self.themeCustomPaletteJSON = defaults.string(forKey: "themeCustomPaletteJSON") ?? ""
        self.automationBridgeEnabled = readBool("automationBridgeEnabled", default: AppModel.defaultBridgeEnabled)
        self.sparkleChannelRaw = defaults.string(forKey: "sparkleChannel") ?? SparkleChannel.stable.rawValue
        self.sparkleAutomatic = readBool("sparkleAutomatic", default: true)
        self.liveCaptionsTranslate = defaults.bool(forKey: "liveCaptionsTranslate")
        self.liveCaptionsSourceRaw = CaptionSource(setting: defaults.string(forKey: "liveCaptionsSource")).setting
        self.remoteAIAcknowledged = defaults.bool(forKey: "remoteAIAcknowledged")
        self.showMostUsedPeople = readBool("showMostUsedPeople", default: true)
        self.openEntriesInNewWindow = defaults.bool(forKey: "openEntriesInNewWindow")
        self.libraryGroupsByDate = readBool("libraryGroupsByDate", default: true)
        self.lastRecordSource = defaults.string(forKey: "lastRecordSource").flatMap(RecordSource.init(rawValue:)) ?? .microphone
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
        Task { await liveCaptions?.setSource(liveCaptionsSource) }

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

    /// Every pre-Sage install wrote "slate" back on each launch, so nil-means-unset would never surface Sage; migrates that one value once, behind a flag a later explicit pick of Slate won't retrigger.
    private static func migratedAccentRaw(from defaults: UserDefaults) -> String {
        let migrationKey = "didMigrateSlateAccentToSage"
        guard !defaults.bool(forKey: migrationKey) else {
            return defaults.string(forKey: AppAccent.storageKey) ?? AppAccent.defaultAccent.rawValue
        }
        defaults.set(true, forKey: migrationKey)
        guard defaults.string(forKey: AppAccent.storageKey) == ThemePreset.slate.rawValue else {
            return defaults.string(forKey: AppAccent.storageKey) ?? AppAccent.defaultAccent.rawValue
        }
        defaults.set(ThemePreset.sage.rawValue, forKey: AppAccent.storageKey)
        return ThemePreset.sage.rawValue
    }

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
    @ObservationIgnored let dictationPermissions = DictationPermissions(readsAtLaunch: false)
    @ObservationIgnored let capturePermissions: SystemCapturePermissions

    var dictationState: DictationCoordinator.State = .idle
    /// The meter the take in progress writes; set once per take, never per buffer.
    private(set) var recordingLevelMeter: LevelMeter?
    /// The levels the take has drawn, kept here rather than in the pane so a rebuilt pane keeps its waveform.
    @ObservationIgnored private(set) var recordingLevelTrace: LevelTrace?
    static let takeLevelHistoryCapacity = 48
    var recordingIsSilent: Bool = false
    @ObservationIgnored var silenceDetector: SilenceDetector = SilenceDetector(threshold: 8)
    @ObservationIgnored var silenceRule = SilenceRule()
    /// The take's silence watch runs on the sampler's tick from its capture's start until it pauses or ends.
    @ObservationIgnored private(set) var watchesSilence = false
    @ObservationIgnored private var silenceTicks = 0
    @ObservationIgnored var recordingAutoStopTask: Task<Void, Never>?
    @ObservationIgnored private var recordingAutoStop: AutoStopBudget?
    /// The last pause or resume on its way to the capture; the next one waits for it.
    @ObservationIgnored private var takePauseWrites: Task<Void, Never>?

    /// What is left of a take's recording limit, and since when it has been running down; a pause stops it running.
    private struct AutoStopBudget {
        let takeID: Int
        var remaining: Duration
        var runningSince: ContinuousClock.Instant?
    }

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

    var meetingDetectedApp: String? {
        didSet {
            guard meetingDetectedApp != oldValue else { return }
            if oldValue != nil { meetingNotifier?.promptLowered() }
            if let meetingDetectedApp { meetingNotifier?.promptRaised(meetingDetectedApp) }
        }
    }
    /// Tells about the prompt in a notification when the window can't show it; nil unless the launch watches for meetings for real.
    @ObservationIgnored var meetingNotifier: MeetingNotifier?
    /// The meeting app the detector saw last, for the Record menu and the menu bar; it outlives the alert `meetingDetectedApp` raises.
    var detectedMeetingAppName: String?
    var meetingCaptureAppOnly: Bool = false { didSet { defaults.set(meetingCaptureAppOnly, forKey: "meetingCaptureAppOnly") } }
    /// A meeting take records your microphone too, as a second track beside the Mac audio.
    var meetingRecordsMicrophone: Bool = true { didSet { defaults.set(meetingRecordsMicrophone, forKey: "meetingRecordsMicrophone") } }
    /// The category the next take's Record asked for; nil files it by its source, through `defaultCategory(for:)`.
    @ObservationIgnored var pendingRecordingCategory: EntryCategory?
    /// Where the take in flight is listening, for the manifest a persist writes after the phase has moved on.
    @ObservationIgnored var pendingRecordingSource: EntrySource = .microphone
    @ObservationIgnored var pendingCaptureBundleIDs: Set<String>?
    @ObservationIgnored var pendingSourceAppBundleID: String?
    @ObservationIgnored var installedBundleID: @MainActor (Set<String>) -> String? = { SourceAppIcon.installedBundleID(among: $0) }
    /// Reading it starts it, and test mode leaves it off, so views read `detectedMeetingAppName` instead.
    @ObservationIgnored lazy var meetingDetector: MeetingDetector = startMeetingDetector()
    /// Test seam: whether anything has started the detector.
    @ObservationIgnored private(set) var meetingDetectorStarted = false

    private func startMeetingDetector() -> MeetingDetector {
        meetingDetectorStarted = true
        return MeetingDetector { [weak self] appName in
            guard let self else { return }
            self.detectedMeetingAppName = appName
            // Never prompt over in-flight work: accepting would stomp a live recording.
            guard !self.takeIsRunning, self.takeRun == nil else { return }
            let prompts = switch self.phase {
            case .idle, .ready, .failed: true
            case .downloadingModel: self.downloadTask != nil
            default: false
            }
            // A presented alert's title never updates, so keep the first prompt — accept
            // and decline must act on the app name the user is actually reading.
            if prompts, self.meetingDetectedApp == nil { self.meetingDetectedApp = appName }
        } onQuit: { [weak self] appName in
            self?.meetingAppQuit(appName)
        } onDisabled: { [weak self] in
            self?.meetingDetectedApp = nil
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
            let transcripts = Self.personTranscriptCounts(in: libraryEntries)
            if transcripts != personTranscriptCounts { personTranscriptCounts = transcripts }
            let badges = LibraryCounts(libraryEntries)
            if badges != libraryCounts { libraryCounts = badges }
            let usual = LibraryRowFormat.usualLanguage(codes: libraryEntries.compactMap { LanguageDisplay.code(for: $0.language) })
            if usual != usualLanguage { usualLanguage = usual }
            let recent = LanguageChoices.recent(in: libraryEntries)
            if recent != recentLanguages { recentLanguages = recent }
            updateSelectedEntryMirrors()
        }
    }
    /// The language most of the library is in, as a code; a row names its own language only when it differs.
    private(set) var usualLanguage: String?
    /// The library's last few languages, newest first, for the language pickers to lead with.
    private(set) var recentLanguages: [String] = []
    /// How many speaker labels across the library stand for each person. Read off the maps, so an assignment an undo takes back stops counting.
    private(set) var personUsageCounts: [UUID: Int] = [:] {
        didSet { rebuildPeopleOrder() }
    }

    private func rebuildPeopleOrder() {
        #if DEBUG
        peopleOrderBuilds &+= 1
        #endif
        let counts = personUsageCounts
        let byUse = people.sorted {
            let left = counts[$0.id] ?? 0
            let right = counts[$1.id] ?? 0
            return left == right ? $0.lastUsedAt > $1.lastUsedAt : left > right
        }
        if byUse != peopleByUse { peopleByUse = byUse }
        peopleByName = people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// How many transcripts stand for each person, for the sidebar's badges.
    private(set) var personTranscriptCounts: [UUID: Int] = [:]
    /// The sidebar's counts, set only when one moves, so a rename or an open repaints no badge.
    private(set) var libraryCounts = LibraryCounts()
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
        guard route == .transcript else { return false }
        switch transcriptRoutePhase {
        case .failed:
            // The failure's banner is on the Library page, which the route draws over an open transcript too.
            return true
        case .idle, .ready:
            // Results the transcript did not come from take the content area; clearing them gives it back.
            if hasTranscript { return hasSearchResults && !openedFromSearch }
            return true
        default: return false
        }
    }

    /// The phase the transcript route draws: a batch job's run shows under Activity, and a model download waits behind a take or a transcript, so the page either would cover stays up.
    var transcriptRoutePhase: Phase {
        if batchOwnsPhase { return .ready }
        if case .downloadingModel = phase, recording.map({ !$0.isOver }) ?? false || (downloadTask != nil && transcript != nil) {
            return .ready
        }
        return phase
    }

    var transcriptRouteFailed: Bool {
        if case .failed = transcriptRoutePhase { return true }
        return false
    }

    /// The Library page with nothing narrowing it: no category or person filter, and no search results.
    var isBrowsingWholeLibrary: Bool {
        isBrowsingLibrary && libraryFilter == nil && personFilter == nil && !hasSearchResults
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

    /// The transcript is a drill-down only while it is the page on screen.
    var canReturnToOrigin: Bool {
        hasTranscript && route == .transcript && !isBrowsingLibrary
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
            updateSelectedEntryMirrors()
            dropTakeSavedOnceLeft()
            savedTranscriptEntryID = nil
        }
    }
    /// The entry the transcript on screen was just saved as: its source file sits outside the bundle, so only this ties them.
    var savedTranscriptEntryID: LibraryEntry.ID?
    /// The menus read this rather than the whole library, so a library write doesn't rebuild them.
    private(set) var selectedEntryHasFavorites = false
    /// The open entry's favorites, notes and speaker map, copied out of the library so a card reads them without tying itself to every library write.
    private(set) var selectedEntryFavorites: Set<Int> = []
    private(set) var selectedEntryNotes: [String: String] = [:]
    private(set) var selectedEntrySpeakerAssignments: [String: UUID] = [:]

    // MARK: - Transcript windows

    /// The window the library and a take's controls live in; nil once it closed.
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Test seam: stands in for where the main window is, which a unit test can't show, minimize or close.
    @ObservationIgnored var mainWindowPresenceOverride: MainWindowPresence?
    @ObservationIgnored let entryWindows = EntryWindowRegistry()
    @ObservationIgnored var openEntryWindowAction: ((LibraryEntry.ID) -> Void)?
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    var keyViewerEntryIDs: Set<LibraryEntry.ID> = []
    var openEntriesInNewWindow: Bool = false {
        didSet { defaults.set(openEntriesInNewWindow, forKey: "openEntriesInNewWindow") }
    }

    @ObservationIgnored private var libraryEntriesByID: [String: LibraryEntry] = [:]

    private func rebuildLibraryIndex() {
        libraryEntriesByID = Dictionary(uniqueKeysWithValues: libraryEntries.map { ($0.id, $0) })
    }

    private func updateSelectedEntryMirrors() {
        let manifest = selectedEntryID.flatMap { libraryEntriesByID[$0] }?.manifest
        let favorites = Set(manifest?.favoriteSegments ?? [])
        if selectedEntryFavorites != favorites { selectedEntryFavorites = favorites }
        let notes = manifest?.segmentNotes ?? [:]
        if selectedEntryNotes != notes { selectedEntryNotes = notes }
        let assignments = manifest?.speakerAssignments ?? [:]
        if selectedEntrySpeakerAssignments != assignments { selectedEntrySpeakerAssignments = assignments }
        let hasFavorites = !favorites.isEmpty
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
    /// The Library page's Labels, Language and date choices, kept here so a transcript opened over the list leaves them as they were.
    var labelFilter: String?
    var languageFilter: String?
    var dateRangeFilter: LibraryDateRangeFilter = .all
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
    var libraryGroupsByDate: Bool = true { didSet { defaults.set(libraryGroupsByDate, forKey: "libraryGroupsByDate") } }
    /// The empty library's Microphone | System Audio choice.
    var lastRecordSource: RecordSource = .microphone { didSet { defaults.set(lastRecordSource.rawValue, forKey: "lastRecordSource") } }
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
    /// On the model so the formatted rows outlive their list; every other page re-opens to the same entries.
    @ObservationIgnored var libraryBrowseDisplays = LibraryRowDisplayCache()
    @ObservationIgnored var librarySearchDisplays = LibraryRowDisplayCache()
    @ObservationIgnored var libraryExcerptsTask: Task<Void, Never>?
    @ObservationIgnored var libraryExcerptsGeneration = 0
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var libraryRefreshTask: Task<Void, Never>?
    /// An entry's labels while writes are still on their way to disk; edits build on this list, not on the cache.
    var pendingLabels: [LibraryEntry.ID: [String]] = [:]
    @ObservationIgnored var labelWrites: [LibraryEntry.ID: LabelWrite] = [:]
    /// How many scans `refreshLibrary()` has started, so a test can bound them.
    @ObservationIgnored var libraryRefreshes = 0
    /// Bumped by every row written in place, so a scan can tell its snapshot is older than the rows.
    @ObservationIgnored var libraryLocalEdits = 0
    /// False until the first scan lands, so the empty list before it never reads as an empty library.
    var libraryLoaded = false
    @ObservationIgnored var pendingTranscriptSaveTask: Task<Void, Never>?
    @ObservationIgnored var transcriptCloseTask: Task<Void, Never>?
    @ObservationIgnored var pendingTranscriptSaveGeneration: Int = 0
    @ObservationIgnored private var pendingSaveTextChanged = false
    /// Each undo step holds a whole transcript, so an editing session can't pin them without limit.
    static let undoLevels = 100
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = Self.undoLevels }
    }
    static let trashRetentionDays = 30

    // MARK: - Engine

    @ObservationIgnored let session = TranscriptionSession()
    @ObservationIgnored var modelResidency = ModelResidencyCoordinator(streaming: LiveStreamingModelResidency())
    @ObservationIgnored private let store = ModelStore.shared
    @ObservationIgnored lazy var mediaSession = MediaSession(
        ownPlayback: OwnPlayerPause { [weak self] in self?.ownPlayers() ?? [] }
    )

    func ownPlayers() -> [PlayerHandle] {
        let windowPlayers = entryWindows.sessions.values.compactMap(\.player)
        return ([player].compactMap { $0 } + windowPlayers).map(PlayerHandle.init)
    }

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

    @ObservationIgnored var liveSource: AudioSource? {
        didSet { if oldValue != nil, liveSource == nil { foregroundLetGo() } }
    }
    /// A file handed over again while it waits, because nothing seemed to answer the first time, still runs once.
    @ObservationIgnored var deferredArrivals: [URL] = [] {
        didSet {
            var seen = Set<URL>()
            let once = deferredArrivals.filter { seen.insert($0.standardizedFileURL).inserted }
            if once.count != deferredArrivals.count { deferredArrivals = once }
        }
    }
    /// A link pasted again while it waits still runs once, as a file handed over twice does.
    @ObservationIgnored var deferredLinks: [DeferredLink] = [] {
        didSet {
            var seen = Set<DeferredLink>()
            let once = deferredLinks.filter { seen.insert($0).inserted }
            if once.count != deferredLinks.count { deferredLinks = once }
        }
    }
    @ObservationIgnored var arrivalDrain: Task<Void, Never>?
    /// Test seam: whether a parked file is still there when the drain comes for it.
    @ObservationIgnored var parkedFileProbe: @Sendable (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }
    @ObservationIgnored var pendingOpenedFiles: [URL] = []
    var pendingLargeDrop: PendingLargeDrop?
    @ObservationIgnored var openedFilesFlushTask: Task<Void, Never>?
    @ObservationIgnored private(set) var streamingSession: (any StreamingTranscriber)? {
        didSet { if oldValue != nil, streamingSession == nil { foregroundLetGo() } }
    }
    @ObservationIgnored var streamingConsumer: Task<Void, Never>?
    @ObservationIgnored var fileTranscribeTask: Task<Void, Never>? {
        didSet {
            guard oldValue != fileTranscribeTask else { return }
            if oldValue == nil { foregroundClaimedSession() }
            visibleArrivalLostTheWindow()
            if fileTranscribeTask == nil { foregroundLetGo() }
        }
    }
    @ObservationIgnored var fileRunLanding: FileRunLanding?
    @ObservationIgnored var fileRunFailure: FileRunFailure?
    @ObservationIgnored var landingSteps: Task<Void, Never>?
    /// Test seam: runs before a landing's library add, and a throw fails the save.
    @ObservationIgnored var beforeLandingSave: (@Sendable () async throws -> Void)?
    @ObservationIgnored let fileReadDeadline: Duration
    @ObservationIgnored private var cancelPass = 0
    @ObservationIgnored private var unsettledInPass = 0
    /// Bumped by every file run. An abandoned run's engine can keep emitting after the slot has
    /// moved on, and its partials would land in the pane the next run is filling.
    @ObservationIgnored private(set) var fileRunGeneration = 0
    @ObservationIgnored var recordingOutcomeWaiters: [RecordingOutcomeWaiter] = []
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Test seam: stands in for a model's download, so a test decides how far it gets and when it ends.
    @ObservationIgnored var modelDownloadOperation: (@Sendable (String, @escaping @Sendable (Double) -> Void) async throws -> Void)?
    @ObservationIgnored private var youtubeTranscribeTask: Task<Void, Never>? {
        didSet { if oldValue != nil, youtubeTranscribeTask == nil { foregroundLetGo() } }
    }
    @ObservationIgnored private(set) var youtubeSubsTask: Task<Void, Never>? {
        didSet { if oldValue != nil, youtubeSubsTask == nil { foregroundLetGo() } }
    }
    /// A take recording, starting or finishing keeps its working files in use even before anything names them.
    var takeFileIsHeld: Bool {
        takeIsRunning || recordingStartInFlight || takeRun != nil || holdsInflightFile
    }

    /// Observed, so a view reading `recordingActive` hears a start that ends after its take's session did.
    private var recordingStartInFlight = false {
        didSet {
            if !oldValue, recordingStartInFlight { foregroundClaimedSession() }
            if oldValue, !recordingStartInFlight { foregroundLetGo() }
        }
    }
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

    /// The runs that paint a phase of their own: not a duplicate check's digest, nor a take's run, so a download's bar behind either is its own to hand back.
    var runOwnsPhase: Bool {
        (fileTranscribeTask != nil && fileTranscribeTask != takeTask) || youtubeTranscribeTask != nil
            || youtubeSubsTask != nil || batchTask != nil
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
        stopTakeRunForNewWork()
        fileTranscribeTask?.cancel()
        fileTranscribeTask = nil
        youtubeTranscribeTask?.cancel()
        youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel()
        youtubeSubsTask = nil
    }

    private var requeuableRuns: [Task<Void, Never>] {
        [duplicateCheckTask, fileTranscribeTask, youtubeTranscribeTask, youtubeSubsTask].compactMap(\.self)
    }

    /// Remembers what `task` goes back in line as if a take cuts it off.
    func noteRequeue(_ retry: RunRetry, for task: Task<Void, Never>?) {
        let running = Set(requeuableRuns)
        requeues = requeues.filter { running.contains($0.key) }
        if let task { requeues[task] = retry }
    }

    /// A take outranks a file or link run: the run stops, waits in line behind the take, and the take's Stage says so.
    private func requeueRunsForTake() {
        let interrupted = requeuableRuns.compactMap { requeues[$0] }
        requeues = [:]
        guard let first = interrupted.first else { return }
        for retry in interrupted {
            switch retry {
            case .file(let url, _): deferredArrivals.append(url)
            case .link(let link): deferredLinks.append(link)
            }
        }
        let covered = exportNotice
        exportNotice = ExportNotice(
            message: String(localized: "Stopped transcribing \(first.name). It starts again after the recording."),
            failures: [], folder: nil, tone: .info, whileTakeRuns: true
        )
        keepCovered(covered, take: nil)
    }

    /// New work outranks a take still transcribing: its pane comes down now, and its save says why.
    func stopTakeRunForNewWork() {
        takeRunStoppedByNewWork = takeRun
        endTakeTranscription()
    }

    var canCancel: Bool {
        hasForegroundWork || burnTask != nil
    }

    /// Everything Cancel stops ahead of a burn, which runs beside the rest and has its own Cancel. A live take's stream is the take itself while it records.
    private var hasForegroundWork: Bool {
        batchTask != nil || (streamingConsumer != nil && !takeIsCapturing) || fileTranscribeTask != nil || downloadTask != nil
            || youtubeTranscribeTask != nil || youtubeSubsTask != nil
    }

    /// The take is recording or paused: only Stop or the confirmed Discard ends it, never Cancel.
    private var takeIsCapturing: Bool {
        guard let take = activeTake, let session = recording, session.takeID == take.id else { return false }
        return session.isCapturing
    }

    private func teardownActiveCapture(exitsMedia: Bool = true) {
        letLiveTakeFinishAlone()
        let takeRecovery = activeTake?.recovery
        endSession(of: activeTake?.id)
        letGoOfFinishingTake()
        if recordingStartInFlight, liveSource == nil {
            stopRequestedDuringStart = true
        } else {
            activeTake = nil
        }
        cancelRecordingAutoStop()
        stopSilenceWatch()
        clearTakeReadouts()
        stopRecordingWatch()
        if let takeRecovery { endRecovery(takeRecovery) }
        endActiveRecovery()
        liveRecordingAudioURL = nil
        liveCompanionAudioURL = nil
        liveCompanionStartOffset = nil
        cancelAndTrack(&streamingConsumer)
        if let s = streamingSession {
            streamingSession = nil
            Task { await s.cancel() }
        }
        if let source = liveSource {
            liveSource = nil
            Task { await source.cancel() }
        }
        if let mic = detachMicTrack(of: nil) { Task { await dropMicTrack(mic) } }
        if exitsMedia { Task { await mediaSession.exitRecording(holder: .take) } }
        pendingRecordingCategory = nil
    }

    /// A live take already finishing keeps its stream and its checkpoint; the rest of the teardown no longer sees it as the active take.
    private func letLiveTakeFinishAlone() {
        guard streamingSession == nil, streamingConsumer != nil, let take = activeTake,
              recording?.takeID == take.id, recording?.state == .finishing else { return }
        liveTakesFinishingAlone[take.id] = FinishingAlone(take: take, annotations: annotations(of: take.id))
        if let recovery = take.recovery { recoveryHeldByTake.insert(recovery) }
        streamingConsumer = nil
        activeTake = nil
    }

    /// A stopped take still finishing its file goes on alone, freeing Record and the Stage; it lands only with its save, so a cut-short file can still say so.
    private func letGoOfFinishingTake() {
        var letGo = false
        updateSession(of: recording?.takeID) { session in
            guard session.state == .finishing else { return }
            letGo = session.transcribing(progress: nil)
        }
        if letGo, route == .recording { route = .transcript }
    }

    /// Stops what the window shows, and says whether it stopped anything. A take that records or is paused is left alone, with the files and links waiting for it; one still starting ends, having recorded nothing.
    @discardableResult
    func cancelCurrentWork() -> Bool {
        catchUpFirstBuffer()
        let keepsTake = takeIsCapturing
        let hadWork = hasForegroundWork || (liveSource != nil && !keepsTake)
        let endsStartingTake = !keepsTake && activeTake.map { take in recording?.takeID == take.id && recording?.isArming == true } ?? false
        let endsBurn = !hadWork && burnTask != nil
        // A new pass reports on its own runs only: one abandoned an hour ago must not make an
        // honest cancel look like it never finished.
        cancelPass &+= 1
        unsettledInPass = 0
        cancelAllInFlightBatchJobs()
        cancelVisibleArrival()
        sendWaitingArrivalsOutOfSight()
        if !keepsTake {
            deferredArrivals = []
            deferredLinks = []
        }
        cancelAndTrack(&downloadTask)
        cancelAndTrack(&fileTranscribeTask)
        retireCurrentFileRun()
        endTakeTranscription()
        cancelAndTrack(&youtubeTranscribeTask)
        cancelAndTrack(&youtubeSubsTask)
        // Cancel stops what the window shows; a burn behind a run is stopped from its own strip.
        if !hadWork { cancelBurn() }
        if !keepsTake {
            let ending = activeTake?.id ?? recording?.takeID
            teardownActiveCapture()
            resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: ending)
        }
        if hadWork || phase != .ready { phase = .idle }
        return hadWork || endsStartingTake || endsBurn
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
        cancelRecordingCountdown()
        batchTask?.cancel(); batchTask = nil
        matchesDebounce?.cancel(); matchesDebounce = nil
        watchesSilence = false
        cancelRecordingAutoStop()
        recordingWatchTask?.cancel(); recordingWatchTask = nil
        searchTask?.cancel(); searchTask = nil
        downloadTask?.cancel(); downloadTask = nil
        fileTranscribeTask?.cancel(); fileTranscribeTask = nil
        endTakeTranscription()
        youtubeTranscribeTask?.cancel(); youtubeTranscribeTask = nil
        youtubeSubsTask?.cancel(); youtubeSubsTask = nil
        burnTask?.cancel(); burnTask = nil
        teardownActiveCapture()
        resolveEveryRecordingOutcome(.failure(IntentActionError.cancelled))
    }

    func unloadTranscriptionSession() async {
        await session.unloadModel()
        await dictationController.fallbackSession.unloadModel()
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

    // MARK: - Live captions source

    @ObservationIgnored lazy var captionApps = CaptionAppList()

    var liveCaptionsSourceRaw: String = "microphone" {
        didSet {
            defaults.set(liveCaptionsSourceRaw, forKey: "liveCaptionsSource")
            if !isReloadingSettings, !choosingCaptionSource { Task { await liveCaptions?.setSource(liveCaptionsSource) } }
        }
    }

    @ObservationIgnored private var choosingCaptionSource = false

    /// Picks the source and returns once a running session has restarted on it.
    func chooseLiveCaptionsSource(_ raw: String) async {
        choosingCaptionSource = true
        liveCaptionsSourceRaw = raw
        choosingCaptionSource = false
        await liveCaptions?.setSource(liveCaptionsSource)
    }

    var liveCaptionsSource: CaptionSource {
        CaptionSource(setting: liveCaptionsSourceRaw, deviceUID: inputDeviceUID.isEmpty ? nil : inputDeviceUID)
    }

    // MARK: - Live captions translation

    var liveCaptionsTranslate: Bool = false {
        didSet { if !isReloadingSettings { applyLiveCaptionsTranslateChange() }; defaults.set(liveCaptionsTranslate, forKey: "liveCaptionsTranslate") }
    }

    private func applyLiveCaptionsTranslateChange() {
        // Parakeet passes so the panel reports it can't translate, instead of the switch doing nothing.
        let parakeet = ModelCatalog.variant(id: selectedModel)?.engineID == .parakeet
        let enabled = liveCaptionsTranslate && (selectedModelCapabilities.supportsTranslate || parakeet)
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
        self.mainSidebar = MainSidebar(defaults: defaults)
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
        self.capturePermissions = SystemCapturePermissions.forLaunch(sideEffects: bootstrap.sideEffects)
        // Takes must outlive a failed transcription, a crash, and the OS temp purge.
        RecordingScratch.setDirectory(library.libraryURL.appendingPathComponent("inflight", isDirectory: true))
        self.recoveryOwner = RecoveryOwner(
            directory: library.libraryURL.appendingPathComponent("recovery/owners", isDirectory: true)
        )
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
            self.appIsActive = { true }
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
        restoreWatchedArrivals()
        loadPendingRecovery()
        sweepInflightRecordings()
        if bootstrap.mode != .test { startTakeFileHeartbeat() }
        modelResidency.attach(fileSession: session) { [weak self] in self?.dictationController.fallbackSession }
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

    /// One transcription, one batch run or one re-run has landed in the library.
    func playCompletionSound() {
        guard playSoundWhenFinished, let completionSoundPlayer else { return }
        completionSoundPlayer()
    }

    // MARK: - Model list

    var modelSizes: [String: Int64] = [:]
    var supersededCopies: [SupersededCopy] = []
    @ObservationIgnored var supersededCopiesTask: Task<Void, Never>?
    var modelsBeingDeleted: Set<String> = []
    /// Last model download/delete failure, surfaced as a banner in the Models pane —
    /// the shared phase error renders in the main window, invisible behind Settings.
    var modelActionError: String?

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
        refreshSupersededCopies()
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
        beginDeletingModel(name)
    }

    @discardableResult
    func beginDeletingModel(_ name: String, in store: ModelStore? = nil) -> Task<Void, Never>? {
        guard !isDeletingModel(name) else { return nil }
        modelsBeingDeleted.insert(name)
        let store = store ?? self.store
        return Task { [weak self] in
            await self?.modelResidency.free(name)
            let failure: (any Error)?
            do {
                // Delete frees everything the model owns, earlier downloads included; the dialog counts them.
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
                let message = String(localized: "Could not delete \(name): \(FailureText.message(for: failure))")
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
        modelResidency.warmFileSession(selectedModel)
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
            // A take's run holds the run slot off the phase, so a download finishing under it could not hand the phase back.
            return takeTranscription == nil ? nil : "Wait for the current job to finish before downloading a model."
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
        let downloadOverride = modelDownloadOperation
        downloadTask = Task {
            do {
                phase = .downloadingModel(name: name, progress: 0)
                if let downloadOverride {
                    try await downloadOverride(name, progress)
                } else {
                    // Cold launch reaches here before any transcribe has registered the engines,
                    // and an empty registry silently swaps in the generic HuggingFace downloader.
                    await ParolaCoreBootstrap.registerBuiltInEngines()
                    _ = try await store.download(variant: name, progress: progress)
                }
                finishModelDownload()
            } catch {
                if !Task.isCancelled {
                    let message = Self.offlineMessage(for: error) ?? Self.downloadFailureMessage(for: error)
                    // A take or a run that took the page since keeps it, as does a transcript the bar was drawn past; Settings still says why.
                    if case .downloadingModel = phase { phase = transcript == nil ? .failed(message: message) : .ready }
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
        if !runOwnsPhase, case .downloadingModel = phase { phase = transcript == nil ? .idle : .ready }
        refreshModelList()
        if watchedLanePausedAt != nil { resumeWatchedLane() }
    }

    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloadingModel = phase { phase = transcript == nil ? .idle : .ready }
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
        } else if parkBehindRun(files.media) {
            return
        } else if files.media.count > 1, features.isEnabled(.batch) {
            importBatchFiles(files.media)
        } else {
            showRunPage()
            transcribe(fileURL: files.media[0], translateOverride: translateOverride)
            deferredArrivals.append(contentsOf: files.media.dropFirst())
        }
    }

    /// What a drop does first, for a run the user or the bridge starts: the page it shows on comes up, so it never starts out of sight. A run a take parks leaves the Stage up.
    func showRunPage() {
        guard !takeIsRunning else { return }
        // Before the route: a failure nobody saw on another page moves to a notice rather than going unread.
        leaveFailedPhase()
        route = .transcript
    }

    /// A link that waits behind a run in flight, a take's included, starts later wherever the user is, so the page stays as it is.
    func showLinkRunPage() {
        guard !linkArrivalsDeferred else { return }
        showRunPage()
    }

    /// Open Recent, as ⌘O: the file's page comes up, unless a batch takes the file in or a run makes it wait.
    func openRecentFile(_ url: URL) {
        guard !parkBehindRun([url]) else { return }
        if !batchIsRunning { showRunPage() }
        transcribe(fileURL: url)
    }

    /// A file opened while a single file or a take's recording transcribes waits its turn, as a dropped one does, rather than cancelling that run.
    private func parkBehindRun(_ urls: [URL]) -> Bool {
        guard !takeIsRunning, takeRun != nil || transcribeTaskRunning else { return false }
        deferredArrivals.append(contentsOf: urls)
        guard exportNotice.map({ $0.actions.isEmpty && $0.tone != .failure }) ?? true else { return true }
        exportNotice = ExportNotice(
            message: String(localized: "Starts when the current transcription ends."), failures: [], folder: nil, tone: .info
        )
        return true
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
        if takeIsRunning {
            deferredArrivals.append(fileURL)
            noteRunWaitsForTake()
            return
        }
        if batchIsRunning {
            deferredArrivals.append(fileURL)
            return
        }
        leaveFinishedStage()
        if RunLanding.Kind.subtitles.policy.recents { noteRecentFile(fileURL) }
        let imported: Transcript
        do {
            imported = try Self.parseSubtitleFile(at: fileURL)
        } catch {
            phase = .failed(message: String(localized: "Couldn't read \(fileURL.lastPathComponent): \(FailureText.message(for: error))"))
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
        land(RunLanding(kind: .subtitles, transcript: processed, title: fileURL.deletingPathExtension().lastPathComponent))
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
        if takeIsRunning {
            deferredArrivals.append(fileURL)
            noteRunWaitsForTake()
            return
        }
        leaveFinishedStage()
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
        fileURL: URL, translateOverride: Bool?, sourceDigest: String? = nil, fetchedLink: FetchedLink? = nil,
        arrival: WatchedArrival? = nil, windowGeneration: Int? = nil
    ) {
        leaveFailedPhase()
        leaveFinishedStage()
        // Before the new token: cancelling retires the old run's token; a file opened mid-download keeps its duplicate check.
        cancelTranscriptionRuns(keepingDuplicateCheck: fetchedLink != nil)
        // An entry opened since the user started the run, during a download or a duplicate check, keeps the run out of it; another page doesn't, so the run's pane is there when they go back.
        let windowGeneration = windowGeneration ?? loadEntryGeneration
        let startsOutOfSight = loadEntryGeneration != windowGeneration
        let runToken = nextFileRunToken()
        let landingKind: RunLanding.Kind = arrival != nil ? .arrival : fetchedLink == nil ? .file : .link
        if landingKind.policy.recents { noteRecentFile(fileURL) }
        if let fetchedLink, let title = fetchedLink.media.metadata.title {
            linkRunTitle = LinkRunTitle(file: fileURL, title: title)
        }
        if startsOutOfSight {
            leaveRunPhase()
        } else {
            sourceFileURL = fileURL
            installPlayer(for: fileURL)
        }
        let probeSource = FileAudioSource(url: fileURL)
        let deadline = fileReadDeadline
        Task { [weak self] in
            let probe = await BoundedFileRead.run(deadline: deadline) {
                probeSource.synchronousDuration()
            }
            guard let self, self.fileRunGeneration == runToken else { return }
            guard case .done(let duration) = probe else {
                self.failFileReadTimeout(
                    fileURL, runToken: runToken, fetchedLink: fetchedLink, translateOverride: translateOverride, since: windowGeneration
                )
                return
            }
            if !startsOutOfSight, let duration, self.mediaDurationSeconds == nil { self.mediaDurationSeconds = duration }
        }
        filePartialText = ""
        fileTranscribeFraction = nil
        fileTranscribeStage = nil

        let task: TranscriptionTask = (translateOverride ?? translate) ? .translate : .transcribe
        // The lane keeps a watched file across a quit, so its run leaves no checkpoint to offer twice.
        let recoveryToken: Int? = arrival != nil ? nil : fetchedLink.map {
            beginFileTranscribeRecovery(sourceURL: $0.link, title: $0.media.metadata.title, source: .web)
        } ?? beginFileTranscribeRecovery(sourceURL: fileURL)

        fileTranscribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !startsOutOfSight {
                    phase = store.isInstalled(selectedModel)
                        ? .loadingModel(name: selectedModel)
                        : .downloadingModel(name: selectedModel, progress: 0)
                }
                modelResidency.sessionRunBegan()
                defer { modelResidency.sessionRunEnded() }
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
                // Post-processing is a suspension a cancel can land in; a replaced run must not land after it.
                try Task.checkCancellation()
                if let fetchedLink { processed.sourceURL = fetchedLink.media.metadata.webpageURL ?? fetchedLink.link }
                // What the user opened meanwhile, or the page they went to, keeps the window: the run lands out of sight.
                let outOfSight = userMovedOn(from: fileURL, since: windowGeneration)
                if outOfSight, let arrival {
                    filePartialText = ""
                    fileTranscribeFraction = nil
                    fileTranscribeStage = nil
                    leaveRunPhase()
                    letGoOfRunMedia(fileURL)
                    landVisibleArrivalOutOfSight(arrival, processed)
                    retireFileRun(runToken)
                    if !Task.isCancelled { self.fileTranscribeTask = nil }
                    return
                }
                let landing = Self.landingSignposter.beginInterval("install")
                defer { Self.landingSignposter.endInterval("install", landing) }
                if !outOfSight {
                    clearDerivedArtifacts()
                    selectedEntryID = nil
                    restorePlaybackSource(fileURL)
                    transcript = processed
                    adoptLoadedMediaDuration()
                }
                filePartialText = ""
                fileTranscribeFraction = nil
                fileTranscribeStage = nil
                if let recoveryToken { endRecovery(recoveryToken) }
                if outOfSight {
                    leaveRunPhase()
                    letGoOfRunMedia(fileURL)
                } else {
                    phase = .ready
                }
                let ownedDownload = fetchedLink.flatMap { $0.media.workingDirectory == nil ? nil : $0 }
                let linkMetadataTitle = fetchedLink?.media.metadata.title
                let finished = RunLanding(
                    kind: outOfSight ? .backgroundRun : landingKind,
                    transcript: processed,
                    audioSource: fileURL,
                    source: fetchedLink == nil ? .file : .web,
                    title: fetchedLink.map { _ in linkMetadataTitle ?? LibraryEntryDisplay.webVideoTitle(createdAt: Date()) },
                    titleSource: linkMetadataTitle == nil ? nil : .source,
                    sourceDigest: sourceDigest,
                    consumesAudio: ownedDownload != nil
                )
                let entry = land(finished)
                fileRunLanding = FileRunLanding(runToken: runToken, text: processed.text, entry: entry)
                if let ownedDownload { followLinkAudioIntoLibrary(ownedDownload, entry: entry) }
                if let arrival { visibleArrivalLanded(arrival, landing: finished, saving: entry) }
                retireFileRun(runToken)
            } catch {
                if let recoveryToken { endRecovery(recoveryToken) }
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
                    noteFileRunFailure(error, runToken: runToken)
                    // A failure stays out of the way of whatever the user opened while it ran.
                    let outOfSight = userMovedOn(from: fileURL, since: windowGeneration)
                    if outOfSight {
                        leaveRunPhase()
                        letGoOfRunMedia(fileURL)
                        if arrival == nil {
                            reportRunFailure(error, of: fileURL, fetchedLink: fetchedLink, translateOverride: translateOverride)
                        }
                    } else {
                        applyTranscriptionError(
                            error,
                            source: fetchedLink == nil ? fileURL : nil,
                            translateOverride: translateOverride,
                            link: fetchedLink?.retry
                        )
                    }
                    if let arrival { failArrival(arrival, error: error, announces: outOfSight) }
                }
            }
            if !Task.isCancelled { self.fileTranscribeTask = nil }
        }
        if arrival == nil {
            noteRequeue(fetchedLink.map { .link($0.retry) } ?? .file(fileURL, translateOverride: translateOverride), for: fileTranscribeTask)
        }
    }

    /// The user opened an entry while a run was going, or went to another page than the run's.
    private func userMovedOn(since windowGeneration: Int) -> Bool {
        loadEntryGeneration != windowGeneration || route != .transcript
    }

    /// The same for a run over a file, which a document or subtitles opened meanwhile take from it too.
    private func userMovedOn(from fileURL: URL, since windowGeneration: Int) -> Bool {
        userMovedOn(since: windowGeneration) || sourceFileURL != fileURL
    }

    /// A run landing out of sight takes its media out of the player, with whatever transcript it ran over: the two never belonged together.
    private func letGoOfRunMedia(_ fileURL: URL) {
        guard sourceFileURL == fileURL else { return }
        guard transcript != nil else {
            sourceFileURL = nil
            tearDownPlayer()
            return
        }
        closeTranscript()
    }

    /// Hands the phase back only while it still shows the run; a model download from Settings keeps its bar.
    private func leaveRunPhase() {
        switch phase {
        case .downloadingModel where downloadTask != nil: break
        case .loadingModel, .downloadingModel, .transcribing, .fetchingLink: phase = transcript == nil ? .idle : .ready
        default: break
        }
    }

    /// A probe that never came back means the file itself is out of reach, so the run reading the
    /// same bytes is not going to report anything of its own.
    private func failFileReadTimeout(
        _ fileURL: URL, runToken: Int, fetchedLink: FetchedLink?, translateOverride: Bool?, since windowGeneration: Int
    ) {
        guard fileTranscribeTask != nil else { return }
        let error = ParolaError.fileReadTimedOut(name: fileURL.lastPathComponent)
        noteFileRunFailure(error, runToken: runToken)
        let outOfSight = userMovedOn(from: fileURL, since: windowGeneration)
        let arrival = watchedArrivals.first { $0.id == visibleArrivalID }
        if let arrival { failArrival(arrival, error: error, announces: outOfSight) }
        cancelAndTrack(&fileTranscribeTask)
        guard outOfSight else {
            applyTranscriptionError(error, source: fetchedLink == nil ? fileURL : nil, link: fetchedLink?.retry)
            return
        }
        leaveRunPhase()
        letGoOfRunMedia(fileURL)
        // An unreachable file keeps its Retry: asking the volume whether it is there could hang as the read did.
        if arrival == nil { reportRunFailure(error, of: fileURL, fetchedLink: fetchedLink, translateOverride: translateOverride, checksFile: false) }
    }

    /// What the Shortcut waiting on this run hears, wherever the failure itself was shown; a cancel is not a failure.
    private func noteFileRunFailure(_ error: any Error, runToken: Int) {
        guard !(error is CancellationError) else { return }
        fileRunFailure = FileRunFailure(runToken: runToken, message: Self.transcriptionFailureMessage(for: error))
    }

    /// A run that failed after the user moved on leaves their page alone; a notice says so, and stays, with the run's Retry.
    private func reportRunFailure(
        _ error: any Error, of fileURL: URL, fetchedLink: FetchedLink?, translateOverride: Bool?, checksFile: Bool = true
    ) {
        if let fetchedLink {
            reportRunFailure(error, name: fetchedLink.media.metadata.title ?? fetchedLink.link.absoluteString, retry: .link(fetchedLink.retry))
            return
        }
        let exists = !checksFile || FileManager.default.fileExists(atPath: fileURL.path)
        reportRunFailure(error, name: fileURL.lastPathComponent, retry: exists ? .file(fileURL, translateOverride: translateOverride) : nil)
    }

    private func reportRunFailure(_ error: any Error, name: String, retry: RunRetry?) {
        guard !(error is CancellationError) else { return }
        var retry = retry
        if case ParolaError.linkDownloadFailed(let failure) = error {
            noteYtDlp(from: failure)
            if !failure.isWorthRetrying { retry = nil }
        }
        let detail = Self.errorDetail(from: Self.transcriptionFailureMessage(for: error))
        let covered = exportNotice
        exportNotice = ExportNotice(
            message: String(localized: "Couldn't transcribe \(name)") + ". " + detail, failures: [], folder: nil, tone: .failure,
            actions: retry.map { [ExportNotice.Action(title: String(localized: "Retry"), handler: .retryRun($0))] } ?? []
        )
        keepCovered(covered, take: nil)
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

    @MainActor private final class ProgressThrottle {
        var lastPercent = -1
        var lastFraction: Double = 0

        /// The fraction to show for `seconds` of `duration`, never lower than the last; nil while it rounds to the percent already shown.
        func advance(to seconds: Double, of duration: Double) -> Double? {
            guard duration > 0 else { return nil }
            let fraction = min(1, max(lastFraction, seconds / duration))
            let percent = Int(fraction * 100)
            guard percent != lastPercent else { return nil }
            lastPercent = percent
            lastFraction = fraction
            return fraction
        }
    }

    func makeFileProgressHandler(runToken: Int) -> @Sendable (Double) -> Void {
        let coalescer = makeFileProgressCoalescer(runToken: runToken)
        return { coalescer.send($0) }
    }

    func makeFileProgressCoalescer(runToken: Int) -> MainActorCoalescer<Double> {
        let throttle = ProgressThrottle()
        return MainActorCoalescer { [weak self] seconds in
            guard let self, self.fileRunGeneration == runToken, let duration = self.mediaDurationSeconds,
                  let fraction = throttle.advance(to: seconds, of: duration) else { return }
            self.fileTranscribeFraction = fraction
        }
    }

    // MARK: - YouTube URL

    var youtubeSheetOpen: Bool = false
    var linkSheetPrefill: URL?
    /// The clipboard a link sheet opened from a menu looks at; tests hand in a private one.
    @ObservationIgnored var linkPasteboard: NSPasteboard = .general
    var youtubeURLError: String?
    var ytDlpAvailable: Bool = false
    var ytDlpInstalling: Bool = false
    var ytDlpInstallError: String?
    @ObservationIgnored var ytDlpPath: String?
    var ytDlpVersion: YtDlpVersion?
    var ytDlpUpdateRoute: YtDlpUpdateRoute?
    var ytDlpUpdating: Bool = false
    var ytDlpUpdateError: String?
    @ObservationIgnored var ytDlpVersionTask: Task<Void, Never>?
    @ObservationIgnored var ytDlpUpdateTask: Task<Void, Never>?
    @ObservationIgnored var ytDlpUpdateDeadline: Duration = YtDlpInstaller.upgradeDeadline
    @ObservationIgnored var ytDlpLocator: () -> String? = { YtDlpLocator.locate() }
    @ObservationIgnored var brewLocator: () -> String? = { YtDlpLocator.locateBrew() }
    var homebrewAvailable: Bool = true
    @ObservationIgnored var linkFetcher: any LinkFetcher

    var ytDlpIsStale: Bool {
        ytDlpVersion?.isStale(asOf: Date()) ?? false
    }

    /// Every way into the link sheet comes through here: ⌘V's link, else one already on the clipboard, never a stale one.
    func openLinkSheet(prefill: URL?) {
        guard features.isEnabled(.youtube) else { return }
        linkSheetPrefill = prefill ?? PastedLink.url(on: linkPasteboard)
        youtubeSheetOpen = true
    }

    func takeLinkSheetPrefill() -> URL? {
        defer { linkSheetPrefill = nil }
        return linkSheetPrefill
    }

    func refreshYtDlpAvailability() {
        let path = ytDlpLocator()
        ytDlpPath = path
        ytDlpAvailable = path != nil
        if ytDlpAvailable { ytDlpInstallError = nil }
        let route = path.map { YtDlpUpdateRoute(ytDlpPath: $0) }
        if route != ytDlpUpdateRoute { ytDlpUpdateRoute = route }
        if path == nil, ytDlpVersion != nil { ytDlpVersion = nil }
        let brew = path != nil || brewLocator() != nil
        if brew != homebrewAvailable { homebrewAvailable = brew }
    }

    /// Availability plus `yt-dlp --version`, which costs a Python start-up, so only the Links pane asks for it.
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
        guard let brew = YtDlpLocator.locateBrew() else {
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
    enum DeferredLink: Hashable {
        case transcribe(String)
        case subtitles(String)
    }

    /// What Retry runs again for a run that failed after the user moved on: the file, or the link.
    enum RunRetry: Equatable {
        case file(URL, translateOverride: Bool?)
        case link(DeferredLink)

        var name: String {
            switch self {
            case .file(let url, _): url.lastPathComponent
            case .link(.transcribe(let link)), .link(.subtitles(let link)): link
            }
        }
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
        takeIsRunning || transcribeTaskRunning
            || (batchTask != nil && batchJobs.contains { $0.status == .pending || $0.status == .transcribing })
    }

    @discardableResult
    func transcribeYouTube(urlString: String) -> LinkHandoff {
        guard features.isEnabled(.youtube) else {
            phase = .failed(message: FailureText.message(for: ParolaError.featureDisabled(.youtube)))
            return .rejected
        }
        guard let url = makeYouTubeURL(urlString) else { return .rejected }
        if linkArrivalsDeferred {
            deferredLinks.append(.transcribe(url.absoluteString))
            if takeIsRunning { noteRunWaitsForTake() }
            return .parked
        }
        leaveFinishedStage()

        cancelTranscriptionRuns()
        let windowGeneration = loadEntryGeneration
        let runToken = nextFileRunToken()
        let recoveryToken = beginFileTranscribeRecovery(sourceURL: url, source: .web)
        let fetcher = linkFetcher
        let progress = makeLinkFetchHandler(runToken: runToken)
        leaveFailedPhase()
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
                    fileURL: media.fileURL, translateOverride: nil, fetchedLink: FetchedLink(link: url, media: media),
                    windowGeneration: windowGeneration
                )
            } catch {
                guard let self else { return }
                self.endRecovery(recoveryToken)
                self.retireFileRun(runToken)
                guard !Task.isCancelled else { return }
                if self.userMovedOn(since: windowGeneration) {
                    self.leaveRunPhase()
                    self.reportRunFailure(error, name: url.absoluteString, retry: .link(.transcribe(url.absoluteString)))
                } else {
                    self.applyTranscriptionError(error, link: .transcribe(url.absoluteString))
                }
                self.youtubeTranscribeTask = nil
            }
        }
        noteRequeue(.link(.transcribe(url.absoluteString)), for: youtubeTranscribeTask)
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
            phase = .failed(message: FailureText.message(for: ParolaError.featureDisabled(.youtube)))
            return .rejected
        }
        guard let url = makeYouTubeURL(urlString) else { return .rejected }
        if linkArrivalsDeferred {
            deferredLinks.append(.subtitles(url.absoluteString))
            if takeIsRunning { noteRunWaitsForTake() }
            return .parked
        }
        leaveFinishedStage()

        cancelTranscriptionRuns()
        let fetcher = linkFetcher
        let windowGeneration = loadEntryGeneration
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
                let outOfSight = userMovedOn(since: windowGeneration)
                if outOfSight {
                    leaveRunPhase()
                } else {
                    installFetchedSubtitles(processed)
                    phase = .ready
                }
                land(RunLanding(
                    kind: outOfSight ? .backgroundRun : .captions,
                    transcript: processed,
                    source: .web,
                    title: result.videoTitle ?? LibraryEntryDisplay.webVideoTitle(createdAt: Date()),
                    titleSource: result.videoTitle == nil ? nil : .source
                ))
            } catch {
                if !Task.isCancelled {
                    if userMovedOn(since: windowGeneration) {
                        leaveRunPhase()
                        reportRunFailure(error, name: url.absoluteString, retry: .link(.subtitles(url.absoluteString)))
                    } else {
                        applyTranscriptionError(error, link: .subtitles(url.absoluteString))
                    }
                }
            }
            if !Task.isCancelled { self.youtubeSubsTask = nil }
        }
        noteRequeue(.link(.subtitles(url.absoluteString)), for: youtubeSubsTask)
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
        if error is CancellationError {
            return String(localized: "Transcription stopped.", bundle: bundle)
        }
        if let offline = offlineMessage(for: error, bundle: bundle) { return offline }
        return FailureText.message(for: error, bundle: bundle)
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

    nonisolated static func downloadFailureMessage(for error: Error, bundle: Bundle = .main) -> String {
        if case ParolaError.modelDownloadFailed = error { return FailureText.message(for: error, bundle: bundle) }
        return String(localized: "Download failed: \(FailureText.message(for: error, bundle: bundle))", bundle: bundle)
    }

    nonisolated static func unsupportedURLMessage(bundle: Bundle = .main) -> String {
        String(localized: "That URL isn't on a host yt-dlp can fetch.", bundle: bundle)
    }

    nonisolated static func exportFailureMessage(for error: Error, bundle: Bundle = .main) -> String {
        String(localized: "Export failed: \(FailureText.message(for: error, bundle: bundle))", bundle: bundle)
    }

    nonisolated static func recordingFailureMessage(
        for error: Error,
        source: RecordSource,
        screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess(),
        hasCaptureTargets: Bool = false,
        bundle: Bundle = .main
    ) -> String {
        switch missingPermission(
            for: error, source: source, screenRecordingGranted: screenRecordingGranted, hasCaptureTargets: hasCaptureTargets
        ) {
        case .screenRecording:
            return String(
                localized: "Parola needs Screen & System Audio Recording permission to capture system audio. Open System Settings → Privacy & Security → Screen & System Audio Recording and allow Parola, then start recording again.",
                bundle: bundle
            )
        case .systemAudioRecording:
            return SystemAudioDidNotStart.message(bundle: bundle)
        case .microphone, nil:
            return transcriptionFailureMessage(for: error, bundle: bundle)
        }
    }

    /// On screen, on the Space in front, and not covered completely: a count-in anywhere else would delay the take unseen.
    private var mainWindowShowsOverlay: Bool {
        guard mainWindowPresence == .onScreen else { return false }
        guard mode != .test, let mainWindow else { return true }
        return mainWindow.isOnActiveSpace && mainWindow.occlusionState.contains(.visible)
    }

    nonisolated static func missingPermission(
        for error: Error, source: RecordSource, screenRecordingGranted: Bool, hasCaptureTargets: Bool = false
    ) -> RecordingSession.Permission? {
        guard source == .systemAudio else { return nil }
        if error is SystemAudioDidNotStart { return .systemAudioRecording }
        guard case ParolaError.captureUnavailable = error else { return nil }
        if hasCaptureTargets { return .systemAudioRecording }
        return screenRecordingGranted ? nil : .screenRecording
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
        showsAITitle: Bool,
        fallback: String,
        entryIsTheTranscript: Bool = false
    ) -> String {
        if let entry, entryIsTheTranscript || sourceBelongsToEntry(sourceFileURL, bundleURL: entry.bundleURL) {
            return LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showsAITitle)
        }
        if let sourceFileURL {
            return sourceFileURL.deletingPathExtension().lastPathComponent
        }
        return entry.map { LibraryEntryDisplay.listTitle(for: $0, showsAITitle: showsAITitle) } ?? fallback
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
        let needed = source.feature
        guard features.isEnabled(needed) else {
            forgetTakeRequest()
            phase = .failed(message: FailureText.message(for: ParolaError.featureDisabled(needed)))
            return
        }
        guard !recordingActive else {
            forgetTakeRequest()
            return
        }
        // A quit is winding the takes down; a new one would only be cut off.
        guard !quitPending else {
            forgetTakeRequest()
            refusalBeep?()
            return
        }
        meetingDetectedApp = nil
        let diskCheck = startDiskSpaceCheck()
        let countIn = max(0, recordingCountInSeconds)
        // The count-in shows only in a main window Parola has in front; anywhere else it would delay the take unseen.
        let overlayVisible = appIsActive() && mainWindowShowsOverlay
        let request = TakeRequest(
            category: requestedCategory(for: source),
            captureTargets: pendingCaptureBundleIDs ?? [],
            sourceAppBundleID: sourceAppBundleID(for: source)
        )
        forgetTakeRequest()
        if countIn > 0, overlayVisible {
            beginCountIn(seconds: countIn, source: source, category: request.category) { [weak self] showsStage, counted in
                self?.beginRecordingNow(source: source, request: request, diskCheck: diskCheck, showsStage: showsStage, countIn: counted)
            }
            refuseDuringCountIn(diskCheck)
        } else {
            beginRecordingNow(source: source, request: request, diskCheck: diskCheck)
        }
    }

    /// What Record asked for, kept from the moment it was pressed, so nothing asked during a count-in reaches this take.
    private struct TakeRequest {
        let category: EntryCategory
        let captureTargets: Set<String>
        let sourceAppBundleID: String?
    }

    /// The app a system-audio take is from: the meeting's own, or the one app its capture is limited to.
    private func sourceAppBundleID(for source: RecordSource) -> String? {
        guard source == .systemAudio else { return nil }
        if let pendingSourceAppBundleID { return pendingSourceAppBundleID }
        guard let targets = pendingCaptureBundleIDs, targets.count == 1 else { return nil }
        return targets.first
    }

    /// A meeting's category and app targets belong to the request that set them, not to whatever take comes next.
    private func forgetTakeRequest() {
        pendingRecordingCategory = nil
        pendingCaptureBundleIDs = nil
        pendingSourceAppBundleID = nil
    }

    /// The category a take from `source` starts in: the one its Record asked for, or its source's own.
    private func requestedCategory(for source: RecordSource) -> EntryCategory {
        pendingRecordingCategory ?? Self.defaultCategory(for: source)
    }

    /// The count-in is the take's first arming, under the id the take will get.
    /// `then` learns whether the Stage is still up, so someone who left it during the count-in keeps their page, and what the count-in's session holds for the take.
    private func beginCountIn(
        seconds: Int, source: RecordSource, category: EntryCategory,
        then: @escaping (_ showsStage: Bool, _ countIn: RecordingSession?) -> Void
    ) {
        countdownTask?.cancel()
        let takeID = takeCounter &+ 1
        let stamp = Date()
        beginSession(RecordingSession(
            takeID: takeID,
            source: source,
            category: category,
            title: Self.liveRecordingTitle(category: category, endedAt: stamp),
            isStreaming: predictsLiveTake(source),
            arming: .countIn(remaining: seconds),
            titleDate: stamp
        ))
        showStage()
        let clock = clock
        countdownTask = Task { @MainActor [weak self] in
            for value in stride(from: seconds, to: 0, by: -1) {
                guard !Task.isCancelled else { return }
                self?.updateSession(of: takeID) { $0.arm(.countIn(remaining: value)) }
                try? await Task.sleep(for: .seconds(1), clock: clock)
            }
            guard !Task.isCancelled else { return }
            let showsStage = self?.route == .recording
            let countIn = self?.recording.flatMap { $0.takeID == takeID ? $0 : nil }
            self?.endCountIn()
            then(showsStage, countIn)
        }
    }

    /// A count-in holds the id its take would get; ending it spends the id, as `failCountIn` does, so no later take answers to it.
    func cancelRecordingCountdown() {
        if recordingCountdown != nil { takeCounter &+= 1 }
        countdownTask?.cancel()
        countdownTask = nil
        endCountIn()
        forgetTakeRequest()
    }

    /// Changes the saved microphone, as Settings does, while a take still counting in has yet to open it; false once the take may have opened one.
    @discardableResult
    func chooseTakeInput(_ uid: String) -> Bool {
        guard recording?.isCountingIn == true else { return false }
        inputDeviceUID = uid
        return true
    }

    /// A count-in refused before its take began ends there, with the reason; its failed Stage keeps the id, so the next take gets its own.
    func failCountIn(_ message: String) {
        if recordingCountdown != nil {
            reportTakeFailure(message, take: recording?.takeID)
            takeCounter &+= 1
        }
        cancelRecordingCountdown()
    }

    private func endCountIn() {
        guard recordingCountdown != nil else { return }
        endSession(of: recording?.takeID)
    }

    private func beginSession(_ session: RecordingSession) {
        takeLevels = TakeLevelHistory()
        takeMicLevels = nil
        if takeMicTrackState != nil { takeMicTrackState = nil }
        if takeMacAudioStopped { takeMacAudioStopped = false }
        if takeStopReason != nil { takeStopReason = nil }
        recording = session
    }

    /// A take that ended without anything to show, like a cancel, leaves no session behind.
    private func endSession(of takeID: Int?) {
        guard let takeID, recording?.takeID == takeID else { return }
        recording = nil
        takeLevels = nil
        takeMicLevels = nil
        if takeMicTrackState != nil { takeMicTrackState = nil }
        if takeMacAudioStopped { takeMacAudioStopped = false }
        if takeStopReason != nil { takeStopReason = nil }
    }

    /// Changes `takeID`'s session only; one a newer take owns by now is left alone.
    func updateSession(of takeID: Int?, _ change: (inout RecordingSession) -> Void) {
        guard let takeID, var session = recording, session.takeID == takeID else { return }
        change(&session)
        if session != recording { recording = session }
    }

    #if DEBUG
    /// Test seam: a take already capturing since `startedAt`; with no source it is a live take whose events the test sends.
    func installTestTake(source: RecordSource, liveSource: AudioSource? = nil, startedAt: Date = Date()) {
        takeCounter &+= 1
        var take = TakeContext(id: takeCounter, source: source, category: requestedCategory(for: source), captureTargets: [])
        take.captureRequested = true
        forgetTakeRequest()
        activeTake = take
        pendingRecordingSource = source.entrySource
        self.liveSource = liveSource
        var session = RecordingSession(
            takeID: take.id,
            source: source,
            category: take.category,
            title: Self.liveRecordingTitle(category: take.category, endedAt: startedAt),
            isStreaming: liveSource == nil,
            arming: .startingCapture,
            titleDate: startedAt
        )
        session.markCapturing(at: startedAt)
        beginSession(session)
        showStage()
    }

    /// Test seam: the installed take ends the way a cancel ends one, leaving nothing behind.
    func endTestTake() {
        liveSource = nil
        activeTake = nil
        endSession(of: recording?.takeID)
    }
    #endif

    /// The streaming mic path drives WhisperKit off the live mic and never consults
    /// MockAudioSourceRegistry. With a mic fixture installed (test-mode) we must avoid it and take the
    /// file-capture path instead, so the fixture transcribes the same way system audio does.
    /// Non-WhisperKit engines can't stream either — those record the take first, then transcribe.
    func shouldUseStreamingMic() async -> Bool {
        guard streamsMicTakes else { return false }
        return await MockAudioSourceRegistry.shared.resolve(for: .mic) == nil
    }

    /// What a take from `source` shows from Record on: a mic take streams when the setting and the model allow it; the start corrects it if it records to its file after all.
    private func predictsLiveTake(_ source: RecordSource) -> Bool {
        source == .microphone && streamsMicTakes
    }

    private var streamsMicTakes: Bool {
        useStreaming && ModelCatalog.canStream(id: selectedModel)
    }

    /// A take from its count-in until its capture has wound down: arming, recording, paused or finishing.
    var takeIsRunning: Bool { recording?.isRunning ?? false }

    /// The take's page; false, and nothing changes, without a take to show on it.
    @discardableResult
    func showStage() -> Bool {
        guard stageHoldsTake else { return false }
        route = .recording
        return true
    }

    private func refreshStageHoldsTake() {
        let holds = recording.map { ContentRoutes.stageShows($0, model: self) } ?? false
        guard holds != stageHoldsTake else { return }
        stageHoldsTake = holds
        // Once the Stage lets go of its take, to new work say, the window shows the transcript page, and the route says so.
        if !holds, route == .recording { route = .transcript }
        holdSavedToastBehindStage()
    }

    /// New work shows on the transcript page, so a Stage whose take is over gives way to it; a landed take never holds the Stage.
    func leaveFinishedStage() {
        guard route == .recording, recording?.isOver ?? true else { return }
        route = .transcript
    }

    /// Whatever take the session still holds, failed or landed, goes with it; a reset starts from the library.
    func forgetTakeSession() {
        endSession(of: recording?.takeID)
    }

    /// The Stage is what the user comes back to: its route is up in a main window that is still open, even minimized or hidden.
    var stageIsVisible: Bool {
        route == .recording && mainWindowPresence != .closed
    }

    /// The Stage is up with this take on it; a newer take's Stage is not this one's.
    func stageShows(_ takeID: Int) -> Bool {
        stageIsVisible && recording?.takeID == takeID
    }

    /// A take's failure shows on its Stage, and in a notice when the Stage isn't on screen; with no take to hold it, the page's banner says it.
    private func reportTakeFailure(
        _ message: String, take takeID: Int?, retry: RecordingSession.Failure? = nil, permission: RecordingSession.Permission? = nil
    ) {
        guard let takeID else {
            phase = .failed(message: message)
            if let retry { armTakeRetry(retry) }
            return
        }
        guard recording?.takeID == takeID else {
            reportReplacedTakeFailure(message, retry: retry)
            return
        }
        var failed = false
        updateSession(of: takeID) { session in
            session.fail(message)
            guard case .failed = session.state else { return }
            session.failure = retry
            session.missingPermission = permission
            failed = true
        }
        guard failed, !stageShows(takeID) else { return }
        var actions = [ExportNotice.Action(title: String(localized: "Show"), handler: .showTake(takeID))]
        if retry != nil {
            actions.insert(ExportNotice.Action(title: String(localized: "Retry"), handler: .retryTake(takeID)), at: 0)
        }
        exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .failure, actions: actions)
    }

    /// A take whose session a newer take has taken over has no Stage to fail on, so its notice carries what its failure saved.
    private func reportReplacedTakeFailure(_ message: String, retry: RecordingSession.Failure?) {
        let actions = retry.map {
            [
                ExportNotice.Action(title: String(localized: "Retry"), handler: .retrySavedTake($0)),
                ExportNotice.Action(title: String(localized: "Show"), handler: .showSavedTake($0)),
            ]
        } ?? []
        exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .failure, actions: actions)
    }

    /// A run asked for while a take records waits for it, or is turned away; either way the user hears why.
    func noteRunWaitsForTake() {
        // One with buttons, like a saved take's Open and Transcribe, or a failure still to be read, is worth more than this.
        guard exportNotice.map({ $0.actions.isEmpty && $0.tone != .failure }) ?? true else { return }
        exportNotice = ExportNotice(
            message: String(localized: "Finish the recording first."), failures: [], folder: nil, tone: .info, whileTakeRuns: true
        )
    }

    /// True from the moment a take is requested until its capture is torn down; the guard in
    /// `startRecording` uses it so a second trigger (menu bar, intent, meeting banner) can't
    /// silently discard the running take and leak its capture.
    var recordingActive: Bool {
        takeIsRunning || recordingStartInFlight || liveSource != nil || streamingSession != nil
    }

    /// What Record and File ▸ New Recording ask before they offer a take from `source`.
    func canStartTake(_ source: RecordSource) -> Bool {
        features.isEnabled(source.feature) && !recordingActive && !quitPending
    }

    /// Whether `take` still owns the recording state; a start or a stream that outlived its take leaves the next one alone.
    func takeIsCurrent(_ take: TakeContext) -> Bool {
        activeTake?.id == take.id
    }

    /// `countIn` is the session the take counted in under: its name, typed or generated, and its Note or Meeting are the take's.
    private func beginRecordingNow(
        source: RecordSource, request: TakeRequest, diskCheck: Task<Int64?, Never>, showsStage: Bool = true,
        countIn: RecordingSession? = nil
    ) {
        // A count-in that ends after a quit began would start a take the quit can only cut off.
        guard !quitPending else {
            resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: countIn?.takeID)
            return
        }
        takeCounter &+= 1
        let take = TakeContext(
            id: takeCounter,
            source: source,
            category: countIn?.category ?? request.category,
            captureTargets: request.captureTargets,
            sourceAppBundleID: request.sourceAppBundleID,
            askedForMeeting: request.category == .meeting
        )
        activeTake = take
        // Words an earlier live take left behind would otherwise go into this take's checkpoint.
        liveSegments = []
        livePartialText = ""
        let stamp = countIn?.titleDate ?? Date()
        var session = RecordingSession(
            takeID: take.id,
            source: source,
            category: take.category,
            title: Self.liveRecordingTitle(category: take.category, endedAt: stamp),
            isStreaming: predictsLiveTake(source),
            arming: .startingCapture,
            titleDate: stamp
        )
        if let countIn, countIn.titleSource == .user { session.rename(countIn.title) }
        session.sourceAppBundleID = take.sourceAppBundleID
        beginSession(session)
        if showsStage { showStage() }
        if source == .microphone { nameTakeDevice(take) }
        pendingRecordingSource = source.entrySource
        let config = recordingMediaConfig(for: source)
        recordingStartInFlight = true
        stopRequestedDuringStart = false
        Task {
            defer {
                if activeTake == nil || takeIsCurrent(take) {
                    recordingStartInFlight = false
                    stopRequestedDuringStart = false
                }
            }
            // Before anything is cancelled: a take refused for space leaves what was running alone.
            guard await passesPreRecordingDiskCheck(diskCheck) else {
                if takeIsCurrent(take) { activeTake = nil }
                reportTakeFailure(Self.diskSpaceRefusalMessage(), take: take.id)
                resolveRecordingOutcome(.failure(IntentActionError.failed(Self.diskSpaceRefusalMessage())), take: take.id)
                return
            }
            guard takeIsCurrent(take) else { return }
            guard !stopRequestedDuringStart else {
                activeTake = nil
                endSession(of: take.id)
                resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: take.id)
                return
            }
            // A recording replaces any transcription in flight, like a user file-open does;
            // otherwise the old run would finish later and stomp the new take's transcript.
            requeueRunsForTake()
            cancelTranscriptionRuns()
            leaveRunPhase()
            if source == .microphone, mode == .normal, await AVCaptureDevice.requestAccess(for: .audio) == false {
                guard takeIsCurrent(take) else { return }
                ParolaLog.notice(.appPermissions, "microphone access request was denied")
                activeTake = nil
                let message = Self.microphoneAccessOffMessage()
                reportTakeFailure(message, take: take.id, permission: .microphone)
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take.id)
                return
            }
            guard takeIsCurrent(take) else { return }
            if source == .microphone, await shouldUseStreamingMic() {
                guard takeIsCurrent(take) else { return }
                // The streaming path never reaches adoptLiveSource, so it has to honour the stop itself.
                guard !stopRequestedDuringStart else {
                    activeTake = nil
                    endSession(of: take.id)
                    resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: take.id)
                    return
                }
                startStreamingMic(take)
                return
            }
            await mediaSession.enterRecording(config: config, holder: .take)
            guard takeIsCurrent(take) else { return }
            var tapsApps = false
            do {
                beginTakeArming(.startingCapture, take: take, streaming: false)
                activeTake?.captureRequested = true
                switch source {
                case .microphone:
                    let mic = await makeTakeCapture(.microphone, take: take)
                    try await mic.start()
                    guard await adoptLiveSource(mic, take: take) else { return }
                case .systemAudio:
                    let sys = await makeTakeCapture(.systemAudio, take: take)
                    tapsApps = sys is ProcessTapAudioSource
                    await sys.whenCaptureEnds(macCaptureEndHandler(take: take.id))
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
                        throw SystemAudioDidNotStart()
                    }
                    guard await adoptLiveSource(sys, take: take) else { return }
                    startMicTrack(for: activeTake ?? take, pairedWith: liveRecordingAudioURL)
                }
                startRecordingWatch(checkpoints: false)
            } catch {
                // A take that already ended in the pane has nobody left to tell.
                guard takeIsCurrent(take) else { return }
                await mediaSession.exitRecording(holder: .take)
                guard takeIsCurrent(take) else { return }
                stopRecordingWatch()
                clearTakeReadouts(of: take.id)
                activeTake = nil
                let screenRecordingGranted = screenRecordingCheck()
                let hasCaptureTargets = tapsApps
                let message = Self.recordingFailureMessage(
                    for: error, source: source, screenRecordingGranted: screenRecordingGranted, hasCaptureTargets: hasCaptureTargets
                )
                let permission = Self.missingPermission(
                    for: error, source: source, screenRecordingGranted: screenRecordingGranted, hasCaptureTargets: hasCaptureTargets
                )
                reportTakeFailure(message, take: take.id, permission: permission)
                recordingStartInFlight = false
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take.id)
            }
        }
    }

    /// Drops a capture that came up after its take ended: after the user's Stop, or after a Cancel while it started.
    private func adoptLiveSource(_ source: any LiveAudioSource, take: TakeContext) async -> Bool {
        guard takeIsCurrent(take) else {
            await source.cancel()
            return false
        }
        guard !stopRequestedDuringStart else { return await dropCaptureStoppedDuringStart(source, take: take) }
        liveSource = source
        showTakeLevels(source.levelMeter, take: take)
        takeCaptureCameUp(take)
        let inFlight = await source.inFlightURL()
        // A Discard during that read holds its stop for this start, as a Cancel before capture does.
        if takeIsCurrent(take), stopRequestedDuringStart { return await dropCaptureStoppedDuringStart(source, take: take) }
        // A stop or a cancel that landed during that read owns the take now.
        guard takeIsCurrent(take), liveSource != nil else { return false }
        // One audio-only checkpoint per take: a crash mid-recording leaves a
        // pointer to the in-flight file instead of losing the take outright.
        liveRecordingAudioURL = inFlight
        updateSession(of: take.id) { $0.audioURL = inFlight }
        if liveRecordingAudioURL != nil {
            activeTake?.recovery = beginRecordingRecovery()
            activeTake?.recoveryStartedAt = recordingRecoveryStartedAt
            writeRecordingCheckpoint()
        }
        return true
    }

    private func dropCaptureStoppedDuringStart(_ source: any LiveAudioSource, take: TakeContext) async -> Bool {
        clearTakeReadouts(of: take.id)
        endSession(of: take.id)
        stopRecordingWatch()
        await source.cancel()
        await mediaSession.exitRecording(holder: .take)
        guard takeIsCurrent(take) else { return false }
        activeTake = nil
        recordingStartInFlight = false
        resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: take.id)
        return false
    }

    private func scheduleRecordingAutoStop(for take: TakeContext) {
        cancelRecordingAutoStop()
        let limit = recordingMaxMinutes
        guard limit > 0 else { return }
        recordingAutoStop = AutoStopBudget(takeID: take.id, remaining: .seconds(limit * 60))
        runRecordingAutoStop()
    }

    /// Sleeps what is left of the take's limit on the model's clock, then stops the take; the time run is measured on the continuous clock.
    private func runRecordingAutoStop() {
        guard var budget = recordingAutoStop, budget.runningSince == nil else { return }
        budget.runningSince = .now
        recordingAutoStop = budget
        let clock = clock
        recordingAutoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: budget.remaining, clock: clock)
            guard !Task.isCancelled, let self else { return }
            guard self.takeIsRunning, self.activeTake?.id == budget.takeID else { return }
            self.stopRecordingAndTranscribe()
        }
    }

    /// A paused take keeps what is left of its limit for when it resumes.
    private func holdRecordingAutoStop() {
        recordingAutoStopTask?.cancel()
        recordingAutoStopTask = nil
        guard var budget = recordingAutoStop, let since = budget.runningSince else { return }
        budget.remaining = max(.zero, budget.remaining - since.duration(to: .now))
        budget.runningSince = nil
        recordingAutoStop = budget
    }

    private func cancelRecordingAutoStop() {
        recordingAutoStopTask?.cancel()
        recordingAutoStopTask = nil
        recordingAutoStop = nil
    }

    private func makeTakeCapture(_ source: RecordSource, take: TakeContext) async -> any LiveAudioSource {
        if let takeCaptureOverride { return takeCaptureOverride(source) }
        switch source {
        case .microphone:
            return await LiveAudioSourceFactory.makeMicrophone(deviceUID: preferredInputDeviceUID, clock: clock)
        case .systemAudio:
            return await LiveAudioSourceFactory.makeSystem(targetBundleIDs: take.captureTargets, clock: clock)
        }
    }

    private func showTakeLevels(_ meter: LevelMeter, take: TakeContext) {
        takeReadoutsOwner = take.id
        recordingLevelTrace = LevelTrace(capacity: Self.takeLevelHistoryCapacity)
        recordingLevelMeter = meter
        startTakeSampler(meter: meter, take: take)
    }

    private func beginTakeArming(_ arming: RecordingSession.Arming, take: TakeContext, streaming: Bool) {
        updateSession(of: take.id) { session in
            session.isStreaming = streaming
            session.arm(arming)
        }
    }

    /// The take's capture is up: its silence watch and auto-stop run from here, heard or not.
    private func takeCaptureCameUp(_ take: TakeContext) {
        captureStart = CaptureStart(takeID: take.id, at: .now)
        startSilenceWatch()
        scheduleRecordingAutoStop(for: take)
    }

    /// The take's first audio, so its clock starts there rather than when Record was pressed.
    private func markTakeCapturing(_ take: TakeContext?, at date: Date = Date()) {
        guard let take, takeIsCurrent(take), recording?.takeID == take.id, recording?.isArming == true else { return }
        updateSession(of: take.id) { $0.markCapturing(at: date) }
        // A live take has no capture-up of its own: its first audio is that moment too.
        if captureStart?.takeID != take.id { takeCaptureCameUp(take) }
        checkpointStreamingAudio(of: take)
    }

    /// A live take's file exists from its first buffer, however long its model still compiles, so a crash then keeps the audio.
    private func checkpointStreamingAudio(of take: TakeContext) {
        guard let session = streamingSession, liveRecordingAudioURL == nil else { return }
        Task { @MainActor [weak self] in
            guard let audio = await session.recordingAudioURL() else { return }
            guard let self, self.takeIsCurrent(take), self.liveRecordingAudioURL == nil else { return }
            self.liveRecordingAudioURL = audio
            self.updateSession(of: take.id) { $0.audioURL = audio }
            self.writeRecordingCheckpoint()
        }
    }

    /// A buffer that came in since the sampler last looked still counts, so a Stop right after it keeps the take.
    private func catchUpFirstBuffer() {
        guard recording?.isArming == true, let first = recordingLevelMeter?.firstReadingAt else { return }
        markTakeCapturing(activeTake, at: Self.date(of: first))
    }

    /// The take's capture came up but hasn't metered a buffer yet.
    private var takeIsUnheard: Bool {
        guard let take = activeTake, recording?.takeID == take.id, recording?.isArming == true else { return false }
        return captureStart?.takeID == take.id
    }

    /// Stops the take's clock; one that came up but was never heard counts from when its capture came up.
    private func finishSession(of take: TakeContext?) {
        let captureUp = captureStart.flatMap { $0.takeID == take?.id ? Self.date(of: $0.at) : nil }
        updateSession(of: take?.id) { session in
            if session.isArming, let captureUp { session.markCapturing(at: captureUp) }
            session.finish(at: Date())
        }
    }

    private func clearTakeReadouts() {
        takeReadoutsOwner = nil
        stopTakeSampler()
        if takeClockSeconds != 0 { takeClockSeconds = 0 }
        if recordingLevelMeter != nil { recordingLevelMeter = nil }
        recordingLevelTrace = nil
    }

    /// A take's own readouts only: a clear that lands after the next take showed its levels leaves them alone.
    private func clearTakeReadouts(of takeID: Int?) {
        guard takeReadoutsOwner == takeID else { return }
        clearTakeReadouts()
    }

    /// The one reader of the take's meter peak, which every read resets; the first buffer it finds starts the take's clock. Its tick is the take's one timer: the clock's seconds and the silence watch run on it too.
    private func startTakeSampler(meter: LevelMeter, take: TakeContext) {
        stopTakeSampler()
        takeSampler = Task { @MainActor [weak self] in
            var tick = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleTake(meter, take: take)
                self.watchSilence()
                tick = Self.nextSampleTick(after: tick, now: .now, takeElapsed: self.runningClockElapsed(of: take))
                try? await Task.sleep(until: tick, tolerance: Self.takeSampleTolerance, clock: .continuous)
            }
        }
    }

    /// Ten a second on average, whatever a tick costs; a stall longer than a second is skipped rather than replayed. While the take's clock runs, a tick lands just past each step of it, so one sees each of its seconds turn over.
    nonisolated static func nextSampleTick(
        after tick: ContinuousClock.Instant, now: ContinuousClock.Instant, takeElapsed elapsed: TimeInterval? = nil
    ) -> ContinuousClock.Instant {
        guard let elapsed else {
            let next = tick + takeSampleInterval
            return next < now - .seconds(1) ? now : next
        }
        let step = takeSampleInterval / .seconds(1), lag = takeClockLag / .seconds(1)
        let target = ((elapsed - lag) / step).rounded(.down) * step + step + lag
        return now + .seconds(max(target - elapsed, 0.000_1))
    }

    private func runningClockElapsed(of take: TakeContext) -> TimeInterval? {
        guard let session = recording, session.takeID == take.id, session.state == .recording else { return nil }
        return session.elapsed(at: Date())
    }

    private func stopTakeSampler() {
        takeSampler?.cancel()
        takeSampler = nil
    }

    private func sampleTake(_ meter: LevelMeter, take: TakeContext) {
        if recording?.isArming == true {
            if let first = meter.firstReadingAt {
                markTakeCapturing(take, at: Self.date(of: first))
            } else if let start = captureStart, start.takeID == take.id, start.at.duration(to: .now) >= Self.firstBufferWait {
                markTakeCapturing(take, at: Self.date(of: start.at))
            }
        }
        // Read even while nothing is kept, so a peak from before a pause or a silence never lands after it.
        let peak = meter.takePeak()
        let micPeak = sampleMicTrack(macMeter: meter, take: take)
        recordingLevelTrace?.note(peak, lastSound: meter.lastSound)
        guard let session = recording, session.takeID == take.id, session.state == .recording else { return }
        takeLevels?.append(peak)
        takeMicLevels?.append(micPeak ?? 0)
        takeLevelTick &+= 1
        takeLevelTickAt = Date()
        let seconds = Int(session.elapsed(at: takeLevelTickAt))
        if takeClockSeconds != seconds { takeClockSeconds = seconds }
    }

    /// When to read the take's clock for display; `following` ties the reader, inside an observation, to the clock's seconds, so it reads again as each turns over.
    func takeClockNow(following: Bool) -> Date {
        if following { _ = takeClockSeconds }
        return Date()
    }

    /// The wall-clock moment a meter reading came in.
    static func date(of instant: ContinuousClock.Instant) -> Date {
        let ago = instant.duration(to: .now).components
        return Date(timeIntervalSinceNow: -(Double(ago.seconds) + Double(ago.attoseconds) / 1e18))
    }

    /// Names the input a mic take listens on; listing devices asks CoreAudio, so it runs off the main thread.
    private func nameTakeDevice(_ take: TakeContext) {
        let uid = preferredInputDeviceUID
        let lookup = takeInputNameLookup
        Task { [weak self] in
            let name = await Self.askCoreAudio { lookup(uid) }
            self?.updateSession(of: take.id) { $0.device = name }
        }
    }

    /// A live take is over: its clock, meter, watches and checkpoint stop, unless a newer take owns them by now.
    private func endLiveTake(_ take: TakeContext?) {
        if let take, let active = activeTake, active.id != take.id { return }
        cancelRecordingAutoStop()
        if let take { clearTakeReadouts(of: take.id) } else { clearTakeReadouts() }
        stopSilenceWatch()
        stopRecordingWatch()
        if let recovery = recoveryGeneration(of: take ?? activeTake) { endRecovery(recovery) }
        liveRecordingAudioURL = nil
        activeTake = nil
    }

    /// A take's own checkpoint; with no take, as in a test driving the events directly, whichever run is active.
    func recoveryGeneration(of take: TakeContext?) -> Int? {
        guard let take else { return activeRecoveryGeneration }
        return take.recovery
    }

    private func updateSilenceFlag() {
        let alert = silenceDetector.shouldAlert()
        if recordingIsSilent != alert { recordingIsSilent = alert }
    }

    /// Reads the meter rather than a voice detector, so every source warns off the same signal: mic or Mac audio, live or not.
    private func startSilenceWatch() {
        stopSilenceWatch()
        watchesSilence = true
    }

    private func watchSilence() {
        guard watchesSilence else { return }
        silenceTicks += 1
        if silenceTicks.isMultiple(of: Self.silenceCheckTicks) { noteRecordingLevel() }
    }

    private func noteRecordingLevel() {
        let lastSound = Self.latestSound(recordingLevelMeter?.lastSound, micTrackLastSound)
        let heard = lastSound.map { $0.duration(to: .now) < .seconds(1) } ?? false
        // Mac audio has pauses a mic take doesn't: it warns early only if it has heard nothing yet.
        if activeTake?.source == .systemAudio {
            silenceDetector.threshold = lastSound == nil ? silenceRule.macAudioBeforeSound : silenceRule.macAudioAfterSound
        } else {
            silenceDetector.threshold = silenceRule.microphone
        }
        silenceDetector.note(active: heard)
        updateSilenceFlag()
    }

    private func stopSilenceWatch() {
        watchesSilence = false
        silenceTicks = 0
        silenceDetector.reset()
        recordingIsSilent = false
    }

    private func startStreamingMic(_ take: TakeContext) {
        // The active copy, which holds a category chosen since Record.
        var take = activeTake ?? take
        streamingConsumer?.cancel()
        let modelName = selectedModel
        let s = StreamingTranscriberFactory.make(clock: clock, deviceUID: preferredInputDeviceUID, persistAudio: true)
        streamingSession = s
        showTakeLevels(s.levelMeter, take: take)
        liveSegments = []
        livePartialText = ""
        liveVoiceActive = false
        beginTakeArming(.preparingModel(name: modelName, download: nil), take: take, streaming: true)
        take.captureRequested = true
        take.recovery = beginRecordingRecovery()
        take.recoveryStartedAt = recordingRecoveryStartedAt
        activeTake = take
        startRecordingWatch(checkpoints: true)

        let opts = currentOptions
        let progress = makeTakeDownloadProgressHandler(for: modelName, take: take.id)
        let config = mediaSessionConfig(allowMute: true)

        streamingConsumer = Task { @MainActor in
            guard takeIsCurrent(take) else { return }
            await mediaSession.enterRecording(config: config, holder: .take)
            await runStreamingTake(s, take: take, options: opts, downloadProgress: progress)
            // A take that started since owns the media session now.
            if activeTake == nil || takeIsCurrent(take) { await mediaSession.exitRecording(holder: .take) }
        }
    }

    private func runStreamingTake(
        _ s: any StreamingTranscriber,
        take: TakeContext,
        options: TranscriptionOptions,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async {
        let labeler = streamingSpeakerLabeler()
        do {
            let events = try await s.start(options: options, speakerLabeler: labeler, downloadProgress: downloadProgress)
            guard takeIsCurrent(take) else {
                // A take let go while its stop waited for the model lands from its stream.
                if liveTakesFinishingAlone[take.id] != nil {
                    for await event in events { await handleStreamingEvent(event, take: take, session: s) }
                    return
                }
                // The take ended while its model loaded; the model stays loaded for the next one.
                await s.cancel()
                return
            }
            updateSession(of: take.id) { session in
                if case .arming(.preparingModel) = session.state { session.arm(.startingCapture) }
            }
            let audio = await s.recordingAudioURL()
            guard takeIsCurrent(take) else { return }
            liveRecordingAudioURL = audio
            updateSession(of: take.id) { $0.audioURL = audio }
            writeRecordingCheckpoint()
            for await event in events {
                await handleStreamingEvent(event, take: take, session: s)
                // Self-cancellation inside the .failed handler races the stream's buffer;
                // a buffered late .finished must not resurrect the torn-down take.
                if case .failed = event { break }
            }
        } catch {
            // A cancelled load is not a failure, and the next take may already own the session this would tear down.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            let message = Self.transcriptionFailureMessage(for: error)
            let captured = await s.recordingAudioURL()
            let heard: URL? = if let captured, !(await Self.holdsNoAudio(captured)) { captured } else { nil }
            guard takeIsCurrent(take) else {
                guard let letGo = liveTakesFinishingAlone.removeValue(forKey: take.id) else { return }
                if let heard {
                    await landLetGoInterruptedTake(letGo, audio: heard)
                } else {
                    if let recovery = letGo.take.recovery {
                        recoveryHeldByTake.remove(recovery)
                        endRecovery(recovery)
                    }
                    if let captured { releaseTakeFile(captured) }
                }
                return
            }
            if heard != nil {
                await keepFailedLiveTake(message, take: take, session: s)
                return
            }
            reportTakeFailure(message, take: take.id)
            teardownStreaming(take)
            if let captured { releaseTakeFile(captured) }
            resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take.id)
        }
    }

    /// A take stopped and then let go whose model failed to load keeps its audio as an interrupted entry, through the held checkpoint.
    private func landLetGoInterruptedTake(_ letGo: FinishingAlone, audio: URL) async {
        let take = letGo.take
        let category = take.category
        let finished = await StreamingTranscriptionSession.finishedTake(
            segments: [], options: currentOptions, modelName: "", audioURL: audio
        )
        let processed = await postProcessDetached(finished)
        saveTake(
            processed,
            audio: audio,
            title: Self.takeTitle(letGo.annotations.title(for: category), suffix: .interrupted),
            source: take.source.entrySource,
            category: category,
            landingAs: .salvagedTake,
            recovery: take.recovery,
            take: take.id,
            annotations: letGo.annotations
        )
    }

    /// The model download a live take waits on shows in its pane; the phase stays the take's.
    private func makeTakeDownloadProgressHandler(for modelName: String, take takeID: Int) -> @Sendable (Double) -> Void {
        let downloadProgress = makeDownloadProgressHandler(for: modelName)
        return { [weak self] fraction in
            downloadProgress(fraction)
            Task { @MainActor [weak self] in
                self?.updateSession(of: takeID) { session in
                    guard case .arming(.preparingModel(let name, _)) = session.state, name == modelName else { return }
                    session.arm(.preparingModel(name: name, download: fraction < 1 ? fraction : nil))
                }
            }
        }
    }

    /// Session-local speaker labels for streaming mic recordings. When the diarizer models
    /// aren't downloaded yet, this recording stays unlabeled and the fetch runs in the
    /// background so the next one can label.
    private func streamingSpeakerLabeler() -> (any StreamingSpeakerLabeler)? {
        guard diarize else { return nil }
        if IncrementalSpeakerLabeler.modelsInstalled() {
            return IncrementalSpeakerLabeler.sharedInstalled()
        }
        if mode == .normal {
            Task.detached { try? await IncrementalSpeakerLabeler.downloadModels() }
        }
        return nil
    }

    /// Stops and clears the live streaming session, its consumer, and the silence watch.
    /// Without this a failed stream left the audio engine and observers running.
    private func teardownStreaming(_ take: TakeContext?) {
        streamingConsumer?.cancel()
        streamingConsumer = nil
        if let session = streamingSession {
            streamingSession = nil
            Task { await session.stop() }
        }
        endLiveTake(take)
    }

    /// Partials, segments and voice activity only arrive once the session captures, so the first marks the take's first audio.
    func handleStreamingEvent(
        _ event: StreamingEvent,
        take: TakeContext? = nil,
        session: (any StreamingTranscriber)? = nil
    ) async {
        // A take that ended in the pane has nothing left to report, unless a cancel let it go while it finished.
        if let take, !takeIsCurrent(take) {
            guard case .finished(let transcript) = event, let letGo = liveTakesFinishingAlone.removeValue(forKey: take.id) else { return }
            await landLiveTake(transcript, take: letGo.take, session: session, given: letGo.annotations)
            return
        }
        // The active copy rather than the one the stream started with: a take's category can change while it records.
        let owner = activeTake ?? take
        switch event {
        case .partial(let text):
            markTakeCapturing(owner)
            if livePartialText != text { livePartialText = text }
        case .confirmed(let segment):
            markTakeCapturing(owner)
            liveSegments.append(segment)
            if !livePartialText.isEmpty { livePartialText = "" }
        case .voiceActivity(let active):
            markTakeCapturing(owner)
            if liveVoiceActive != active { liveVoiceActive = active }
        case .warning:
            break
        case .failed(let msg):
            await keepFailedLiveTake(msg, take: owner, session: session ?? streamingSession)
        case .finished(let transcript):
            await landLiveTake(transcript, take: owner, session: session ?? streamingSession)
        }
    }

    /// A live take that failed keeps what it heard: its confirmed words and its audio, as an interrupted entry.
    private func keepFailedLiveTake(_ reason: String, take: TakeContext?, session: (any StreamingTranscriber)?) async {
        let reason = FailureText.reason(reason)
        let recovery = recoveryGeneration(of: take)
        // Held first, so the teardown below leaves the checkpoint for the save to end.
        if let recovery { recoveryHeldByTake.insert(recovery) }
        let confirmed = liveSegments
        let given = annotations(of: take?.id)
        updateSession(of: take?.id) { $0.fail(reason) }
        teardownStreaming(take)
        let audioURL = await session?.recordingAudioURL()
        var message = reason
        let takeCategory = take?.category ?? pendingRecordingCategory ?? .transcription
        let takeSource = take?.source.entrySource ?? pendingRecordingSource
        let takeTitle = given.title(for: takeCategory)
        let savedPartial = !confirmed.isEmpty || audioURL != nil
        var saving: Task<LibraryEntry, any Error>?
        if savedPartial {
            // With no words through, no model ran on it as far as the entry can tell: it opens as not transcribed.
            let finished = await StreamingTranscriptionSession.finishedTake(
                segments: confirmed, options: currentOptions, modelName: confirmed.isEmpty ? "" : selectedModel, audioURL: audioURL
            )
            let partial = await postProcessDetached(finished)
            saving = saveTake(
                partial,
                audio: audioURL,
                title: Self.takeTitle(takeTitle, suffix: .interrupted),
                source: takeSource,
                category: takeCategory,
                landingAs: .salvagedTake,
                recovery: recovery,
                take: take?.id,
                annotations: given
            )
            message += " " + String(localized: "The recording up to this point was saved to your library.")
        } else if let recovery {
            recoveryHeldByTake.remove(recovery)
            endRecovery(recovery)
        }
        // A take started while this one was being kept has the Stage now; this one is in the library.
        guard activeTake == nil else { return }
        liveSegments = []
        livePartialText = ""
        let retry = audioURL.map {
            Self.takeRetry(
                url: $0, title: takeTitle, source: takeSource, category: takeCategory, save: saving, recovery: recovery,
                annotations: given
            )
        }
        reportTakeFailure(message, take: take?.id, retry: retry)
        resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take?.id)
    }

    /// A live take's final transcript lands on screen and in the library; one with nothing in it says so.
    private func landLiveTake(
        _ transcript: Transcript, take: TakeContext?, session: (any StreamingTranscriber)?, given kept: TakeAnnotations? = nil
    ) async {
        let recovery = recoveryGeneration(of: take)
        // Held until the save ends it, so a cancel's cleanup during the awaits below leaves it on disk.
        if let recovery { recoveryHeldByTake.insert(recovery) }
        let arming = takeArming
        let given = kept ?? annotations(of: take?.id)
        if take.map(takeIsCurrent) ?? true { stopRecordingWatch() }
        let takeCategory = take?.category ?? pendingRecordingCategory ?? .transcription
        let takeSource = take?.source.entrySource ?? pendingRecordingSource
        let cutShort = await session?.audioWasCutShort() ?? false
        let processed = await postProcessDetached(transcript)
        if cutShort, let audio = processed.sourceURL {
            _ = try? await AppModel.offMainIO { WAVHeaderRepair.makeReadable(audio) }
        }
        let hasContent = !processed.segments.isEmpty || processed.sourceURL != nil
        // A take no model ran on (its stop gave up waiting for one) keeps its audio as not transcribed, not as no speech.
        let untranscribed = processed.modelName.isEmpty && processed.segments.isEmpty
        let note: TakeTitleSuffix? = cutShort ? .interrupted : untranscribed ? .notTranscribed : nil
        // Cancelled, or followed by another take, while those ran: it goes to the library without touching the screen.
        if let take, !takeIsCurrent(take) {
            liveTakesFinishingAlone.removeValue(forKey: take.id)
            if hasContent {
                let title = given.title(for: takeCategory)
                saveTake(
                    processed,
                    audio: processed.sourceURL,
                    title: note.map { Self.takeTitle(title, suffix: $0) } ?? title,
                    source: takeSource,
                    category: takeCategory,
                    landingAs: .salvagedTake,
                    recovery: recovery,
                    take: take.id,
                    annotations: given
                )
            } else {
                if let recovery {
                    recoveryHeldByTake.remove(recovery)
                    endRecovery(recovery)
                }
                if recording?.takeID == take.id { reportTakeFailure(Self.nothingRecordedMessage(), take: take.id) }
            }
            return
        }
        livePartialText = ""
        liveSegments = []
        // A take stopped before capture came up (say, during the first model download) has nothing to keep, and says so.
        guard hasContent else {
            let message = Self.nothingRecordedMessage(for: arming)
            if let recovery { recoveryHeldByTake.remove(recovery) }
            reportTakeFailure(message, take: take?.id)
            endLiveTake(take)
            resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take?.id)
            return
        }
        let title = given.title(for: takeCategory)
        // Watched on its Stage, the take opens as the transcript; from any other page it goes to the library with a toast.
        let inPlace = take.map { stageShows($0.id) } ?? true
        if inPlace {
            let landing = Self.landingSignposter.beginInterval("install")
            clearDerivedArtifacts()
            selectedEntryID = nil
            self.transcript = processed
            readyForLandedTake()
            showLandedTake()
            if let audioURL = processed.sourceURL {
                recordedTake = RecordedTake(file: audioURL, title: given.typedTitle ?? title, takeID: take?.id)
                sourceFileURL = audioURL
                installPlayer(for: audioURL)
                adoptLoadedMediaDuration()
            }
            Self.landingSignposter.endInterval("install", landing)
        }
        updateSession(of: take?.id) { $0.land(entryID: nil) }
        saveTake(
            processed,
            audio: processed.sourceURL,
            title: note.map { Self.takeTitle(title, suffix: $0) } ?? title,
            source: takeSource,
            category: takeCategory,
            landingAs: inPlace ? .recording : .backgroundTake,
            recovery: recovery,
            take: take?.id,
            annotations: given
        )
        endLiveTake(take)
        if cutShort {
            exportNotice = ExportNotice(
                message: String(localized: "The recording stopped saving to disk partway, so its audio ends early."),
                failures: [],
                folder: nil,
                tone: .info
            )
        }
        resolveRecordingOutcome(.success(processed.text), take: take?.id)
    }

    func stopRecordingAndTranscribe() {
        // Before the auto-stop is cancelled: a capture marked here schedules one.
        catchUpFirstBuffer()
        cancelRecordingAutoStop()
        // Nothing captured yet ends here and says so; a capture that came up stops normally and keeps its file.
        if let arming = takeArming, activeTake?.captureRequested == true, !captureIsUp(arming) {
            endTakeBeforeCapture(reporting: Self.nothingRecordedMessage(for: arming))
            return
        }
        if let s = streamingSession {
            let take = activeTake
            let consumer = streamingConsumer
            // Let go now, so a second Stop finds nothing left to stop.
            streamingSession = nil
            finishSession(of: take)
            trackTakeWork { [weak self] in
                await self?.finishStreamingTake(s, take: take, consumer: consumer)
                self?.resolveRecordingOutcome(.failure(IntentActionError.failed(Self.streamEndedWithoutTranscriptMessage())), take: take?.id)
            }
            return
        }

        guard let source = liveSource else {
            if recordingStartInFlight { stopRequestedDuringStart = true }
            return
        }
        // Hand off synchronously so a racing auto-stop or second click can't start a duplicate run.
        let take = activeTake
        let mic = detachMicTrackAtStop(of: take?.id, macMeter: (source as? any LiveAudioSource)?.levelMeter)
        let unheard = takeIsUnheard
        liveSource = nil
        activeTake = nil
        finishSession(of: take)
        stopRecordingWatch()
        stopSilenceWatch()
        let category = take?.category ?? pendingRecordingCategory ?? .transcription
        let takeSource = take?.source.entrySource ?? pendingRecordingSource
        let recovery = recoveryGeneration(of: take)
        // Held until the take's run replaces it, so a Cancel while the take finishes can't delete it mid-fold.
        if let recovery { recoveryHeldByTake.insert(recovery) }
        let given = annotations(of: take?.id)
        startTakeTask { [weak self] in
            guard let self else { return }
            await mediaSession.exitRecording(holder: .take)
            await recordMicStoppedAtStop(mic, recovery: recovery)
            let title = given.title(for: category)
            do {
                let url = try await source.prepare()
                let micFile = await finishMicTrack(mic)
                clearTakeReadouts(of: take?.id)
                if unheard, await Self.holdsNoAudio(url) {
                    releaseStoppedMicTrack(micFile)
                    endUnheardTake(url, recovery: recovery, take: take?.id)
                    return
                }
                let folded = await foldMicTrack(
                    micFile, into: url, take: take, recovery: recovery, wantsEngineInput: engineNeedsMonoMix(), trimsOverrun: true
                )
                if folded.stopped { return }
                await transcribeRecordedTake(
                    url: folded.audio, engineInput: folded.engineInput, title: title, source: takeSource, category: category,
                    replacing: recovery, take: take?.id, annotations: given
                )
            } catch let cut as CaptureInterrupted {
                let micFile = await finishMicTrack(mic)
                clearTakeReadouts(of: take?.id)
                liveRecordingAudioURL = nil
                let folded = await foldMicTrack(micFile, into: cut.url, take: take, recovery: recovery, wantsEngineInput: false)
                if folded.stopped { return }
                await keepCutShortTake(
                    CaptureInterrupted(url: folded.audio, reason: cut.reason), title: title, source: takeSource,
                    category: category, recovery: recovery, take: take?.id, annotations: given
                )
            } catch {
                // The Mac file stays for the sweep, and the microphone file beside it, named to pair with it.
                _ = await finishMicTrack(mic)
                liveCompanionAudioURL = nil
                clearTakeReadouts(of: take?.id)
                if let recovery {
                    recoveryHeldByTake.remove(recovery)
                    endRecovery(recovery)
                }
                liveRecordingAudioURL = nil
                let message = Self.transcriptionFailureMessage(for: error)
                reportTakeFailure(message, take: take?.id)
                resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take?.id)
            }
        }
    }

    /// A take's prepare and transcription run as the file run, and as take work, so a quit stops them and waits for the save they leave.
    func startTakeTask(_ body: @escaping @MainActor () async -> Void) {
        if fileTranscribeTask != nil { retireCurrentFileRun() }
        stopTakeRunForNewWork()
        fileTranscribeTask?.cancel()
        let task = Task { @MainActor [weak self] in
            await body()
            guard let self, !Task.isCancelled else { return }
            self.fileTranscribeTask = nil
        }
        fileTranscribeTask = task
        takeTask = task
        trackTakeWork { [weak self] in
            await task.value
            if self?.takeTask == task { self?.takeTask = nil }
        }
    }

    /// Stops a live take and waits for its last event, which saves it. Cleanup after the waits skips a take that started since.
    private func finishStreamingTake(_ s: any StreamingTranscriber, take: TakeContext?, consumer: Task<Void, Never>?) async {
        await s.stop()
        // Await delivery of the final .finished event; cancelling here can drop the whole recording.
        await consumer?.value
        if streamingConsumer == consumer { streamingConsumer = nil }
        let message = Self.streamEndedWithoutTranscriptMessage()
        if let take, liveTakesFinishingAlone.removeValue(forKey: take.id) != nil {
            if let recovery = take.recovery { recoveryHeldByTake.remove(recovery) }
            reportTakeFailure(message, take: take.id)
        }
        // A no-op when .finished already ended the take; it covers a stream that ends without one.
        updateSession(of: take?.id) { if $0.isRunning { $0.fail(message) } }
        endLiveTake(take)
    }

    /// A take whose file stopped taking writes keeps the audio that landed, saved as interrupted, with Retry.
    private func keepCutShortTake(
        _ cut: CaptureInterrupted, title: String, source: EntrySource, category: EntryCategory, recovery: Int?, take: Int?,
        annotations: TakeAnnotations
    ) async {
        let message = String(localized: "Parola couldn't keep writing the recording to disk.")
            + " " + String(localized: "The recording up to this point was saved to your library.")
        updateSession(of: take) { $0.fail(message) }
        _ = try? await AppModel.offMainIO { WAVHeaderRepair.makeReadable(cut.url) }
        let saving = saveTake(
            Self.untranscribedTranscript(of: cut.url, language: currentOptions.language),
            audio: cut.url,
            title: Self.takeTitle(title, suffix: .interrupted),
            source: source,
            category: category,
            landingAs: .salvagedTake,
            recovery: recovery,
            take: take,
            annotations: annotations
        )
        let retry = Self.takeRetry(
            url: cut.url, title: title, source: source, category: category, save: saving, recovery: recovery,
            annotations: annotations
        )
        reportTakeFailure(message, take: take, retry: retry)
        resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take)
    }

    /// The Stage's Cancel while a take arms: a count-in or a capture still starting ends without a word.
    func cancelArmingTake() {
        if recordingCountdown != nil {
            cancelRecordingCountdown()
        } else {
            cancelRecordingBeforeCapture()
        }
    }

    /// Stop from anywhere but the Stage's own buttons: a take that has recorded nothing ends as Cancel ends it; a buffer that just came in counts, so that take is kept.
    func stopTake() {
        catchUpFirstBuffer()
        if recording?.isArming == true {
            cancelArmingTake()
        } else {
            stopRecordingAndTranscribe()
        }
    }

    /// What the take records ended by itself: the take stops as Stop stops it, with a notice that stays until it is dismissed; one that never heard a sound ends with nothing saved, saying `unheard`.
    func stopTakeOnItsOwn(_ takeID: Int, saying message: String, unheard: String? = nil) {
        let covered = exportNotice
        catchUpFirstBuffer()
        guard recording?.isArming != true else {
            takeStopReason = unheard ?? message
            endTakeBeforeCapture(reporting: unheard ?? message)
            keepCovered(covered, take: takeID)
            return
        }
        takeStopReason = message
        stopRecordingAndTranscribe()
        exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .failure, forTake: takeID)
        keepCovered(covered, take: takeID)
    }

    /// Cancel on a take that has captured nothing: there is nothing to lose, so it ends without a word.
    func cancelRecordingBeforeCapture() {
        guard takeArming != nil else { return }
        guard activeTake?.captureRequested == true else {
            if recordingStartInFlight { stopRequestedDuringStart = true }
            return
        }
        endTakeBeforeCapture(reporting: nil)
    }

    /// Ends a take in the pane at once; a start in flight drops its capture later, and a model still loading finishes for the next take.
    private func endTakeBeforeCapture(reporting message: String?) {
        let take = activeTake
        if case .preparingModel = takeArming, let s = streamingSession {
            streamingSession = nil
            streamingConsumer = nil
            trackTakeWork { await s.cancel() }
        }
        if let message {
            reportTakeFailure(message, take: take?.id)
        } else {
            endSession(of: take?.id)
        }
        activeTake = nil
        recordingStartInFlight = false
        stopRequestedDuringStart = false
        teardownActiveCapture()
        if let message {
            resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take?.id)
        } else {
            resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: take?.id)
        }
    }

    nonisolated static func nothingRecordedMessage(for arming: TakeArming? = nil, bundle: Bundle = .main) -> String {
        if case .preparingModel = arming {
            return String(localized: "Nothing was recorded — the model was still loading.", bundle: bundle)
        }
        return String(localized: "Nothing was recorded.", bundle: bundle)
    }

    nonisolated static func streamEndedWithoutTranscriptMessage(bundle: Bundle = .main) -> String {
        String(localized: "The recording ended without a transcript.", bundle: bundle)
    }

    /// A take whose capture came up, live or to a file, has something to stop; one still starting doesn't.
    private func captureIsUp(_ arming: TakeArming) -> Bool {
        arming == .startingCapture && (streamingSession != nil || liveSource != nil)
    }

    /// A WAV header and next to nothing after it, by the rule the launch sweep uses.
    nonisolated static func holdsNoAudio(_ file: URL) async -> Bool {
        let bytes = (try? await offMainIO { try file.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? nil
        return (bytes ?? 0) <= emptyTakeBytes
    }

    /// A take that came up but never heard a buffer, and whose file holds nothing, ends as if stopped before capture.
    private func endUnheardTake(_ file: URL, recovery: Int?, take: Int?) {
        if let recovery {
            recoveryHeldByTake.remove(recovery)
            endRecovery(recovery)
        }
        liveRecordingAudioURL = nil
        releaseTakeFile(file)
        let message = Self.nothingRecordedMessage()
        reportTakeFailure(message, take: take)
        resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take)
    }

    /// Transcribes a finished take from its working file, retiring the checkpoint it replaces; a failure or a stop still saves it.
    func transcribeRecordedTake(
        url: URL, engineInput: URL? = nil, title: String, source: EntrySource, category: EntryCategory = .transcription,
        replacing previous: Int? = nil, take: Int? = nil, annotations: TakeAnnotations = TakeAnnotations()
    ) async {
        liveRecordingAudioURL = nil
        takeRunCounter &+= 1
        let run = takeRunCounter
        // Stopped before it began, the run only saves: a newer take's run keeps Stop Transcribing, its title and its Stage.
        let startsStopped = Task.isCancelled
        if !startsStopped { takeRun = run }
        var engineFile = engineInput
        defer {
            if takeRun == run { takeRun = nil }
            endTakeTranscription(run)
            discardMeetingScratch([engineFile])
        }
        let named = annotations.typedTitle ?? title
        let recovery = beginFileTranscribeRecovery(
            sourceURL: url, title: named, source: source, category: category, annotations: annotations
        )
        // Held by the run itself, so a Cancel's cleanup leaves it for the save that follows.
        recoveryHeldByTake.insert(recovery)
        if !startsStopped { recordedTake = RecordedTake(file: url, title: named, takeID: take) }
        // A take's run reports to its session and its Stage; one with no session is a run like a file's.
        if let take {
            if !startsStopped { beginTakeTranscription(TakeTranscription(run: run, takeID: take, file: url)) }
        } else {
            phase = .transcribing(file: url)
        }
        updateSession(of: take) { $0.transcribing(progress: nil) }
        if let previous {
            recoveryHeldByTake.remove(previous)
            await pendingRecoveryWrite?.value
            endRecovery(previous)
        }
        do {
            // A take stopped before its run began, by a quit say, goes straight to its save.
            try Task.checkCancellation()
            var meeting = engineInput != nil
            if !meeting { meeting = await isMeetingStereo(url, source: source) }
            if meeting, engineFile == nil, engineNeedsMonoMix() { engineFile = try await meetingEngineInput(for: url) }
            let handlers = take.map { makeTakeHandlers(run: run, takeID: $0) } ?? TranscribeHandlers()
            modelResidency.sessionRunBegan()
            defer { modelResidency.sessionRunEnded() }
            let result = try await session.transcribe(
                source: FileAudioSource(url: engineFile ?? url),
                options: meeting ? meetingOptions(currentOptions, stereo: url) : currentOptions,
                partialHandler: handlers.onPartial,
                progressHandler: handlers.onProgress,
                stageHandler: handlers.onStage
            )
            var processed = await postProcessDetached(result)
            if meeting { processed.sourceURL = url }
            // A run stopped after its words were ready keeps them, out of the way of whatever stopped it.
            guard !Task.isCancelled else {
                saveTake(
                    processed, audio: url, title: title, source: source, category: category, landingAs: .salvagedTake,
                    recovery: recovery, take: take, annotations: annotations
                )
                resolveRecordingOutcome(.success(processed.text), take: take)
                return
            }
            guard take.map({ stageShows($0) }) ?? true else {
                saveTake(
                    processed, audio: url, title: title, source: source, category: category, landingAs: .backgroundTake,
                    recovery: recovery, take: take, annotations: annotations
                )
                resolveRecordingOutcome(.success(processed.text), take: take)
                return
            }
            let landing = Self.landingSignposter.beginInterval("install")
            defer { Self.landingSignposter.endInterval("install", landing) }
            clearDerivedArtifacts()
            selectedEntryID = nil
            restorePlaybackSource(url)
            transcript = processed
            adoptLoadedMediaDuration()
            readyForLandedTake()
            if route == .recording { showLandedTake() }
            saveTake(
                processed, audio: url, title: title, source: source, category: category, landingAs: .recording,
                recovery: recovery, take: take, annotations: annotations
            )
            resolveRecordingOutcome(.success(processed.text), take: take)
        } catch {
            keepUntranscribedTake(
                url: url, title: title, source: source, category: category, error: error,
                recovery: recovery, forNewWork: takeRunStoppedByNewWork == run,
                stoppedByUser: takeRunStoppedByStopTranscribing == run, take: take, annotations: annotations
            )
        }
    }

    /// A take whose transcription failed or was stopped goes to the library as audio; only a failure reports.
    private func keepUntranscribedTake(
        url: URL, title: String, source: EntrySource, category: EntryCategory, error: any Error,
        recovery: Int?, forNewWork: Bool, stoppedByUser: Bool, take: Int?, annotations: TakeAnnotations
    ) {
        let stopped = error is CancellationError || Task.isCancelled
        let saving = saveTake(
            Self.untranscribedTranscript(of: url, language: currentOptions.language),
            audio: url,
            title: Self.takeTitle(title, suffix: stopped ? .notTranscribed : .transcriptionFailed),
            source: source,
            category: category,
            landingAs: .salvagedTake,
            recovery: recovery,
            take: take,
            annotations: annotations
        ) { [weak self] entry in
            guard let self else { return }
            if forNewWork {
                self.exportNotice = ExportNotice(
                    message: String(localized: "Saved the previous recording without transcribing it."),
                    failures: [], folder: nil, tone: .info,
                    actions: [
                        ExportNotice.Action(title: String(localized: "Open"), handler: .openEntry(entry.id)),
                        ExportNotice.Action(title: String(localized: "Transcribe"), handler: .transcribeEntry(entry.id))
                    ]
                )
            } else if stoppedByUser {
                self.exportNotice = ExportNotice(
                    message: String(localized: "Saved without a transcript."),
                    failures: [], folder: nil, tone: .info,
                    actions: [ExportNotice.Action(title: String(localized: "Transcribe"), handler: .transcribeEntry(entry.id))]
                )
            }
        }
        // Whatever stopped the run keeps the screen; only the take's own pane gives way.
        handBackTakePane(url)
        if stopped {
            resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: take)
            return
        }
        let message = Self.transcriptionFailureMessage(for: error)
            + " " + String(localized: "The audio was saved to your library.")
        // A take recording since then keeps the page; the failed one waits in the library.
        if take != nil || !takeIsRunning {
            let retry = Self.takeRetry(
                url: url, title: title, source: source, category: category, save: saving, recovery: recovery,
                annotations: annotations
            )
            reportTakeFailure(message, take: take, retry: retry)
        }
        resolveRecordingOutcome(.failure(IntentActionError.failed(message)), take: take)
    }

    /// The transcribing pane a run with no session put up comes down; anything that took the phase since keeps it.
    private func handBackTakePane(_ file: URL?) {
        guard let file, phase == .transcribing(file: file) else { return }
        phase = transcript == nil ? .idle : .ready
    }

    /// A take's run takes over the Stage's readouts, starting from nothing.
    private func beginTakeTranscription(_ transcription: TakeTranscription) {
        endTakeTranscription()
        takeTranscription = transcription
    }

    /// The Stage lets go of the take run it shows, or only of `run`, and of what that run painted.
    private func endTakeTranscription(_ run: Int? = nil) {
        guard let shown = takeTranscription, run == nil || shown.run == run else { return }
        takeTranscription = nil
        if !takePartialText.isEmpty { takePartialText = "" }
        if takeTranscribeStage != nil { takeTranscribeStage = nil }
    }

    /// What a take's run reports, stamped with the run, so one that was stopped or replaced changes nothing.
    func makeTakeHandlers(run: Int, takeID: Int) -> TranscribeHandlers {
        let partials = makeTakePartialCoalescer(run: run)
        let progress = makeTakeProgressCoalescer(run: run, takeID: takeID)
        return TranscribeHandlers(
            onPartial: { partials.send($0) },
            onProgress: { progress.send($0) },
            onStage: makeTakeStageHandler(run: run)
        )
    }

    private func makeTakePartialCoalescer(run: Int) -> MainActorCoalescer<String> {
        MainActorCoalescer { [weak self] text in
            guard let self, self.takeTranscription?.run == run, self.takePartialText != text else { return }
            self.takePartialText = text
        }
    }

    /// The engine counts seconds of the file; the session knows how long the take is.
    private func makeTakeProgressCoalescer(run: Int, takeID: Int) -> MainActorCoalescer<Double> {
        let throttle = ProgressThrottle()
        return MainActorCoalescer { [weak self] seconds in
            guard let self, self.takeTranscription?.run == run, let session = self.recording, session.takeID == takeID,
                  let length = session.endedElapsed, let fraction = throttle.advance(to: seconds, of: length) else { return }
            self.updateSession(of: takeID) { $0.transcribing(progress: fraction) }
        }
    }

    private func makeTakeStageHandler(run: Int) -> @Sendable (TranscribeStage) -> Void {
        { [weak self] stage in
            Task { @MainActor in
                guard let self, self.takeTranscription?.run == run, self.takeTranscribeStage != stage else { return }
                self.takeTranscribeStage = stage
            }
        }
    }

    /// What Retry needs of a take whose audio was saved untranscribed.
    private static func takeRetry(
        url: URL, title: String, source: EntrySource, category: EntryCategory,
        save: Task<LibraryEntry, any Error>?, recovery: Int?, annotations: TakeAnnotations
    ) -> RecordingSession.Failure {
        RecordingSession.Failure(
            audioURL: url, save: save, recovery: recovery, title: annotations.typedTitle ?? title,
            category: category, source: source, annotations: annotations
        )
    }

    /// After the phase is set: its didSet forgets whatever the last failure left behind.
    private func armTakeRetry(_ retry: RecordingSession.Failure) {
        failureKind = .transcription
        failedTakeRetry = retry
        armTakeFileHeartbeat()
    }

    /// A model download from Settings keeps the phase for its bar; the transcript page shows past it.
    private func readyForLandedTake() {
        if case .downloadingModel = phase, downloadTask != nil { return }
        phase = .ready
    }

    private func showLandedTake() {
        let fromStage = route == .recording
        route = .transcript
        routeLandsTake = fromStage
    }

    /// Stops a take's transcription. The take is saved to the library untranscribed, so the recording survives.
    func stopTranscribingTake() {
        guard let run = takeRun else { return }
        takeRunStoppedByStopTranscribing = run
        cancelAndTrack(&fileTranscribeTask)
        endTakeTranscription(run)
        handBackTakePane(recordedTake?.file)
    }

    /// A take's library save: the checkpoint and working file stay until the entry exists, and a quit waits for it.
    @discardableResult
    func saveTake(
        _ transcript: Transcript,
        audio: URL?,
        title: String,
        source: EntrySource,
        category: EntryCategory,
        landingAs kind: RunLanding.Kind,
        recovery: Int?,
        take: Int? = nil,
        annotations: TakeAnnotations = TakeAnnotations(),
        onSaved: (@MainActor (LibraryEntry) -> Void)? = nil
    ) -> Task<LibraryEntry, any Error> {
        // A typed title is the user's: it replaces the generated one, and carries none of its notes.
        let saving = land(RunLanding(
            kind: kind,
            transcript: transcript,
            audioSource: audio,
            source: source,
            category: category,
            title: annotations.typedTitle ?? title,
            titleSource: annotations.typedTitle == nil ? nil : .user,
            takeMarkers: annotations.markers,
            sourceAppBundleID: annotations.sourceAppBundleID
        ))
        if let recovery { recoveryHeldByTake.insert(recovery) }
        if let audio { takeFilesBeingSaved[audio, default: 0] += 1 }
        trackTakeWork { [weak self, library] in
            let entry = try? await saving.value
            // Before the take's checkpoint goes; a record that doesn't land leaves that checkpoint and the take's copy naming the mic.
            var heldForMic: [String] = []
            if let entry, let audio, let self, let mic = self.pendingMicTracks.removeValue(forKey: audio),
               await !self.keepMicTrack(mic, forEntry: entry.id) {
                heldForMic = [audio, mic.file].map { $0.resolvingSymlinksInPath().path }
                self.recoveryReferencedFiles.formUnion(heldForMic)
            }
            let micKept = heldForMic.isEmpty
            if let audio, let self {
                let left = (self.takeFilesBeingSaved[audio] ?? 1) - 1
                self.takeFilesBeingSaved[audio] = left > 0 ? left : nil
            }
            // At once: the entry holds the take now, and a quit may not wait for the rest.
            if let recovery {
                self?.recoveryHeldByTake.remove(recovery)
                if entry != nil, micKept {
                    self?.endRecovery(recovery)
                } else {
                    self?.keepForNextLaunch(recovery)
                }
            }
            self?.updateSession(of: take) { $0.land(entryID: entry?.id) }
            if kind == .recording, take != nil, let entry {
                self?.takeSavedNotice = TakeSavedNotice(entryID: entry.id, title: LibraryEntryDisplay.title(for: entry), category: category)
            }
            var entryAudio: URL?
            if let entry, audio != nil { entryAudio = try? await library.load(entry.id).document.audioURL }
            guard let self, let entry else { return }
            onSaved?(entry)
            self.recoveryReferencedFiles.formUnion(heldForMic)
            self.assignMePerson(in: entry.id, transcript: transcript)
            if let audio {
                if let entryAudio, self.sourceFileURL == audio, self.selectedEntryID == entry.id {
                    self.movePlayback(to: entryAudio)
                }
                self.releaseTakeFile(audio)
            }
        }
        return saving
    }

    private func trackTakeWork(_ work: @escaping @MainActor () async -> Void) {
        takeWorkCounter &+= 1
        let id = takeWorkCounter
        takeWork[id] = Task { [weak self] in
            await work()
            self?.takeWork[id] = nil
        }
    }

    /// The take's title while its own working file is what's loaded; nil once playback moves into its entry.
    func recordedTakeTitle(playing file: URL?) -> String? {
        guard let file, let recordedTake, recordedTake.file == file else { return nil }
        return recordedTake.title
    }

    // MARK: - Take controls

    /// The take from Record until Stop, which its controls act on; nil during a count-in and once Stop is pressed.
    private var controlledTake: TakeContext? {
        guard let take = activeTake, let session = recording, session.takeID == take.id,
              session.isArming || session.isCapturing else { return nil }
        return take
    }

    /// Pauses a take that is capturing: its file stops growing, its clock and auto-stop hold, and its silence watch and sampler rest.
    @discardableResult
    func pauseTake() -> Bool {
        guard let take = controlledTake else { return false }
        var paused = false
        updateSession(of: take.id) { paused = $0.pause(at: Date()) }
        guard paused else { return false }
        setCapturePaused(true)
        stopSilenceWatch()
        holdRecordingAutoStop()
        restTakeSampler(take)
        return true
    }

    @discardableResult
    func resumeTake() -> Bool {
        guard let take = controlledTake, recording?.isPaused == true else { return false }
        let meter = takeReadoutsOwner == take.id ? recordingLevelMeter : nil
        // A tick while the take still pauses: a microphone first heard in the pause is placed where the pause began, and the meters' peaks from it go.
        if let meter { sampleTake(meter, take: take) }
        var resumed = false
        updateSession(of: take.id) { resumed = $0.resume(at: Date()) }
        guard resumed else { return false }
        setCapturePaused(false)
        startSilenceWatch()
        runRecordingAutoStop()
        if let meter { startTakeSampler(meter: meter, take: take) }
        return true
    }

    /// One last tick, as the sampler would have taken, then none until the take resumes.
    private func restTakeSampler(_ take: TakeContext) {
        stopTakeSampler()
        guard takeReadoutsOwner == take.id, let meter = recordingLevelMeter else { return }
        sampleTake(meter, take: take)
    }

    /// One change after another, so a quick pause and resume reach the capture in the order they were made.
    private func setCapturePaused(_ paused: Bool) {
        let capture = liveSource as? any LiveAudioSource
        let stream = streamingSession
        let earlier = takePauseWrites
        takePauseWrites = Task {
            await earlier?.value
            await capture?.setPaused(paused)
            await stream?.setPaused(paused)
        }
        if let mic = micTrack?.capture { queueMicTrackPause(paused, on: mic) }
    }

    /// The mic keeps a queue of its own, so a wedged input device can't hold up the Mac audio's pause or resume.
    func queueMicTrackPause(_ paused: Bool, on capture: any LiveAudioSource) {
        let earlier = micTrackPauseWrites
        micTrackPauseWrites = Task {
            await earlier?.value
            await capture.setPaused(paused)
        }
    }

    /// Marks this moment, whose sentence becomes a favorite once the take has words; nil when nothing is capturing or the last mark is under a second old.
    @discardableResult
    func addTakeMarker() -> TimeInterval? {
        guard let take = controlledTake else { return nil }
        var mark: TimeInterval?
        updateSession(of: take.id) { mark = $0.addMarker(at: Date()) }
        if mark != nil { writeRecordingCheckpoint() }
        return mark
    }

    /// The confirmed Discard: the take's audio and checkpoint are deleted and nothing is saved; a take still arming ends as Cancel ends it.
    func discardTake() async {
        if recordingCountdown != nil {
            cancelRecordingCountdown()
            return
        }
        guard controlledTake != nil, let session = recording else { return }
        guard session.isCapturing else {
            cancelRecordingBeforeCapture()
            return
        }
        await discardCapture()
    }

    /// A title the user typed becomes the entry's own; an empty one gives the take its generated name back. A count-in hands its title to the take it becomes.
    func renameTake(_ title: String) {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let countIn = recording, countIn.isCountingIn {
            updateSession(of: countIn.takeID) { $0.rename(typed) }
            return
        }
        guard let take = controlledTake else { return }
        let before = recording
        updateSession(of: take.id) { $0.rename(typed) }
        if recording != before { checkpointRenameSoon(of: take.id) }
    }

    /// A rename reaches the take's checkpoint within a second: one write for a run of keystrokes, never one for each.
    private func checkpointRenameSoon(of takeID: Int) {
        guard renameCheckpoint == nil else { return }
        let clock = clock
        renameCheckpoint = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1), clock: clock)
            guard let self else { return }
            self.renameCheckpoint = nil
            guard self.activeTake?.id == takeID else { return }
            self.writeRecordingCheckpoint()
        }
    }

    /// Note or Meeting for the take in progress: its entry is saved under it, and a generated title follows it; a count-in hands the choice to the take it becomes.
    func setTakeCategory(_ category: EntryCategory) {
        if let countIn = recording, countIn.isCountingIn {
            updateSession(of: countIn.takeID) { session in
                session.category = category
                guard session.titleSource == nil else { return }
                session.title = session.generatedTitle
            }
            return
        }
        guard let take = controlledTake, take.category != category else { return }
        activeTake?.category = category
        updateSession(of: take.id) { session in
            session.category = category
            guard session.titleSource == nil else { return }
            session.title = session.generatedTitle
        }
        writeRecordingCheckpoint()
    }

    /// What the take's session holds for its entry, while the session is still that take's.
    func annotations(of takeID: Int?) -> TakeAnnotations {
        guard let takeID, let session = recording, session.takeID == takeID else { return TakeAnnotations() }
        return TakeAnnotations(
            generatedTitle: session.generatedTitle,
            typedTitle: session.titleSource == .user ? session.title : nil,
            markers: session.markers,
            sourceAppBundleID: session.sourceAppBundleID
        )
    }

    // MARK: - Take titles

    /// What a take's title says about the audio it holds; the raw value is the English text.
    enum TakeTitleSuffix: String {
        case notTranscribed = "(not transcribed)"
        case transcriptionFailed = "(transcription failed)"
        case interrupted = "(interrupted)"
    }

    /// Live takes capture to a temp file whose UUID name would otherwise leak into the
    /// library title when auto-titling is unavailable.
    nonisolated static func liveRecordingTitle(category: EntryCategory, endedAt: Date, bundle: Bundle = .main) -> String {
        let stamp = AppFormat.dateAndTime(endedAt)
        return category == .meeting
            ? String(localized: "Meeting \(stamp)", bundle: bundle)
            : String(localized: "Recording \(stamp)", bundle: bundle)
    }

    nonisolated static func takeTitle(_ title: String, suffix: TakeTitleSuffix, bundle: Bundle = .main) -> String {
        "\(title) \(suffixText(suffix, bundle: bundle))"
    }

    private nonisolated static func suffixText(_ suffix: TakeTitleSuffix, bundle: Bundle) -> String {
        switch suffix {
        case .notTranscribed: return String(localized: "(not transcribed)", bundle: bundle)
        case .transcriptionFailed: return String(localized: "(transcription failed)", bundle: bundle)
        case .interrupted: return String(localized: "(interrupted)", bundle: bundle)
        }
    }

    /// The title without its "not transcribed" note, for a take that has a transcript now; nil when it carries none.
    nonisolated static func transcribedTitle(from title: String, bundle: Bundle = .main) -> String? {
        let notes = [TakeTitleSuffix.notTranscribed, .transcriptionFailed].flatMap { [suffixText($0, bundle: bundle), $0.rawValue] }
        for note in notes where title.hasSuffix(" " + note) {
            return String(title.dropLast(note.count + 1))
        }
        return nil
    }

    /// No model ran on it, which is how an entry tells "not transcribed" from "no speech found".
    nonisolated static func untranscribedTranscript(of audio: URL, language: String?) -> Transcript {
        Transcript(segments: [], language: language ?? "auto", modelName: "", sourceURL: audio)
    }

    // MARK: - Quitting during a take

    /// A take whose capture is up, paused or not, so quitting now would drop what it holds. One still starting has nothing to lose.
    var takeInProgress: Bool {
        guard liveSource != nil || streamingSession != nil else { return false }
        return recording?.isCapturing == true || takeIsUnheard
    }

    /// A live take finishing, a take transcribing, or a take's save still on its way to the library.
    var hasPendingTakeWork: Bool {
        !takeWork.isEmpty
    }

    /// Acts on the answer to the quit prompt and waits for every take's save, all within the quit's limit; true when the app may quit.
    func resolveQuitDuringTake(_ choice: QuitDuringTake) async -> Bool {
        guard choice != .keepRecording else { return false }
        // Said at once: a live take's last decode can take a while before any save begins.
        if choice == .stopAndSave { savingTakesBeforeQuit = true }
        await withinQuitLimit { [weak self] in
            if choice == .discard {
                await self?.discardCapture()
            } else {
                await self?.saveTakeForQuit()
            }
            await self?.waitForTakeWork()
        }
        return true
    }

    /// The bridge's quit asks nobody: a take capturing is stopped and saved, as the prompt's Stop and Save does, and nothing new starts meanwhile.
    func stopAndSaveTakeForQuit() async {
        quitPending = true
        if takeInProgress { _ = await resolveQuitDuringTake(.stopAndSave) }
    }

    /// Holds a quit, with the window saying so, until every take is in the library or the limit passes; a take still transcribing stops and is saved as audio.
    func finishTakeWorkForQuit() async {
        await withinQuitLimit { [weak self] in await self?.waitForTakeWork() }
    }

    /// A test reset's wait: every take's save lands, or `limit` passes, before the library is wiped.
    func settleTakeWork(within limit: Duration) async {
        _ = await AsyncTimeout.run(limit, clock: clock) { @MainActor [weak self] in
            while let work = self?.takeWork.values.first { await work.value }
        }
    }

    private func waitForTakeWork() async {
        takeTask?.cancel()
        guard !takeWork.isEmpty else { return }
        savingTakesBeforeQuit = true
        while let work = takeWork.values.first {
            await work.value
        }
    }

    private func withinQuitLimit(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        _ = await AsyncTimeout.run(quitSaveLimit, clock: clock) { await work() }
    }

    /// A quit can't wait for a model, so a file take is saved as audio; a live take keeps what it transcribed.
    private func saveTakeForQuit() async {
        catchUpFirstBuffer()
        cancelRecordingAutoStop()
        if let arming = takeArming, activeTake?.captureRequested == true, !captureIsUp(arming) {
            endTakeBeforeCapture(reporting: nil)
            return
        }
        if let s = streamingSession {
            let take = activeTake
            let consumer = streamingConsumer
            streamingSession = nil
            finishSession(of: take)
            await finishStreamingTake(s, take: take, consumer: consumer)
            return
        }
        guard let source = liveSource else { return }
        let take = activeTake
        let mic = detachMicTrackAtStop(of: take?.id, macMeter: (source as? any LiveAudioSource)?.levelMeter)
        let unheard = takeIsUnheard
        liveSource = nil
        activeTake = nil
        finishSession(of: take)
        stopRecordingWatch()
        stopSilenceWatch()
        let category = take?.category ?? pendingRecordingCategory ?? .transcription
        let takeSource = take?.source.entrySource ?? pendingRecordingSource
        let recovery = recoveryGeneration(of: take)
        if let recovery { recoveryHeldByTake.insert(recovery) }
        let given = annotations(of: take?.id)
        let title = given.title(for: category)
        await mediaSession.exitRecording(holder: .take)
        await recordMicStoppedAtStop(mic, recovery: recovery)
        var cutShort = false
        let prepared: URL?
        do {
            prepared = try await source.prepare()
        } catch let cut as CaptureInterrupted {
            prepared = cut.url
            cutShort = true
        } catch {
            prepared = nil
        }
        let micFile = await finishMicTrack(mic)
        clearTakeReadouts(of: take?.id)
        var heardNothing = false
        if unheard, !cutShort, let url = prepared { heardNothing = await Self.holdsNoAudio(url) }
        if heardNothing {
            endSession(of: take?.id)
        } else {
            updateSession(of: take?.id) { $0.land(entryID: nil) }
        }
        resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: take?.id)
        // Without a file the checkpoint stays, so the next launch offers what it points at.
        guard let prepared else { return }
        guard !heardNothing else {
            releaseStoppedMicTrack(micFile)
            if let recovery {
                recoveryHeldByTake.remove(recovery)
                endRecovery(recovery)
            }
            releaseTakeFile(prepared)
            return
        }
        if cutShort { _ = try? await AppModel.offMainIO { WAVHeaderRepair.makeReadable(prepared) } }
        let folded = await foldMicTrack(
            micFile, into: prepared, take: take, recovery: recovery, wantsEngineInput: false, trimsOverrun: !cutShort
        )
        if folded.stopped { return }
        let url = folded.audio
        saveTake(
            Self.untranscribedTranscript(of: url, language: currentOptions.language),
            audio: url,
            title: Self.takeTitle(title, suffix: cutShort ? .interrupted : .notTranscribed),
            source: takeSource,
            category: category,
            landingAs: .salvagedTake,
            recovery: recovery,
            take: take?.id,
            annotations: given
        )
    }

    /// Stops the capture without keeping anything: the take's audio and checkpoint are deleted, and no entry is made.
    private func discardCapture() async {
        let discarded = activeTake?.id
        let audio = recording?.takeID == activeTake?.id ? recording?.audioURL : nil
        let streaming = streamingSession
        let capture = liveSource
        let consumer = streamingConsumer
        let mic = detachMicTrack(of: nil)
        streamingSession = nil
        liveSource = nil
        teardownActiveCapture(exitsMedia: false)
        await streaming?.cancel()
        await capture?.cancel()
        await dropMicTrack(mic)
        // After the consumer's own exit, so this one is the exit that restores muted or paused media before the reply.
        await consumer?.value
        await mediaSession.exitRecording(holder: .take)
        // Whatever the capture left of its file goes too, so the launch sweep can't bring a discarded take back.
        if let audio { releaseTakeFile(audio) }
        resolveRecordingOutcome(.failure(IntentActionError.cancelled), take: discarded)
    }

    /// A phase change means the last failure's file is no longer what the error card is about.
    private func forgetFailedSource() {
        if failureKind != .other { failureKind = .other }
        if failedFileURL != nil { failedFileURL = nil }
        if failedTranslateOverride != nil { failedTranslateOverride = nil }
        if failedLink != nil { failedLink = nil }
        if failedLinkDownload != nil { failedLinkDownload = nil }
        if failedTakeRetry != nil { failedTakeRetry = nil }
    }

    var canRetryFailedTranscription: Bool {
        failureKind == .transcription && (failedTakeRetry != nil || failedFileURL != nil || failedLink != nil)
    }

    /// What the error card names: a recorded take by its title, an opened file by its file name.
    var failedSourceName: String? {
        guard failureKind == .transcription else { return nil }
        if let failedTakeRetry { return failedTakeRetry.title }
        return failedFileURL?.lastPathComponent
    }

    func retryFailedTranscription() {
        guard !takeIsRunning else {
            noteRunWaitsForTake()
            return
        }
        if let failedTakeRetry {
            retryTake(failedTakeRetry)
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
        // A watched file that stopped the lane is still in it: Retry starts the lane, not a second copy.
        if watchedLanePausedAt != nil, watchedArrivals.contains(where: { $0.url == url }) {
            phase = transcript == nil ? .idle : .ready
            resumeWatchedLane()
            return
        }
        beginFileTranscription(fileURL: url, translateOverride: failedTranslateOverride)
    }

    func revealFailedFile() {
        guard let url = failedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Retry on a failed take's Stage: the take hands over to the library, where its entry runs again.
    func retryFailedTake() {
        guard let session = recording, let failure = session.failure else { return }
        endSession(of: session.takeID)
        retryTake(failure)
    }

    /// Dismiss on a failed take's Stage: what it kept is in the library, so the page goes back there.
    func dismissTakeFailure() {
        guard let session = recording, case .failed = session.state else { return }
        endSession(of: session.takeID)
    }

    func dismissTakeSaved() {
        takeSavedNotice = nil
    }

    /// The toast's window is on screen: its time starts the first time, as an arrival toast's does, so a take landed behind a hidden window keeps it.
    func takeSavedCameOnScreen() {
        guard takeSavedNotice != nil, !takeSavedSeen else { return }
        takeSavedSeen = true
        takeSavedWasSeen = true
        restartTakeSavedExpiry()
    }

    /// The saved take's toast belongs under that take's transcript; on any other page its Summarize and Copy would read as acting there.
    var takeSavedToastIsOnItsTake: Bool {
        guard let notice = takeSavedNotice else { return false }
        return transcriptIsOnScreen && selectedEntryID == notice.entryID
    }

    /// Once seen, the toast goes when the user moves on; a landing still on its way to the take's transcript leaves it.
    private func dropTakeSavedOnceLeft() {
        guard takeSavedWasSeen, takeSavedNotice != nil, !noticesWaitForStage, !takeSavedToastIsOnItsTake else { return }
        takeSavedNotice = nil
    }

    /// A saved take's toast the Stage covers keeps its Summarize and Copy: its time starts again once it is back in view.
    private func holdSavedToastBehindStage() {
        guard noticesWaitForStage, takeSavedSeen else { return }
        takeSavedSeen = false
        restartTakeSavedExpiry()
    }

    /// The pointer over the saved-take toast holds it; when it leaves, the toast's time starts again.
    func holdTakeSaved(_ held: Bool) {
        guard takeSavedHeld != held else { return }
        takeSavedHeld = held
        restartTakeSavedExpiry()
    }

    /// The model keeps the toast's time, so a window closed and opened again doesn't bring a stale toast back.
    private func restartTakeSavedExpiry() {
        takeSavedExpiry?.cancel()
        takeSavedExpiry = nil
        guard let notice = takeSavedNotice, takeSavedSeen, !takeSavedHeld, !voiceOverIsRunning else { return }
        let lifetime = takeSavedLifetime
        let clock = clock
        takeSavedExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime, clock: clock)
            guard !Task.isCancelled, let self, self.takeSavedNotice == notice else { return }
            self.takeSavedNotice = nil
        }
    }

    /// The saved take's Summarize: its transcript page in summary mode, with a summary on the way unless it has one already.
    func summarizeSavedTake(_ entryID: LibraryEntry.ID) {
        dismissTakeSaved()
        Task { [weak self] in
            guard let self else { return }
            if selectedEntryID != entryID {
                guard (try? await openEntry(entryID)) != nil else { return }
            }
            route = .transcript
            setTranscriptPaneMode(.summary)
            guard transcript?.summary == nil, !isSummarising else { return }
            summariseTranscript()
        }
    }

    /// The saved take's Copy, as Copy Transcript copies it; read from the library if the user has moved on.
    func copySavedTake(_ entryID: LibraryEntry.ID, to pasteboard: NSPasteboard = .general) async {
        dismissTakeSaved()
        var copied = selectedEntryID == entryID ? transcript : nil
        if copied == nil { copied = try? await library.load(entryID).document.transcript }
        guard let copied else { return }
        await copyTranscriptAsPlainText(copied, to: pasteboard)
    }

    /// What Reveal in Finder on a failed take points at, or why it can't.
    enum TakeReveal: Equatable {
        case reveal(URL)
        case deleted(restorable: Bool)
    }

    /// Reveal in Finder on a failed take's Stage: the entry its failure saved, selected as a library row selects it.
    func revealFailedTake() {
        guard let take = recording, let failure = take.failure else { return }
        Task { [weak self] in
            guard let self else { return }
            switch await self.takeReveal(for: failure) {
            case .reveal(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .deleted(let restorable):
                // As Retry does: the failed Stage has nothing left to offer, and its notice would wait behind it.
                self.endSession(of: take.takeID)
                self.releaseTakeFile(failure.audioURL)
                self.exportNotice = Self.deletedTakeNotice(restorable: restorable)
            case nil:
                break
            }
        }
    }

    /// The entry's bundle while it is in the library; a deleted one is said to be deleted, and an unsaved take shows its working file.
    func takeReveal(for failure: RecordingSession.Failure) async -> TakeReveal? {
        if let entry = try? await failure.save?.value {
            if let live = await library.list().first(where: { $0.id == entry.id }) { return .reveal(live.bundleURL) }
            let restorable = await library.listDeleted().contains { $0.id == entry.id }
            return .deleted(restorable: restorable)
        }
        return FileManager.default.fileExists(atPath: failure.audioURL.path) ? .reveal(failure.audioURL) : nil
    }

    /// Reveal in Finder or Retry on a take whose entry was deleted says so, and leads to Recently Deleted while the entry is still there.
    static func deletedTakeNotice(restorable: Bool) -> ExportNotice {
        guard restorable else {
            return ExportNotice(message: String(localized: "This recording was deleted."), failures: [], folder: nil, tone: .info)
        }
        return ExportNotice(
            message: String(localized: "This recording was deleted. Restore it from Recently Deleted to try again."),
            failures: [], folder: nil, tone: .info,
            actions: [ExportNotice.Action(title: String(localized: "Show Recently Deleted"), handler: .openRecentlyDeleted)]
        )
    }

    /// Re-runs a failed take's transcription in the entry its failure saved, so no twin appears; from its working file when that save never landed.
    func retryTake(_ failure: RecordingSession.Failure) {
        let url = failure.audioURL
        Task { [weak self] in
            if let entry = try? await failure.save?.value, let self {
                guard await self.library.list().contains(where: { $0.id == entry.id }) else {
                    // The user deleted this take, so a working file a failed Stage still held goes too, the last copy once the entry is purged; a later sweep would bring it back.
                    self.releaseTakeFile(url)
                    let restorable = await self.library.listDeleted().contains { $0.id == entry.id }
                    self.exportNotice = Self.deletedTakeNotice(restorable: restorable)
                    return
                }
                if let record = self.micTrackRecords[entry.id] { await self.foldWaitingMicTrack(record, intoEntry: entry.id, notifies: false) }
                if (try? await self.openEntry(entry.id)) != nil {
                    self.retranscribeCurrentEntry(model: self.selectedModel, language: self.selectedLanguage, landingAs: .retriedTake)
                    self.releaseTakeFile(url)
                    return
                }
            }
            self?.startTakeTask { [weak self] in
                await self?.transcribeRecordedTake(
                    url: url, title: failure.title, source: failure.source, category: failure.category,
                    replacing: failure.recovery, annotations: failure.annotations
                )
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

    nonisolated private static let coreAudioQueue = DispatchQueue(label: "app.parola.core-audio", qos: .userInitiated)

    /// CoreAudio can take 30 s to answer a call; on one serial queue a stall holds one thread, never the shared pool a take's start waits on.
    nonisolated static func askCoreAudio<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            coreAudioQueue.async { continuation.resume(returning: work()) }
        }
    }

    func openProjectDocument(at url: URL) async {
        do {
            let doc = try await Self.offMainIO { try ParolaDocument.read(at: url) }
            leaveFinishedStage()
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
            phase = .failed(message: String(localized: "Couldn't open document: \(FailureText.message(for: error))"))
        }
    }

    func saveProjectDocument() {
        guard let transcript, let sourceFileURL else { return }
        // A take still playing from its working file goes by its title, never the file's name.
        let name = recordedTakeTitle(playing: sourceFileURL).map(TranscriptShareFile.safeName(for:))
            ?? sourceFileURL.deletingPathExtension().lastPathComponent
        let suggested = name + ".parola"
        // A copy of a link's entry is still a link; with nothing loaded the writer derives it as before.
        let entrySource = libraryEntries.first { $0.id == selectedEntryID }?.manifest.source
        Task { [weak self] in
            guard let self else { return }
            guard let dest = await self.filePicker.chooseSaveDestination(suggestedName: suggested, allowedTypes: []) else { return }
            do {
                try await AppModel.offMainIO {
                    let written = try ParolaDocument.write(
                        transcript: transcript, audioURL: sourceFileURL, to: dest, entrySource: entrySource
                    )
                    OutputMarker.mark(written)
                }
            } catch {
                ParolaLog.error(.export, "document save failed", [.error: .error(error)])
                self.exportNotice = .failed(error)
            }
        }
    }

    // MARK: - Summary

    var summaryError: String?
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
        String(localized: "Burn failed: \(FailureText.message(for: error, bundle: bundle))", bundle: bundle)
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
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}
