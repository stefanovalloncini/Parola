import Foundation
import SwiftUI
import AppKit
import ParolaCore

extension AppModel {

    private static let batchQueueDecoder = JSONDecoder()
    private static let batchQueueEncoder = JSONEncoder()

    func startBatch(urls: [URL]) {
        startBatch(jobs: urls.map { BatchJob(url: $0) })
    }

    func startBatch(jobs: [BatchJob]) {
        guard features.isEnabled(.batch) else {
            phase = .failed(message: ParolaError.featureDisabled(.batch).description)
            return
        }
        // Replacing batchJobs would strand the running job and the pending ones Resume waits on.
        if batchJobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) {
            addBatchJobs(jobs)
            return
        }
        // A single-file or YouTube run owns phase and transcript until it drains; starting here
        // would let both flows write them and leave whichever finished last on screen.
        if phaseDefersArrivals || transcribeTaskRunning {
            deferredArrivals.append(contentsOf: jobs.map(\.url))
            return
        }
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
            batchProgress.advance(id, to: fraction)
        case .completed(let id, let transcript):
            guard !isCancelled(id) else { return }
            let processed = await postProcessDetached(transcript)
            // Re-check: a cancel that lands during the post-process await must not be
            // overwritten to .done, and its exports must not run.
            guard !isCancelled(id) else { return }
            batchProgress.advance(id, to: 1)
            mutateBatchJob(id) {
                $0.status = .done
                $0.transcript = processed
                $0.segmentCount = processed.segments.count
            }
            if id == selectedBatchJobID {
                showUnsavedBatchJob(id, processed)
            }
            if let job = batchJobs.first(where: { $0.id == id }) {
                let sidecarTargets = writeBatchExports(transcript: processed, sourceURL: job.url)
                runAutoExports(transcript: processed, sourceURL: job.url, skippingTargets: sidecarTargets)
                persistBatchJobToLibrary(id, transcript: processed, sourceURL: job.url, sourceDigest: job.sourceDigest)
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
            refreshLibraryOnceBatchAddsLand()
            // Draining alongside a resume would hand the queue two competing batch tasks; the
            // pending wave ends in another .finished, and the parked files drain there.
            let pending = batchJobs.filter { $0.status == .pending }
            if pending.isEmpty {
                // Read before the drain: a wave it starts resets the flag, and a run the user
                // cancelled would then ring.
                let wasCancelled = batchRunCancelled
                drainDeferredArrivals()
                // One sound for the run that just ended, whatever mix of done and failed it ended
                // with. Files the drain picked up are a run of their own and ring when they finish.
                if !wasCancelled { playCompletionSound() }
            } else {
                resumeBatch(pendingJobs: pending)
            }
        }
    }

    // Skips persistToLibrary on purpose: its runAutoExports call would fire a second time
    // (handleBatchEvent already ran the rules), and it would steal selection + refresh per job.
    private func persistBatchJobToLibrary(
        _ jobID: BatchJob.ID, transcript: Transcript, sourceURL: URL, sourceDigest digest: String?
    ) {
        let adding = Task { [weak self] () -> LibraryEntry? in
            guard let self else { return nil }
            do {
                let entry = try await library.add(
                    transcript: transcript,
                    audioSource: sourceURL,
                    category: .transcription,
                    sourceDigest: digest,
                    source: .file
                )
                landBatchJobEntry(entry.id, jobID: jobID)
                return entry
            } catch {
                nonFatalWarning = "\(sourceURL.lastPathComponent) was transcribed, but Parola couldn't save it to your library. \(error.localizedDescription)"
                return nil
            }
        }
        batchLibraryAdds.append(adding)
        Task { [weak self] in
            guard let entry = await adding.value else { return }
            self?.enqueueCardMetadata(for: entry.id, transcript: transcript)
        }
    }

    /// Every way a run ends short of its .finished: the refresh that event would have made happens here.
    private func stopBatchRun() {
        batchTask?.cancel()
        batchTask = nil
        if !batchLibraryAdds.isEmpty { refreshLibraryOnceBatchAddsLand() }
    }

    /// Refreshed before the last add returns, the list would miss that file until something else refreshed it.
    private func refreshLibraryOnceBatchAddsLand() {
        let adds = batchLibraryAdds
        batchLibraryAdds = []
        guard !adds.isEmpty else {
            refreshLibrary()
            return
        }
        batchClosingRefresh = Task { [weak self] in
            for add in adds { _ = await add.value }
            self?.refreshLibrary()
        }
    }

    /// A finished job whose library add hasn't returned: its own copy, with no entry to save edits to yet.
    private func showUnsavedBatchJob(_ id: BatchJob.ID, _ transcript: Transcript) {
        let landing = Self.landingSignposter.beginInterval("install")
        defer { Self.landingSignposter.endInterval("install", landing) }
        loadEntryGeneration &+= 1
        clearDerivedArtifacts()
        selectedEntryID = nil
        self.transcript = transcript
        unsavedBatchJobOnScreen = UnsavedBatchJob(jobID: id, install: derivedArtifactsGeneration)
    }

    /// An edit made before the entry exists goes back into the job, so it reaches the entry when the add lands.
    func keepUnsavedBatchEdit() {
        guard selectedEntryID == nil, let transcript, let screen = unsavedBatchJobOnScreen,
              screen.install == derivedArtifactsGeneration else { return }
        unsavedBatchEdits.insert(screen.jobID)
        if let index = batchJobs.firstIndex(where: { $0.id == screen.jobID }), batchJobs[index].entryID == nil {
            batchJobs[index].transcript = transcript
        }
    }

    /// From here the entry holds the transcript: the job lets go of its copy, and a copy still on screen becomes the entry.
    private func landBatchJobEntry(_ entryID: LibraryEntry.ID, jobID: BatchJob.ID) {
        let edited = unsavedBatchEdits.remove(jobID) != nil
        let jobCopy = batchJobs.first(where: { $0.id == jobID })?.transcript
        mutateBatchJob(jobID) {
            $0.entryID = entryID
            $0.transcript = nil
        }
        if let screen = unsavedBatchJobOnScreen, screen.jobID == jobID {
            unsavedBatchJobOnScreen = nil
            if screen.install == derivedArtifactsGeneration, selectedEntryID == nil {
                selectedEntryID = entryID
                if edited { persistCurrentTranscriptIfLoaded() }
                return
            }
        }
        if edited, let jobCopy {
            Task { [library] in
                try? await library.updateTranscript(jobCopy, for: entryID)
            }
        }
    }

    private func resumeBatch(pendingJobs: [BatchJob]) {
        runBatchTask(jobs: pendingJobs)
    }

    private func runBatchTask(jobs: [BatchJob]) {
        batchRunCancelled = false
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

    @discardableResult
    private func writeBatchExports(transcript: Transcript, sourceURL: URL) -> Set<URL> {
        let plans: [(spec: ExportSpec, target: URL)] = batchExportPresets.map { preset in
            (preset.spec, sourceURL.deletingPathExtension().appendingPathExtension(preset.spec.format.fileExtension))
        }
        guard !plans.isEmpty else { return [] }
        Task.detached {
            for plan in plans {
                do {
                    let data = try Exporters.exporter(for: plan.spec).render(transcript)
                    try data.write(to: plan.target, options: .atomic)
                } catch {
                    // Sidecar write is best-effort; the transcript is already saved.
                }
            }
        }
        return Set(plans.map(\.target))
    }

    func addBatchFiles(_ urls: [URL]) {
        addBatchJobs(urls.map { BatchJob(url: $0) })
    }

    func addBatchJobs(_ jobs: [BatchJob]) {
        guard features.isEnabled(.batch) else {
            phase = .failed(message: ParolaError.featureDisabled(.batch).description)
            return
        }
        guard !jobs.isEmpty else { return }
        if batchIsRunning {
            batchJobs.append(contentsOf: jobs)
        } else if batchJobs.isEmpty {
            startBatch(jobs: jobs)
        } else if phaseDefersArrivals || transcribeTaskRunning {
            deferredArrivals.append(contentsOf: jobs.map(\.url))
        } else {
            batchJobs.append(contentsOf: jobs)
            resumeBatch(pendingJobs: jobs)
        }
    }

    func drainDeferredArrivals() {
        guard !deferredArrivals.isEmpty || !deferredLinks.isEmpty else { return }
        let urls = deferredArrivals
        deferredArrivals = []
        let parolaURLs = urls.filter(DroppedFiles.isProject)
        let subtitleURLs = urls.filter(Self.isSubtitleImport)
        let audioURLs = urls.filter { !DroppedFiles.isProject($0) && !Self.isSubtitleImport($0) }
        // Subtitles first: a batch kicked off by addBatchFiles could flip batchIsRunning and re-defer them.
        for url in subtitleURLs { importSubtitle(fileURL: url) }
        if !audioURLs.isEmpty {
            if features.isEnabled(.batch) {
                importBatchFiles(audioURLs)
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
        for link in links {
            switch link {
            case .transcribe(let urlString): transcribeYouTube(urlString: urlString)
            case .subtitles(let urlString): fetchYouTubeSubs(urlString: urlString)
            }
        }
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
        } else if let data = try? Self.batchQueueEncoder.encode(urls) {
            try? data.write(to: batchQueueFileURL, options: .atomic)
        }
    }

    /// Rebuilds a queue that a quit interrupted: jobs come back pending and wait for Resume.
    func restoreBatchQueue() {
        guard features.isEnabled(.batch) else { return }
        guard batchJobs.isEmpty,
              let data = try? Data(contentsOf: batchQueueFileURL),
              let urls = try? Self.batchQueueDecoder.decode([URL].self, from: data),
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
            stopBatchRun()
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
        importBatchFiles(panel.urls)
    }

    private func isCancelled(_ id: BatchJob.ID) -> Bool {
        batchJobs.first(where: { $0.id == id })?.status == .cancelled
    }

    private func mutateBatchJob(_ id: BatchJob.ID, _ change: (inout BatchJob) -> Void) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        change(&batchJobs[idx])
    }

    /// Opens the job's entry in place, or its own copy while the add is in flight; returns the entry's load.
    @discardableResult
    func selectBatchJob(_ id: BatchJob.ID) -> Task<Transcript, any Error>? {
        // An open the last click started must not land over this one.
        loadEntryGeneration &+= 1
        selectedBatchJobID = id
        guard let job = batchJobs.first(where: { $0.id == id }) else { return nil }
        if let entryID = job.entryID {
            guard selectedEntryID != entryID else { return nil }
            return openEntryInPlace(entryID)
        }
        if let t = job.transcript {
            showUnsavedBatchJobReplacingSelection(job, t)
        }
        return nil
    }

    private func showUnsavedBatchJobReplacingSelection(_ job: BatchJob, _ transcript: Transcript) {
        let pending = cancelAndDrainPendingTranscriptSave()
        showUnsavedBatchJob(job.id, transcript)
        installPlayer(for: job.url)
        adoptLoadedMediaDuration()
        if let pending {
            Task { [library] in
                try? await library.updateTranscript(pending.transcript, for: pending.id)
            }
        }
    }

    func clearBatch() {
        stopBatchRun()
        batchJobs = []
        selectedBatchJobID = nil
        batchDuplicatesSkipped = 0
    }

    func cancelAllInFlightBatchJobs() {
        batchRunCancelled = true
        cancelAndTrack(&batchTask)
        stopBatchRun()
        for idx in batchJobs.indices where batchJobs[idx].status == .pending || batchJobs[idx].status == .transcribing {
            batchJobs[idx].status = .cancelled
        }
    }

    func retryBatchJob(_ id: BatchJob.ID) {
        guard let idx = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        batchJobs[idx].status = .pending
        batchJobs[idx].error = nil
        batchJobs[idx].transcript = nil
        batchJobs[idx].entryID = nil
        batchJobs[idx].segmentCount = nil
        // The file may have changed since it was hashed; the add takes its own digest.
        batchJobs[idx].sourceDigest = nil
        batchProgress.reset(id)
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
        guard let job = batchJobs.first(where: { $0.id == id }) else { return }
        if let entryID = job.entryID {
            selectedBatchJobID = id
            loadEntry(entryID)
        } else if let t = job.transcript {
            selectedBatchJobID = id
            showUnsavedBatchJobReplacingSelection(job, t)
            phase = .ready
            route = .transcript
        }
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
