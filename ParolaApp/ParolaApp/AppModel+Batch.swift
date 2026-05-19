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
        let jobs = urls.map { BatchJob(url: $0) }
        batchJobs = jobs
        selectedBatchJobID = jobs.first?.id
        route = .batch
        runBatchTask(jobs: jobs)
    }

    private func handleBatchEvent(_ event: BatchEvent) {
        switch event {
        case .started(let id):
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.status = .transcribing }
            phase = .transcribing(file: batchJobs.first(where: { $0.id == id })?.url ?? URL(fileURLWithPath: "/"))
        case .completed(let id, let transcript):
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.status = .done; $0.transcript = transcript; $0.progress = 1 }
            if id == selectedBatchJobID { self.transcript = transcript }
            if let job = batchJobs.first(where: { $0.id == id }) {
                writeBatchExports(transcript: transcript, sourceURL: job.url)
            }
        case .failed(let id, let reason):
            guard !isCancelled(id) else { return }
            mutateBatchJob(id) { $0.status = .failed; $0.error = reason }
        case .cancelled(let id):
            mutateBatchJob(id) { $0.status = .cancelled }
        case .finished:
            phase = .ready
            let pending = batchJobs.filter { $0.status == .pending }
            if !pending.isEmpty {
                resumeBatch(pendingJobs: pending)
            }
        }
    }

    private func resumeBatch(pendingJobs: [BatchJob]) {
        runBatchTask(jobs: pendingJobs)
    }

    private func runBatchTask(jobs: [BatchJob]) {
        batchTask?.cancel()
        let queue = BatchQueue()
        let opts = currentOptions
        batchTask = Task { @MainActor [weak self] in
            let events = await queue.process(jobs: jobs, options: opts)
            for await event in events {
                if Task.isCancelled { break }
                self?.handleBatchEvent(event)
            }
        }
    }

    private func writeBatchExports(transcript: Transcript, sourceURL: URL) {
        let formats = batchExportFormats
        guard !formats.isEmpty else { return }
        let plans: [(ExportFormat, URL)] = formats.compactMap { format in
            let opts = options(for: format)
            guard opts.writeToSourceFolder else { return nil }
            let url = sourceURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
            return (format, url)
        }
        guard !plans.isEmpty else { return }
        Task.detached {
            for (format, target) in plans {
                do {
                    let data = try Exporters.exporter(for: format).render(transcript)
                    try data.write(to: target, options: .atomic)
                } catch {
                    // Sidecar write is best-effort; the transcript is already saved.
                }
            }
        }
    }

    func addBatchFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if batchIsRunning {
            batchJobs.append(contentsOf: urls.map { BatchJob(url: $0) })
        } else if batchJobs.isEmpty {
            startBatch(urls: urls)
        } else {
            let newJobs = urls.map { BatchJob(url: $0) }
            batchJobs.append(contentsOf: newJobs)
            resumeBatch(pendingJobs: newJobs)
        }
    }

    var batchIsRunning: Bool {
        batchJobs.contains { $0.status == .transcribing }
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
        runBatchTask(jobs: [batchJobs[idx]])
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
        transcript = t
        installPlayer(for: job.url)
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
