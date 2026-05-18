import Combine
import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ParolaCore

@MainActor
final class AppModel: ObservableObject {

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
            case .microphone: return "Microphone"
            case .systemAudio: return "System audio"
            }
        }
    }

    enum Route: String, Hashable, CaseIterable {
        case transcript
        case batch
        case queue
    }

    @Published var route: Route = .transcript
    @Published var phase: Phase = .idle
    @Published var transcript: Transcript?
    @Published var showingTrash: Bool = false
    @Published var currentSegmentID: TranscriptSegment.ID?
    @Published var currentWordID: WordTiming.ID?

    @Published var liveSegments: [TranscriptSegment] = []
    @Published var livePartialText: String = ""
    @Published var liveVoiceActive: Bool = false
    @AppStorage("useStreaming") var useStreaming: Bool = true
    @AppStorage("wordTimestamps") var wordTimestamps: Bool = false
    @AppStorage("karaokeHighlight") var karaokeHighlight: Bool = true
    @AppStorage("initialPrompt") var initialPrompt: String = ""
    @AppStorage("diarize") var diarize: Bool = false
    @AppStorage("subtitleFPS") var subtitleFPS: Double = 30
    @AppStorage("subtitleCaptionLength") var subtitleCaptionLengthRaw: String = CaptionLength.none.rawValue
    @AppStorage("recentFiles") var recentFilesRaw: String = "[]"
    @AppStorage("micHotkeyKeyCode") var micHotkeyKeyCode: Int = 15 // kVK_ANSI_R
    @AppStorage("micHotkeyModifiers") var micHotkeyModifiers: Int = 786721 // ⌃⌥⌘
    @AppStorage("micHotkeyEnabled") var micHotkeyEnabled: Bool = false

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

    @Published var batchJobs: [BatchJob] = []
    @Published var selectedBatchJobID: BatchJob.ID?
    var batchTask: Task<Void, Never>?

    @AppStorage("batchExportFormats") var batchExportFormatsRaw: String = "txt,srt"
    @AppStorage("batchExportToSourceFolder") var batchExportToSourceFolder: Bool = true
    @AppStorage("batchExportIncludeTimestamps") var batchExportIncludeTimestamps: Bool = false
    @AppStorage("batchExportFormatOptions") var batchExportFormatOptionsJSON: String = "{}"

    @Published var findIsOpen: Bool = false
    @Published var findQuery: String = "" { didSet { scheduleRecomputeMatches() } }
    @Published var findCaseSensitive: Bool = false { didSet { scheduleRecomputeMatches() } }
    @Published var findReplacement: String = ""
    @Published var matches: [TranscriptMatch] = []
    @Published var currentMatchIndex: Int = 0
    var matchesDebounce: Task<Void, Never>?

    @AppStorage("inputDeviceUID") var inputDeviceUID: String = ""

    var preferredInputDeviceUID: String? {
        inputDeviceUID.isEmpty ? nil : inputDeviceUID
    }

    @AppStorage("selectedModel") var selectedModel: String = "openai_whisper-tiny"
    @AppStorage("selectedLanguageRaw") private var selectedLanguageRaw: String = ""
    @AppStorage("translate") var translate: Bool = false

    private var cachedSelectedModel: String = ""
    private var cachedCapabilities: EngineCapabilities = .whisperKitDefaults

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

    @Published var availableModels: [ModelInfo] = []
    @Published var sourceFileURL: URL?

    @Published var player: AVPlayer?
    @Published var hasVideo: Bool = false
    @Published var currentTimeSeconds: Double = 0
    @Published var isPlaying: Bool = false
    var playerTimeObserver: Any?
    var timeControlObserver: NSKeyValueObservation?
    var playerInstallToken: Int = 0

    @Published var pendingExport: ExportFormat?

    // MARK: - Post-process rules

    @Published var ignoredSegmentRules: [IgnoredSegmentRule] = [] {
        didSet { saveIgnoredSegmentRules() }
    }

    @Published var findReplaceRules: [FindReplaceRule] = [] {
        didSet { saveFindReplaceRules() }
    }

    @Published var snippets: [Snippet] = [] {
        didSet {
            saveSnippets()
            applyDictationCleanupPromptChange()
        }
    }

    // MARK: - People (speakers)

    let peopleStore = PeopleStore()
    @Published var showingSpeakersSheet: Bool = false

    // MARK: - Prompt library

    let promptLibrary = PromptLibrary()
    @Published var promptOutput: PromptOutput?
    @Published var isRunningPrompt: Bool = false
    @Published var actionItems: [ActionItem] = []
    @Published var isExtractingActionItems: Bool = false
    @Published var smartChapters: [Chapter] = []
    @Published var isExtractingChapters: Bool = false

    struct PromptOutput: Identifiable {
        let id = UUID()
        let promptName: String
        let text: String
    }

    // MARK: - Auto-export rules

    @Published var autoExportRules: [AutoExportRule] = [] {
        didSet { saveAutoExportRules() }
    }

    // MARK: - Watched folders

    lazy var watchedFolders: WatchedFoldersStore = WatchedFoldersStore { [weak self] url in
        self?.transcribe(fileURL: url)
    }

    // MARK: - Live captions

    weak var liveCaptions: LiveCaptionsController?

    func toggleLiveCaptions() {
        guard let liveCaptions else { return }
        Task { await liveCaptions.toggle(options: makeOptions(task: .transcribe)) }
    }

    // MARK: - Dictation

    @Published var dictationEnabled: Bool = UserDefaults.standard.bool(forKey: "dictationEnabled") {
        didSet {
            UserDefaults.standard.set(dictationEnabled, forKey: "dictationEnabled")
            applyDictationEnabledChange()
        }
    }

    @Published var dictationModeRaw: String = AppModel.readString("dictationModeRaw", default: DictationMode.pushToTalk.rawValue) {
        didSet {
            UserDefaults.standard.set(dictationModeRaw, forKey: "dictationModeRaw")
            applyDictationModeChange()
        }
    }

    @Published var dictationKeyCode: Int = AppModel.readInt("dictationKeyCode", default: 96) {
        didSet {
            UserDefaults.standard.set(dictationKeyCode, forKey: "dictationKeyCode")
            restartDictation()
        }
    }

    @Published var dictationKeyModifiers: Int = AppModel.readInt("dictationKeyModifiers", default: 0) {
        didSet {
            UserDefaults.standard.set(dictationKeyModifiers, forKey: "dictationKeyModifiers")
            restartDictation()
        }
    }

    var dictationModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(dictationKeyModifiers))
            .intersection(.deviceIndependentFlagsMask)
    }

    @Published var dictationIndicatorStyleRaw: String = AppModel.readString("dictationIndicatorStyleRaw", default: DictationIndicatorStyle.overlay.rawValue) {
        didSet {
            UserDefaults.standard.set(dictationIndicatorStyleRaw, forKey: "dictationIndicatorStyleRaw")
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

    @AppStorage("appTheme") var appTheme: String = "system"  // "system" | "light" | "dark"
    @AppStorage("monospacedTimestamps") var monospacedTimestamps: Bool = true
    @AppStorage("sidebarDensity") var sidebarDensity: String = "comfortable"  // "comfortable" | "compact"

    var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    @Published var dictationCleanupPromptID: String = AppModel.readString("dictationCleanupPromptID", default: "") {
        didSet {
            UserDefaults.standard.set(dictationCleanupPromptID, forKey: "dictationCleanupPromptID")
            applyDictationCleanupPromptChange()
        }
    }

    @Published var dictationPerAppOverridesJSON: String = AppModel.readString("dictationPerAppOverridesJSON", default: "{}") {
        didSet {
            UserDefaults.standard.set(dictationPerAppOverridesJSON, forKey: "dictationPerAppOverridesJSON")
            applyDictationCleanupPromptChange()
            restartDictation()
        }
    }

    static let dictationOverrideApps: [(bundleID: String, name: String)] = [
        ("com.apple.mail", "Mail"),
        ("com.apple.MobileSMS", "Messages"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.Notes", "Notes"),
    ]

    let dictationController = DictationController()
    var dictationCancellables: Set<AnyCancellable> = []

    @Published var dictationState: DictationCoordinator.State = .idle
    @Published var dictationAudioLevel: Float = 0
    @Published var dictationPartialText: String = ""
    @Published var recordingAudioLevel: Float = 0
    var recordingLevelTask: Task<Void, Never>?

    private static func readString(_ key: String, default fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    private static func readInt(_ key: String, default fallback: Int) -> Int {
        if UserDefaults.standard.object(forKey: key) == nil { return fallback }
        return UserDefaults.standard.integer(forKey: key)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Meeting detection

    @Published var meetingDetectedApp: String?
    var pendingRecordingCategory: EntryCategory = .transcription
    lazy var meetingDetector: MeetingDetector = MeetingDetector { [weak self] appName in
        self?.meetingDetectedApp = appName
    }

    // MARK: - Library

    let library = LibraryStore()
    @Published var libraryEntries: [LibraryEntry] = []
    @Published var deletedEntries: [LibraryEntry] = []
    @Published var searchResults: [LibraryEntry]?
    @Published var selectedEntryID: LibraryEntry.ID?
    @Published var libraryFilter: EntryCategory?
    @Published var librarySortOrder: LibrarySortOrder = .newest {
        didSet { reapplyLibrarySort() }
    }
    var libraryBundleSizes: [String: Int64] = [:]
    var searchTask: Task<Void, Never>?
    static let trashRetentionDays = 30

    // MARK: - Engine

    private let session = TranscriptionSession()
    private let store = ModelStore.shared

    private var liveSource: AudioSource?
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingConsumer: Task<Void, Never>?
    private var fileTranscribeTask: Task<Void, Never>?
    private var youtubeTranscribeTask: Task<Void, Never>?
    private var youtubeSubsTask: Task<Void, Never>?
    private var lastDownloadPercent: Int = -1

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
        pendingRecordingCategory = .transcription
        phase = .idle
    }

    private var testBridge: ParolaTestBridge?
    @Published private(set) var automationBridgeRunning: Bool = false
    @Published private(set) var automationBridgePort: UInt16?

    @AppStorage("automationBridgeEnabled") var automationBridgeEnabled: Bool = AppModel.defaultBridgeEnabled

    static var defaultBridgeEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Sparkle

    @AppStorage("sparkleChannel") var sparkleChannelRaw: String = SparkleChannel.stable.rawValue {
        didSet { applySparkleChannelChange() }
    }

    @AppStorage("sparkleAutomatic") var sparkleAutomatic: Bool = true {
        didSet { SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic }
    }

    var sparkleChannel: SparkleChannel {
        SparkleChannel(rawValue: sparkleChannelRaw) ?? .stable
    }

    private func applySparkleChannelChange() {
        SparkleUpdater.shared.channel = sparkleChannel
    }

    // MARK: - Live captions translation

    @AppStorage("liveCaptionsTranslate") var liveCaptionsTranslate: Bool = false {
        didSet { applyLiveCaptionsTranslateChange() }
    }

    private func applyLiveCaptionsTranslateChange() {
        let enabled = liveCaptionsTranslate
        Task { await liveCaptions?.setTranslate(enabled) }
    }

    func startAutomationBridge() {
        guard testBridge == nil else { return }
        guard let bridge = try? ParolaTestBridge(model: self) else { return }
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

    init() {
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        loadSnippets()
        refreshModelList()
        refreshYtDlpAvailability()
        refreshLibrary()
        _ = watchedFolders
        _ = meetingDetector
        wireDictationController()
        if dictationEnabled { startDictation() }
        SparkleUpdater.shared.channel = sparkleChannel
        SparkleUpdater.shared.automaticallyChecks = sparkleAutomatic
        let initialTranslate = liveCaptionsTranslate
        Task { [weak self] in await self?.liveCaptions?.setTranslate(initialTranslate) }
        if automationBridgeEnabled {
            startAutomationBridge()
        }
        Task { [weak self, library] in
            await library.purgeDeletedOlderThan(days: AppModel.trashRetentionDays, now: Date())
            self?.refreshLibrary()
        }
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

    func refreshModelList() {
        let curated = store.catalog()
        let extra = (try? store.installedModels())?.filter { ent in
            !curated.contains { $0.name == ent.name }
        } ?? []
        availableModels = curated + extra

        if !availableModels.contains(where: { $0.name == selectedModel }) {
            selectedModel = availableModels.first?.name ?? "openai_whisper-tiny"
        }
    }

    func deleteModel(_ name: String) {
        do {
            try store.delete(variant: name)
            refreshModelList()
        } catch {
            phase = .failed(message: "Could not delete \(name): \(error.localizedDescription)")
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if panel.urls.count == 1 {
            transcribe(fileURL: panel.urls[0])
        } else {
            startBatch(urls: panel.urls)
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
                    downloadProgress: makeDownloadProgressHandler()
                )
                try Task.checkCancellation()
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                refreshModelList()
                persistToLibrary(processed, audioSource: fileURL)
            } catch {
                applyTranscriptionError(error)
            }
            self.fileTranscribeTask = nil
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

    @Published var youtubeSheetOpen: Bool = false
    @Published var ytDlpAvailable: Bool = false
    @Published var ytDlpInstalling: Bool = false
    @Published var ytDlpInstallError: String?

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
        guard let url = URL(string: urlString), url.isYouTubeVideo else {
            phase = .failed(message: "That doesn't look like a YouTube URL.")
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
        if source == .microphone && useStreaming {
            startStreamingMic()
            return
        }
        Task {
            do {
                phase = .recording(source: source)
                switch source {
                case .microphone:
                    let mic = MicAudioSource(deviceUID: preferredInputDeviceUID)
                    try await mic.start()
                    liveSource = mic
                    observeRecordingLevels(from: mic)
                case .systemAudio:
                    let sys = SystemAudioSource()
                    try await sys.start()
                    liveSource = sys
                    observeRecordingLevels(from: sys)
                }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    private func observeRecordingLevels(from mic: MicAudioSource) {
        recordingLevelTask?.cancel()
        recordingLevelTask = Task { @MainActor [weak self] in
            let stream = await mic.levels()
            for await value in stream {
                guard let self else { return }
                if abs(self.recordingAudioLevel - value) > 0.01 {
                    self.recordingAudioLevel = value
                }
            }
        }
    }

    private func observeRecordingLevels(from system: SystemAudioSource) {
        recordingLevelTask?.cancel()
        recordingLevelTask = Task { @MainActor [weak self] in
            let stream = await system.levels()
            for await value in stream {
                guard let self else { return }
                if abs(self.recordingAudioLevel - value) > 0.01 {
                    self.recordingAudioLevel = value
                }
            }
        }
    }

    private func stopRecordingLevelObserver() {
        recordingLevelTask?.cancel()
        recordingLevelTask = nil
        recordingAudioLevel = 0
    }

    private func startStreamingMic() {
        let s = StreamingTranscriptionSession()
        streamingSession = s
        liveSegments = []
        livePartialText = ""
        liveVoiceActive = false
        phase = .recording(source: .microphone)

        let opts = currentOptions
        let progress = makeDownloadProgressHandler()

        streamingConsumer = Task { @MainActor in
            do {
                let events = try await s.start(options: opts, downloadProgress: progress)
                phase = .recording(source: .microphone)
                for await event in events {
                    handleStreamingEvent(event)
                }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
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
        if let s = streamingSession {
            Task { @MainActor in
                await s.stop()
                streamingSession = nil
                streamingConsumer?.cancel()
                streamingConsumer = nil
                stopRecordingLevelObserver()
            }
            return
        }

        guard let source = liveSource else { return }
        Task {
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
        if findIsOpen { scheduleRecomputeMatches() }
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
        if !findIsOpen {
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
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceFileURL.deletingPathExtension().lastPathComponent + ".parola"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            _ = try ParolaDocument.write(transcript: transcript, audioURL: sourceFileURL, to: dest)
        } catch {
            phase = .failed(message: "Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Summary

    @Published var isSummarising: Bool = false
    @Published var summaryError: String?
    private var summaryGeneration: Int = 0

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

        let open = NSOpenPanel()
        open.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        open.allowsMultipleSelection = false
        open.message = "Pick the video to burn subtitles into."
        guard open.runModal() == .OK, let videoURL = open.url else { return }

        let save = NSSavePanel()
        save.allowedContentTypes = [.mpeg4Movie]
        save.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + " (captioned).mp4"
        guard save.runModal() == .OK, let outputURL = save.url else { return }

        let snapshot = transcript
        phase = .transcribing(file: outputURL)
        Task {
            do {
                try await SubtitleBurner.burn(transcript: snapshot, video: videoURL, to: outputURL)
                phase = .ready
            } catch {
                phase = .failed(message: "Burn failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Export

    func exportRequest(_ format: ExportFormat) {
        guard transcript != nil else { return }
        pendingExport = format
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try makeExporter(for: format).render(transcript)
            try data.write(to: url, options: .atomic)
        } catch {
            phase = .failed(message: "Export failed: \(error.localizedDescription)")
        }
    }

    var subtitleCaptionLength: CaptionLength {
        CaptionLength(rawValue: subtitleCaptionLengthRaw) ?? .none
    }

    func makeExporter(for format: ExportFormat) -> TranscriptExporter {
        switch format {
        case .srt: return SrtExporter(options: SubtitleOptions(captionLength: subtitleCaptionLength))
        case .vtt: return VttExporter(options: SubtitleOptions(captionLength: subtitleCaptionLength))
        default:   return Exporters.exporter(for: format)
        }
    }
}

