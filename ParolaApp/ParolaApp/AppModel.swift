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
    private var batchTask: Task<Void, Never>?

    @Published var findIsOpen: Bool = false
    @Published var findQuery: String = "" { didSet { scheduleRecomputeMatches() } }
    @Published var findCaseSensitive: Bool = false { didSet { scheduleRecomputeMatches() } }
    @Published var findReplacement: String = ""
    @Published var matches: [TranscriptMatch] = []
    @Published var currentMatchIndex: Int = 0
    private var matchesDebounce: Task<Void, Never>?

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
    private var playerTimeObserver: Any?
    private var timeControlObserver: NSKeyValueObservation?
    private var playerInstallToken: Int = 0

    @Published var pendingExport: ExportFormat?

    // MARK: - Post-process rules

    @Published var ignoredSegmentRules: [IgnoredSegmentRule] = [] {
        didSet { saveIgnoredSegmentRules() }
    }

    @Published var findReplaceRules: [FindReplaceRule] = [] {
        didSet { saveFindReplaceRules() }
    }

    private func loadIgnoredSegmentRules() {
        guard let data = UserDefaults.standard.data(forKey: "ignoredSegmentRules"),
              let rules = try? JSONDecoder().decode([IgnoredSegmentRule].self, from: data) else { return }
        ignoredSegmentRules = rules
    }

    private func saveIgnoredSegmentRules() {
        if let data = try? JSONEncoder().encode(ignoredSegmentRules) {
            UserDefaults.standard.set(data, forKey: "ignoredSegmentRules")
        }
    }

    private func loadFindReplaceRules() {
        guard let data = UserDefaults.standard.data(forKey: "findReplaceRules"),
              let rules = try? JSONDecoder().decode([FindReplaceRule].self, from: data) else { return }
        findReplaceRules = rules
    }

    private func saveFindReplaceRules() {
        if let data = try? JSONEncoder().encode(findReplaceRules) {
            UserDefaults.standard.set(data, forKey: "findReplaceRules")
        }
    }

    // MARK: - People (speakers)

    let peopleStore = PeopleStore()
    @Published var showingSpeakersSheet: Bool = false

    func applySpeakerRenames(_ renames: [String: String]) {
        guard var transcript = self.transcript else { return }
        let nonEmpty = renames.compactMapValues { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        for (from, to) in nonEmpty {
            transcript = transcript.renamingSpeaker(from, to: to)
        }
        self.transcript = transcript
        if let id = selectedEntryID {
            Task { [library] in try? await library.updateTranscript(transcript, for: id) }
        }
        Task { [peopleStore] in
            for to in nonEmpty.values {
                _ = await peopleStore.recordUsage(name: to)
            }
        }
    }

    // MARK: - Prompt library

    let promptLibrary = PromptLibrary()
    @Published var promptOutput: PromptOutput?
    @Published var isRunningPrompt: Bool = false

    struct PromptOutput: Identifiable {
        let id = UUID()
        let promptName: String
        let text: String
    }

    func runPrompt(_ prompt: Prompt) {
        guard let transcript = self.transcript else { return }
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try LanguageModelFactory.makeOnDevice(instructions: prompt.instructions)
                let result = try await PromptRunner.run(prompt, on: transcript.text, model: model)
                promptOutput = PromptOutput(promptName: prompt.name, text: result)
            } catch {
                phase = .failed(message: "Prompt failed: \(error.localizedDescription)")
            }
            isRunningPrompt = false
        }
    }

    func generateYouTubeChapters() {
        guard let transcript = self.transcript else { return }
        guard !isRunningPrompt else { return }
        isRunningPrompt = true
        promptOutput = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let model = try LanguageModelFactory.makeOnDevice()
                let result = try await YouTubeChapters.generate(for: transcript, model: model)
                promptOutput = PromptOutput(promptName: "YouTube Chapters", text: result)
            } catch {
                phase = .failed(message: "Chapter generation failed: \(error.localizedDescription)")
            }
            isRunningPrompt = false
        }
    }

    // MARK: - Chat

    func recordChat(history: [ChatMessage]) {
        guard var transcript = self.transcript else { return }
        transcript.chatHistory = history
        self.transcript = transcript
        guard let id = selectedEntryID else { return }
        Task { [library] in
            try? await library.updateTranscript(transcript, for: id)
        }
    }

    func postProcess(_ transcript: Transcript) -> Transcript {
        var out = transcript
        out.segments = IgnoredSegments.apply(rules: ignoredSegmentRules, to: out.segments)
        out.segments = GlobalFindReplace.apply(rules: findReplaceRules, to: out.segments)
        return out
    }

    // MARK: - Auto-export rules

    @Published var autoExportRules: [AutoExportRule] = [] {
        didSet { saveAutoExportRules() }
    }

    private func loadAutoExportRules() {
        guard let data = UserDefaults.standard.data(forKey: "autoExportRules"),
              let rules = try? JSONDecoder().decode([AutoExportRule].self, from: data) else { return }
        autoExportRules = rules
    }

    private func saveAutoExportRules() {
        if let data = try? JSONEncoder().encode(autoExportRules) {
            UserDefaults.standard.set(data, forKey: "autoExportRules")
        }
    }

    private func runAutoExports(transcript: Transcript, sourceURL: URL) {
        let formats = AutoExportEngine.plannedFormats(
            rules: autoExportRules,
            sourceExtension: sourceURL.pathExtension
        )
        for format in formats {
            do {
                let target = sourceURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
                let data = try Exporters.exporter(for: format).render(transcript)
                try data.write(to: target, options: .atomic)
            } catch {
                // Auto-export is best-effort; primary transcription already in the library.
            }
        }
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

    // MARK: - Meeting detection

    @Published var meetingDetectedApp: String?
    private var pendingRecordingCategory: EntryCategory = .transcription
    lazy var meetingDetector: MeetingDetector = MeetingDetector { [weak self] appName in
        self?.meetingDetectedApp = appName
    }

    func startMeetingRecording() {
        meetingDetectedApp = nil
        pendingRecordingCategory = .meeting
        startRecording(source: .systemAudio)
    }

    func dismissMeetingPrompt() {
        meetingDetectedApp = nil
    }

    // MARK: - Library

    let library = LibraryStore()
    @Published var libraryEntries: [LibraryEntry] = []
    @Published var deletedEntries: [LibraryEntry] = []
    @Published var searchResults: [LibraryEntry]?
    @Published var selectedEntryID: LibraryEntry.ID?
    private var searchTask: Task<Void, Never>?
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
        Task { [weak self, library] in
            await library.purgeDeletedOlderThan(days: AppModel.trashRetentionDays, now: Date())
            self?.refreshLibrary()
        }
    }

    // MARK: - Library

    func refreshLibrary() {
        Task { [weak self] in
            guard let self else { return }
            libraryEntries = await library.list()
            deletedEntries = await library.listDeleted()
        }
    }

    func deleteEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.delete(id)
                if selectedEntryID == id { selectedEntryID = nil }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func restoreEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.restore(id)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func purgeEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.purge(id)
                if selectedEntryID == id { selectedEntryID = nil }
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
            refreshLibrary()
        }
    }

    func loadEntry(_ id: LibraryEntry.ID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await library.load(id)
                transcript = loaded.document.transcript
                sourceFileURL = loaded.document.audioURL
                if let audioURL = loaded.document.audioURL {
                    installPlayer(for: audioURL)
                } else {
                    player?.pause()
                    player = nil
                }
                phase = .ready
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    private func persistToLibrary(_ result: Transcript, audioSource: URL?) {
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

    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let matches = await library.search(q)
            guard !Task.isCancelled else { return }
            let scoreByID = Dictionary(uniqueKeysWithValues: matches.map { ($0.entryID, $0.score) })
            let active = await library.list()
            guard !Task.isCancelled else { return }
            searchResults = active
                .filter { scoreByID[$0.id] != nil }
                .sorted { (scoreByID[$0.id] ?? 0) > (scoreByID[$1.id] ?? 0) }
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

    private var currentOptions: TranscriptionOptions {
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

    // MARK: - Batch

    func startBatch(urls: [URL]) {
        batchTask?.cancel()
        let jobs = urls.map { BatchJob(url: $0) }
        batchJobs = jobs
        selectedBatchJobID = jobs.first?.id

        let queue = BatchQueue()
        let opts = currentOptions

        batchTask = Task { @MainActor in
            let events = await queue.process(jobs: jobs, options: opts)
            for await event in events {
                handleBatchEvent(event)
            }
        }
    }

    private func handleBatchEvent(_ event: BatchEvent) {
        switch event {
        case .started(let id):
            mutateBatchJob(id) { $0.status = .transcribing }
            phase = .transcribing(file: batchJobs.first(where: { $0.id == id })?.url ?? URL(fileURLWithPath: "/"))
        case .completed(let id, let transcript):
            mutateBatchJob(id) { $0.status = .done; $0.transcript = transcript; $0.progress = 1 }
            if id == selectedBatchJobID { self.transcript = transcript }
        case .failed(let id, let reason):
            mutateBatchJob(id) { $0.status = .failed; $0.error = reason }
        case .finished:
            phase = .ready
        }
    }

    private func mutateBatchJob(_ id: BatchJob.ID, _ change: (inout BatchJob) -> Void) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        change(&batchJobs[idx])
    }

    func selectBatchJob(_ id: BatchJob.ID) {
        selectedBatchJobID = id
        if let job = batchJobs.first(where: { $0.id == id }), let t = job.transcript {
            transcript = t
            installPlayer(for: job.url)
        }
    }

    func clearBatch() {
        batchTask?.cancel()
        batchTask = nil
        batchJobs = []
        selectedBatchJobID = nil
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

    // MARK: - Player & seek

    private func installPlayer(for url: URL) {
        if let obs = playerTimeObserver, let player {
            player.removeTimeObserver(obs)
        }
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        player?.pause()
        playerTimeObserver = nil
        let p = AVPlayer(url: url)
        player = p
        hasVideo = false
        currentTimeSeconds = 0
        isPlaying = false
        playerInstallToken &+= 1
        let token = playerInstallToken
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            MainActor.assumeIsolated {
                self?.currentTimeSeconds = seconds
                self?.updateCurrentSegment(time: seconds)
            }
        }
        timeControlObserver = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard let self, self.playerInstallToken == token else { return }
            self.hasVideo = !tracks.isEmpty
        }
    }

    private func updateCurrentSegment(time: Double) {
        guard let segments = transcript?.segments else { return }
        let match = segments.first(where: { time >= $0.start && time <= $0.end })
        if currentSegmentID != match?.id {
            currentSegmentID = match?.id
        }
        let newWordID = match?.word(at: time)?.id
        if currentWordID != newWordID {
            currentWordID = newWordID
        }
    }

    func seek(to segment: TranscriptSegment) {
        guard let player else { return }
        let t = CMTime(seconds: segment.start, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
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

    private func scheduleRecomputeMatches() {
        matchesDebounce?.cancel()
        matchesDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.recomputeMatches()
        }
    }

    private func recomputeMatches() {
        guard findIsOpen, let transcript else {
            matches = []
            currentMatchIndex = 0
            return
        }
        matches = transcript.findMatches(findQuery, caseSensitive: findCaseSensitive)
        currentMatchIndex = min(currentMatchIndex, max(matches.count - 1, 0))
        snapToCurrentMatch()
    }

    func goToNextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        snapToCurrentMatch()
    }

    func goToPreviousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        snapToCurrentMatch()
    }

    func replaceCurrentMatch() {
        guard let transcript, !matches.isEmpty else { return }
        let match = matches[currentMatchIndex]
        self.transcript = transcript.applying(replacement: findReplacement, to: match)
        recomputeMatches()
    }

    func replaceAllMatches() {
        guard let transcript, !findQuery.isEmpty else { return }
        self.transcript = transcript.replacingAll(findQuery, with: findReplacement, caseSensitive: findCaseSensitive)
        recomputeMatches()
    }

    private func snapToCurrentMatch() {
        guard !matches.isEmpty else { return }
        let id = matches[currentMatchIndex].segmentID
        currentSegmentID = id
    }

    func match(in segmentID: TranscriptSegment.ID) -> [TranscriptMatch] {
        matches.filter { $0.segmentID == segmentID }
    }

    var currentMatch: TranscriptMatch? {
        guard !matches.isEmpty else { return nil }
        return matches[currentMatchIndex]
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

    func seekTo(chapter: Chapter) {
        guard let player else { return }
        let t = CMTime(seconds: chapter.start, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
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
