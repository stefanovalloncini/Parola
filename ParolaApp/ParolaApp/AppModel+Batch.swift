import Foundation
import SwiftUI
import AppKit
import ParolaCore

extension AppModel {

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
        case .finished:
            phase = .ready
            let pending = batchJobs.filter { $0.status == .pending }
            if !pending.isEmpty {
                resumeBatch(pendingJobs: pending)
            }
        }
    }

    private func resumeBatch(pendingJobs: [BatchJob]) {
        batchTask?.cancel()
        let queue = BatchQueue()
        let opts = currentOptions
        batchTask = Task { @MainActor in
            let events = await queue.process(jobs: pendingJobs, options: opts)
            for await event in events {
                handleBatchEvent(event)
            }
        }
    }

    private func writeBatchExports(transcript: Transcript, sourceURL: URL) {
        let formats = batchExportFormats
        guard !formats.isEmpty, batchExportToSourceFolder else { return }
        Task.detached {
            for format in formats {
                let target = sourceURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
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

        let job = batchJobs[idx]
        let opts = currentOptions
        batchTask = Task { @MainActor in
            let events = await BatchQueue().process(jobs: [job], options: opts)
            for await event in events {
                handleBatchEvent(event)
            }
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
        transcript = t
        installPlayer(for: job.url)
        phase = .ready
        route = .transcript
    }
}
