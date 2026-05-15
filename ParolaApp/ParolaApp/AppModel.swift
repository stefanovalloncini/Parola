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
    private var playerTimeObserver: Any?

    @Published var pendingExport: ExportFormat?

    // MARK: - Engine

    private let session = TranscriptionSession()
    private let store = ModelStore.shared

    private var liveSource: AudioSource?
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingConsumer: Task<Void, Never>?

    init() {
        refreshModelList()
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
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
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
                transcript = result
                phase = .ready
                refreshModelList()
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
        { [weak self] frac in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phase = .downloadingModel(name: self.selectedModel, progress: frac)
            }
        }
    }

    // MARK: - YouTube URL

    @Published var youtubeURLDraft: String = ""
    @Published var youtubeSheetOpen: Bool = false

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
                transcript = result
                phase = .ready
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
                transcript = result
                phase = .ready
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
        youtubeURLDraft = ""
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
            self.transcript = transcript
            self.livePartialText = ""
            self.phase = .ready
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
                transcript = result
                phase = .ready
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
        player?.pause()
        playerTimeObserver = nil
        let p = AVPlayer(url: url)
        player = p
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            MainActor.assumeIsolated {
                self?.updateCurrentSegment(time: seconds)
            }
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
            installPlayer(for: doc.audioURL)
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
            let text = try Exporters.exporter(for: format).render(transcript)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed(message: "Export failed: \(error.localizedDescription)")
        }
    }
}
