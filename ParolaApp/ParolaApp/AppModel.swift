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

    enum Route: Hashable {
        case transcript
        case batch
        case queue
    }

    @Published var route: Route = .transcript
    @Published var phase: Phase = .idle
    @Published var transcript: Transcript?
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

    @Published var batchJobs: [BatchJob] = []
    @Published var selectedBatchJobID: BatchJob.ID?
    var batchTask: Task<Void, Never>?

    @AppStorage("batchExportFormats") var batchExportFormatsRaw: String = "txt,srt"
    @AppStorage("batchExportToSourceFolder") var batchExportToSourceFolder: Bool = true
    @AppStorage("batchExportIncludeTimestamps") var batchExportIncludeTimestamps: Bool = false

    @Published var findIsOpen: Bool = false
    @Published var findQuery: String = "" { didSet { scheduleRecomputeMatches() } }
    @Published var findCaseSensitive: Bool = false { didSet { scheduleRecomputeMatches() } }
    @Published var findReplacement: String = ""
    @Published var matches: [TranscriptMatch] = []
    @Published var currentMatchIndex: Int = 0
    var matchesDebounce: Task<Void, Never>?

    @AppStorage("selectedModel") var selectedModel: String = "openai_whisper-tiny"
    @AppStorage("selectedLanguageRaw") private var selectedLanguageRaw: String = ""
    @AppStorage("translate") var translate: Bool = false

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

    // MARK: - People (speakers)

    let peopleStore = PeopleStore()
    @Published var showingSpeakersSheet: Bool = false

    // MARK: - Prompt library

    let promptLibrary = PromptLibrary()
    @Published var promptOutput: PromptOutput?
    @Published var isRunningPrompt: Bool = false

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

    lazy var liveCaptions: LiveCaptionsController = LiveCaptionsController()

    func toggleLiveCaptions() {
        Task { await liveCaptions.toggle(options: makeOptions(task: .transcribe)) }
    }

    // MARK: - Dictation

    @AppStorage("dictationEnabled") var dictationEnabled: Bool = false {
        didSet { applyDictationEnabledChange() }
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
    @AppStorage("dictationCleanupPromptID") var dictationCleanupPromptID: String = "" {
        didSet { applyDictationCleanupPromptChange() }
    }
    @AppStorage("dictationPerAppOverridesJSON") var dictationPerAppOverridesJSON: String = "{}" {
        didSet { applyDictationCleanupPromptChange() }
    }

    static let dictationOverrideApps: [(bundleID: String, name: String)] = [
        ("com.apple.mail", "Mail"),
        ("com.apple.MobileSMS", "Messages"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.Notes", "Notes"),
    ]

    @Published var dictationState: DictationCoordinator.State = .idle
    var dictationCoordinator: DictationCoordinator?
    var dictationHUD: NSPanel?

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
    var searchTask: Task<Void, Never>?
    static let trashRetentionDays = 30

    // MARK: - Engine

    private let session = TranscriptionSession()
    private let store = ModelStore.shared

    private var liveSource: AudioSource?
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingConsumer: Task<Void, Never>?
    private var lastDownloadPercent: Int = -1

    init() {
        loadAutoExportRules()
        loadIgnoredSegmentRules()
        loadFindReplaceRules()
        refreshModelList()
        refreshYtDlpAvailability()
        refreshLibrary()
        _ = watchedFolders   // touch lazy var to start watchers on launch
        _ = meetingDetector  // touch lazy var to start NSWorkspace observation
        if dictationEnabled { startDictation() }
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
                // Don't fail the transcription if library save fails; the user still has the in-memory result.
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
        sourceFileURL = fileURL
        installPlayer(for: fileURL)

        let task: TranscriptionTask = (translateOverride ?? translate) ? .translate : .transcribe

        Task {
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
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                refreshModelList()
                persistToLibrary(processed, audioSource: fileURL)
            } catch {
                phase = .failed(message: error.localizedDescription)
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

        let buffer = ProcessOutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
            } else {
                buffer.append(chunk)
            }
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure("Could not launch brew: \(error.localizedDescription)")
        }
        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = buffer.string()
                if p.terminationStatus == 0 {
                    cont.resume(returning: .success)
                } else {
                    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: .failure(detail.isEmpty ? "brew exited with status \(p.terminationStatus)." : detail))
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

        Task {
            do {
                phase = .downloadingModel(name: "youtube", progress: 0)
                let source = YouTubeAudioSource(url: url)
                let audioURL = try await source.prepare()
                sourceFileURL = audioURL
                installPlayer(for: audioURL)

                phase = .transcribing(file: audioURL)
                let result = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: currentOptions,
                    downloadProgress: makeDownloadProgressHandler()
                )
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                refreshModelList()
                persistToLibrary(processed, audioSource: audioURL)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func fetchYouTubeSubs(urlString: String) {
        guard let url = makeYouTubeURL(urlString) else { return }

        Task {
            do {
                phase = .transcribing(file: url)
                let result = try await YouTubeSubsFetcher.fetch(url: url, preferLanguage: selectedLanguage)
                let processed = postProcess(result)
                transcript = processed
                phase = .ready
                persistToLibrary(processed, audioSource: nil)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
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
                    let mic = MicAudioSource()
                    try await mic.start()
                    liveSource = mic
                case .systemAudio:
                    let sys = SystemAudioSource()
                    try await sys.start()
                    liveSource = sys
                }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
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
            }
            return
        }

        guard let source = liveSource else { return }
        Task {
            do {
                let url = try await source.prepare()
                liveSource = nil
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
                player?.pause()
                player = nil
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

    func performExport(_ format: ExportFormat) {
        guard let transcript else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Exporters.exporter(for: format).render(transcript)
            try data.write(to: url, options: .atomic)
        } catch {
            phase = .failed(message: "Export failed: \(error.localizedDescription)")
        }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
