import Foundation
import SwiftUI
import AppKit
import ParolaCore

struct BatchExportFormatOptions: Codable, Hashable, Sendable {
    var writeToSourceFolder: Bool
    var includeTimestamps: Bool

    static let defaults = BatchExportFormatOptions(writeToSourceFolder: true, includeTimestamps: false)
}

extension AppModel {

    private static let batchOptionsDecoder = JSONDecoder()
    private static let batchOptionsEncoder = JSONEncoder()

    var batchExportFormatOptions: [String: BatchExportFormatOptions] {
        get {
            guard let data = batchExportFormatOptionsJSON.data(using: .utf8),
                  let decoded = try? Self.batchOptionsDecoder.decode([String: BatchExportFormatOptions].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            let data = (try? Self.batchOptionsEncoder.encode(newValue)) ?? Data()
            batchExportFormatOptionsJSON = String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    func options(for format: ExportFormat) -> BatchExportFormatOptions {
        if let stored = batchExportFormatOptions[format.rawValue] { return stored }
        return BatchExportFormatOptions(
            writeToSourceFolder: batchExportToSourceFolder,
            includeTimestamps: batchExportIncludeTimestamps
        )
    }

    func setOptions(_ options: BatchExportFormatOptions, for format: ExportFormat) {
        var current = batchExportFormatOptions
        current[format.rawValue] = options
        batchExportFormatOptions = current
    }

    var batchExportFormats: [ExportFormat] {
        get {
            batchExportFormatsRaw
                .split(separator: ",")
                .compactMap { ExportFormat(rawValue: String($0)) }
        }
        set {
            batchExportFormatsRaw = newValue.map(\.rawValue).joined(separator: ",")
        }
    }

    func addBatchExportFormat(_ format: ExportFormat) {
        var formats = batchExportFormats
        guard !formats.contains(format) else { return }
        formats.append(format)
        batchExportFormats = formats
    }

    func removeBatchExportFormat(_ format: ExportFormat) {
        batchExportFormats = batchExportFormats.filter { $0 != format }
    }

    func startBatch(urls: [URL]) {
        guard features.isEnabled(.batch) else {
            phase = .failed(message: ParolaError.featureDisabled(.batch).description)
            return
        }
        // Replacing batchJobs would strand the running job and the pending ones Resume waits on.
        if batchJobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) {
            addBatchFiles(urls)
            return
        }
        // A single-file or YouTube run owns phase and transcript until it drains; starting here
        // would let both flows write them and leave whichever finished last on screen.
        if phaseDefersArrivals || transcribeTaskRunning {
            deferredArrivals.append(contentsOf: urls)
            return
        }
        let jobs = urls.map { BatchJob(url: $0) }
        batchJobs = jobs
        selectedBatchJobID = jobs.first?.id
        route = .batch
        runBatchTask(jobs: jobs)
    }

    func handleBatchEvent(_ event: BatchEvent) async {
        switch event {
        case .started(let id):
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.status = .transcribing }
            // A live recording owns the phase: every stop affordance is keyed on .recording,
            // so a batch overwrite would leave a hot mic nothing can reach.
            if !recordingActive {
                phase = .transcribing(file: batchJobs.first(where: { $0.id == id })?.url ?? URL(fileURLWithPath: "/"))
            }
        case .progress(let id, let fraction):
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.progress = max($0.progress, fraction) }
        case .completed(let id, let transcript):
            guard !isCancelled(id) else { return }
            let processed = await postProcessDetached(transcript)
            // Re-check: a cancel that lands during the post-process await must not be
            // overwritten to .done, and its exports must not run.
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.status = .done; $0.transcript = processed; $0.progress = 1 }
            if id == selectedBatchJobID {
                clearDerivedArtifacts()
                selectedEntryID = nil
                self.transcript = processed
            }
            if let job = batchJobs.first(where: { $0.id == id }) {
                let sidecarTargets = writeBatchExports(transcript: processed, sourceURL: job.url)
                runAutoExports(transcript: processed, sourceURL: job.url, skippingTargets: sidecarTargets)
                persistBatchJobToLibrary(processed, sourceURL: job.url)
            }
        case .failed(let id, let reason):
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.status = .failed; $0.error = reason }
        case .cancelled(let id):
            mutateBatchJob(id) { $0.status = .cancelled }
        case .finished:
            if !recordingActive {
                phase = .ready
            }
            refreshLibrary()
            // Draining alongside a resume would hand the queue two competing batch tasks; the
            // pending wave ends in another .finished, and the parked files drain there.
            let pending = batchJobs.filter { $0.status == .pending }
            if pending.isEmpty {
                drainDeferredArrivals()
            } else {
                resumeBatch(pendingJobs: pending)
            }
        }
    }

    // Skips persistToLibrary on purpose: its runAutoExports call would fire a second time
    // (handleBatchEvent already ran the rules), and it would steal selection + refresh per job.
    private func persistBatchJobToLibrary(_ transcript: Transcript, sourceURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await library.add(transcript: transcript, audioSource: sourceURL, category: .transcription)
            } catch {
                nonFatalWarning = "\(sourceURL.lastPathComponent) was transcribed, but Parola couldn't save it to your library. \(error.localizedDescription)"
            }
        }
    }

    private func resumeBatch(pendingJobs: [BatchJob]) {
        runBatchTask(jobs: pendingJobs)
    }

    private func runBatchTask(jobs: [BatchJob]) {
        batchTask?.cancel()
        let queue = BatchQueue(session: session, features: features)
        let opts = currentOptions
        batchTask = Task { @MainActor [weak self] in
            let events = await queue.process(jobs: jobs, options: opts)
            for await event in events {
                if Task.isCancelled { break }
                await self?.handleBatchEvent(event)
            }
        }
    }

    nonisolated static func batchExporter(
        for format: ExportFormat,
        includeTimestamps: Bool,
        captionLength: CaptionLength,
        htmlTheme: HtmlExportTheme
    ) -> any TranscriptExporter {
        switch format {
        case .txt:  TxtExporter(options: TxtOptions(showTimestamps: includeTimestamps))
        case .srt:  SrtExporter(options: SubtitleOptions(captionLength: captionLength))
        case .vtt:  VttExporter(options: SubtitleOptions(captionLength: captionLength))
        case .md:   MarkdownExporter(options: MarkdownOptions(showTimestamps: includeTimestamps))
        case .html: HtmlExporter(options: HtmlOptions(theme: htmlTheme, showTimestamps: includeTimestamps))
        default:    Exporters.exporter(for: format)
        }
    }

    @discardableResult
    private func writeBatchExports(transcript: Transcript, sourceURL: URL) -> Set<URL> {
        let formats = batchExportFormats
        guard !formats.isEmpty else { return [] }
        let plans: [(ExportFormat, URL, Bool)] = formats.compactMap { format in
            let opts = options(for: format)
            guard opts.writeToSourceFolder else { return nil }
            let url = sourceURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
            return (format, url, opts.includeTimestamps)
        }
        guard !plans.isEmpty else { return [] }
        let captionLength = subtitleCaptionLength
        let htmlTheme = HtmlExportTheme(rawValue: htmlExportThemeRaw) ?? .light
        Task.detached {
            for (format, target, includeTimestamps) in plans {
                do {
                    let exporter = AppModel.batchExporter(
                        for: format,
                        includeTimestamps: includeTimestamps,
                        captionLength: captionLength,
                        htmlTheme: htmlTheme
                    )
                    let data = try exporter.render(transcript)
                    try data.write(to: target, options: .atomic)
                } catch {
                    // Sidecar write is best-effort; the transcript is already saved.
                }
            }
        }
        return Set(plans.map { $0.1 })
    }

    func addBatchFiles(_ urls: [URL]) {
        guard features.isEnabled(.batch) else {
            phase = .failed(message: ParolaError.featureDisabled(.batch).description)
            return
        }
        guard !urls.isEmpty else { return }
        if batchIsRunning {
            batchJobs.append(contentsOf: urls.map { BatchJob(url: $0) })
        } else if batchJobs.isEmpty {
            startBatch(urls: urls)
        } else if phaseDefersArrivals || transcribeTaskRunning {
            deferredArrivals.append(contentsOf: urls)
        } else {
            let newJobs = urls.map { BatchJob(url: $0) }
            batchJobs.append(contentsOf: newJobs)
            resumeBatch(pendingJobs: newJobs)
        }
    }

    func drainDeferredArrivals() {
        guard !deferredArrivals.isEmpty || !deferredLinks.isEmpty else { return }
        let urls = deferredArrivals
        deferredArrivals = []
        let parolaURLs = urls.filter { $0.pathExtension == "parola" }
        let subtitleURLs = urls.filter(Self.isSubtitleImport)
        let audioURLs = urls.filter { $0.pathExtension != "parola" && !Self.isSubtitleImport($0) }
        // Subtitles first: a batch kicked off by addBatchFiles could flip batchIsRunning and re-defer them.
        for url in subtitleURLs { importSubtitle(fileURL: url) }
        if !audioURLs.isEmpty {
            if features.isEnabled(.batch) {
                addBatchFiles(audioURLs)
            } else {
                transcribe(fileURL: audioURLs[0])
                deferredArrivals.append(contentsOf: audioURLs.dropFirst())
            }
        }
        for url in parolaURLs {
            Task { [weak self] in await self?.openProjectDocument(at: url) }
        }
        let links = deferredLinks
        deferredLinks = []
        for link in links { transcribeYouTube(urlString: link) }
    }

    var batchIsRunning: Bool {
        batchJobs.contains { $0.status == .transcribing }
    }

    // MARK: - Queue persistence across quit

    var batchQueueFileURL: URL {
        library.libraryURL.appendingPathComponent("batch-queue.json")
    }

    func saveBatchQueueSnapshot() {
        let restorable: Set<BatchJob.Status> = [.pending, .transcribing, .failed]
        let urls = batchJobs.filter { restorable.contains($0.status) }.map(\.url)
        guard urls != lastSavedBatchQueueURLs else { return }
        lastSavedBatchQueueURLs = urls
        if urls.isEmpty {
            try? FileManager.default.removeItem(at: batchQueueFileURL)
        } else if let data = try? Self.batchOptionsEncoder.encode(urls) {
            try? data.write(to: batchQueueFileURL, options: .atomic)
        }
    }

    /// Rebuilds a queue that a quit interrupted: jobs come back pending and wait for Resume.
    func restoreBatchQueue() {
        guard features.isEnabled(.batch) else { return }
        guard batchJobs.isEmpty,
              let data = try? Data(contentsOf: batchQueueFileURL),
              let urls = try? Self.batchOptionsDecoder.decode([URL].self, from: data),
              !urls.isEmpty
        else { return }
        lastSavedBatchQueueURLs = urls
        batchJobs = urls.map { BatchJob(url: $0) }
        selectedBatchJobID = batchJobs.first?.id
        route = .batch
    }

    var canResumeBatch: Bool {
        batchTask == nil && !batchIsRunning && batchJobs.contains { $0.status == .pending }
    }

    func resumePendingBatchJobs() {
        guard canResumeBatch else { return }
        runBatchTask(jobs: batchJobs.filter { $0.status == .pending })
    }

    func cancelBatchJob(_ id: BatchJob.ID) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = batchJobs[idx]
        switch job.status {
        case .transcribing:
            batchTask?.cancel()
            batchTask = nil
            mutateBatchJob(id) { $0.status = .cancelled }
            phase = .ready
            let remaining = batchJobs.filter { $0.status == .pending }
            if !remaining.isEmpty {
                resumeBatch(pendingJobs: remaining)
            }
        case .pending, .done, .failed, .cancelled:
            batchJobs.remove(at: idx)
            if selectedBatchJobID == id { selectedBatchJobID = batchJobs.first?.id }
        }
    }

    func presentBatchOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Select audio or video files to transcribe."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addBatchFiles(panel.urls)
    }

    private func isCancelled(_ id: BatchJob.ID) -> Bool {
        batchJobs.first(where: { $0.id == id })?.status == .cancelled
    }

    private func mutateBatchJob(_ id: BatchJob.ID, _ change: (inout BatchJob) -> Void) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        change(&batchJobs[idx])
    }

    func selectBatchJob(_ id: BatchJob.ID) {
        selectedBatchJobID = id
        if let job = batchJobs.first(where: { $0.id == id }), let t = job.transcript {
            loadEntryGeneration &+= 1
            let pending = cancelAndDrainPendingTranscriptSave()
            clearDerivedArtifacts()
            selectedEntryID = nil
            transcript = t
            installPlayer(for: job.url)
            adoptLoadedMediaDuration()
            if let pending {
                Task { [library] in
                    try? await library.updateTranscript(pending.transcript, for: pending.id)
                }
            }
        }
    }

    func clearBatch() {
        batchTask?.cancel()
        batchTask = nil
        batchJobs = []
        selectedBatchJobID = nil
    }

    func cancelAllInFlightBatchJobs() {
        batchTask?.cancel()
        batchTask = nil
        for idx in batchJobs.indices where batchJobs[idx].status == .pending || batchJobs[idx].status == .transcribing {
            batchJobs[idx].status = .cancelled
        }
    }

    func retryBatchJob(_ id: BatchJob.ID) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        batchJobs[idx].status = .pending
        batchJobs[idx].error = nil
        batchJobs[idx].progress = 0
        batchJobs[idx].transcript = nil
        // Don't tear down a live batch to retry one file — runBatchTask cancels the running queue and
        // strands the in-flight job. Reset to .pending; the running batch's .finished resume picks it up.
        if !batchIsRunning {
            runBatchTask(jobs: [batchJobs[idx]])
        }
    }

    func clearFinishedBatchJobs() {
        batchJobs.removeAll { $0.status == .done || $0.status == .cancelled || $0.status == .failed }
        if let selected = selectedBatchJobID, !batchJobs.contains(where: { $0.id == selected }) {
            selectedBatchJobID = batchJobs.first?.id
        }
    }

    func openBatchJobTranscript(_ id: BatchJob.ID) {
        guard let job = batchJobs.first(where: { $0.id == id }), let t = job.transcript else { return }
        selectedBatchJobID = id
        loadEntryGeneration &+= 1
        clearDerivedArtifacts()
        selectedEntryID = nil
        transcript = t
        installPlayer(for: job.url)
        adoptLoadedMediaDuration()
        phase = .ready
        route = .transcript
    }

    func reorderPendingBatchJobs(from source: IndexSet, to destination: Int) {
        let pendingIndices = batchJobs.indices.filter { batchJobs[$0].status == .pending }
        guard !pendingIndices.isEmpty else { return }
        var pending = pendingIndices.map { batchJobs[$0] }
        pending.move(fromOffsets: source, toOffset: destination)
        for (pendingPosition, originalIndex) in pendingIndices.enumerated() {
            batchJobs[originalIndex] = pending[pendingPosition]
        }
    }

    func moveBatchJobToTop(_ id: BatchJob.ID) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        guard batchJobs[idx].status == .pending else { return }
        let firstPending = batchJobs.firstIndex(where: { $0.status == .pending }) ?? idx
        if idx != firstPending {
            let job = batchJobs.remove(at: idx)
            batchJobs.insert(job, at: firstPending)
        }
    }

    func moveBatchJob(_ id: BatchJob.ID, before targetID: BatchJob.ID) {
        guard id != targetID else { return }
        guard let sourceIdx = batchJobs.firstIndex(where: { $0.id == id }),
              batchJobs[sourceIdx].status == .pending else { return }
        let job = batchJobs.remove(at: sourceIdx)
        guard let targetIdx = batchJobs.firstIndex(where: { $0.id == targetID }) else {
            batchJobs.append(job)
            return
        }
        batchJobs.insert(job, at: targetIdx)
    }
}
