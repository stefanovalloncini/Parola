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

    /// `showsActivity` is false for files a finished run drains: the page it landed on stays.
    func startBatch(jobs: [BatchJob], showsActivity: Bool = true) {
        guard features.isEnabled(.batch) else {
            phase = .failed(message: FailureText.message(for: ParolaError.featureDisabled(.batch)))
            return
        }
        // Replacing batchJobs would strand the running job and the pending ones Resume waits on.
        if batchJobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) {
            addBatchJobs(jobs, showsActivity: showsActivity)
            return
        }
        // A single-file or YouTube run owns phase and transcript until it drains; starting here
        // would let both flows write them and leave whichever finished last on screen.
        if takeIsRunning || transcribeTaskRunning {
            deferredArrivals.append(contentsOf: jobs.map(\.url))
            if takeIsRunning { noteRunWaitsForTake() }
            return
        }
        batchJobs = jobs
        selectedBatchJobID = jobs.first?.id
        if showsActivity { showBatchActivity() }
        runBatchTask(jobs: jobs)
    }

    /// A batch that starts or grows opens Activity, so the user sees it run; a take recording, or its Stage, keeps the screen.
    func showBatchActivity() {
        guard !takeIsRunning, route != .recording else { return }
        openQueue()
    }

    /// True while `phase` shows the running job, which the queue shows instead of the transcript route.
    var batchOwnsPhase: Bool {
        guard let batchPhaseFile else { return false }
        return phase == .transcribing(file: batchPhaseFile)
    }

    func handleBatchEvent(_ event: BatchEvent) async {
        switch event {
        case .started(let id):
            guard batchJobIsStillQueued(id) else {
                stopBatchRun()
                resumeWaitingBatchJobs()
                return
            }
            mutateBatchJob(id) { $0.status = .transcribing }
            let file = batchJobs.first(where: { $0.id == id })?.url ?? URL(fileURLWithPath: "/")
            batchPhaseFile = file
            postFailureBeforeBatchPhase()
            phase = .transcribing(file: file)
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
            if let job = batchJobs.first(where: { $0.id == id }) {
                land(.batchJob(job, transcript: processed))
            }
        case .failed(let id, let reason, let error):
            guard !isCancelled(id) else { return }
            let message = error.map { FailureText.message(for: $0) } ?? FailureText.reason(reason)
            mutateBatchJob(id) { $0.status = .failed; $0.error = message }
        case .cancelled(let id):
            mutateBatchJob(id) { $0.status = .cancelled }
        case .finished:
            postFailureBeforeBatchPhase()
            phase = .ready
            batchPhaseFile = nil
            refreshLibraryOnceBatchAddsLand()
            // The pending wave ends in another .finished, and the batch lets go of the foreground there.
            let pending = batchJobs.filter { $0.status == .pending }
            if pending.isEmpty {
                batchTask = nil
                // One sound for the run that just ended, whatever mix of done and failed it ended with.
                if !batchRunCancelled { playCompletionSound() }
            } else {
                resumeBatch(pendingJobs: pending)
            }
        }
    }

    /// A failure from outside the batch, an open or a save, would vanish under the batch's own phase.
    private func postFailureBeforeBatchPhase() {
        if case .failed(let message) = phase { postFailureNotice(message) }
    }

    /// Every way a run ends short of its .finished: the refresh and the phase that event would have settled happen here.
    private func stopBatchRun() {
        batchTask?.cancel()
        batchTask = nil
        if batchOwnsPhase { phase = transcript == nil ? .idle : .ready }
        batchPhaseFile = nil
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
            for add in adds { _ = try? await add.value }
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
    func landBatchJobEntry(_ entryID: LibraryEntry.ID, jobID: BatchJob.ID) {
        let edited = unsavedBatchEdits.remove(jobID) != nil
        let jobCopy = batchJobs.first(where: { $0.id == jobID })?.transcript
        mutateBatchJob(jobID) {
            $0.entryID = entryID
            $0.transcript = nil
        }
        if let screen = unsavedBatchJobOnScreen, screen.jobID == jobID {
            unsavedBatchJobOnScreen = nil
            if screen.install == derivedArtifactsGeneration, selectedEntryID == nil {
                selectLanded(entryID)
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

    private func resumeWaitingBatchJobs() {
        let remaining = batchJobs.filter { $0.status == .pending }
        if !remaining.isEmpty { resumeBatch(pendingJobs: remaining) }
    }

    /// The run holds its own copy of the jobs: one taken off the list or cancelled since must not start.
    func batchJobIsStillQueued(_ id: BatchJob.ID) -> Bool {
        guard let job = batchJobs.first(where: { $0.id == id }) else { return false }
        return job.status != .cancelled
    }

    private func runBatchTask(jobs: [BatchJob]) {
        batchRunCancelled = false
        batchTask?.cancel()
        let queue = BatchQueue(session: session, features: features)
        let opts = currentOptions
        batchTask = Task { @MainActor [weak self] in
            let events = await queue.process(jobs: jobs, options: opts) { [weak self] id in
                await self?.batchJobIsStillQueued(id) ?? false
            }
            for await event in events {
                if Task.isCancelled { break }
                await self?.handleBatchEvent(event)
            }
        }
    }

    func addBatchFiles(_ urls: [URL]) {
        addBatchJobs(urls.map { BatchJob(url: $0) })
    }

    func addBatchJobs(_ jobs: [BatchJob], showsActivity: Bool = true) {
        guard features.isEnabled(.batch) else {
            phase = .failed(message: FailureText.message(for: ParolaError.featureDisabled(.batch)))
            return
        }
        guard !jobs.isEmpty else { return }
        if batchIsRunning {
            batchJobs.append(contentsOf: jobs)
            if showsActivity { showBatchActivity() }
        } else if batchJobs.isEmpty {
            startBatch(jobs: jobs, showsActivity: showsActivity)
        } else if takeIsRunning || transcribeTaskRunning {
            deferredArrivals.append(contentsOf: jobs.map(\.url))
            if takeIsRunning { noteRunWaitsForTake() }
        } else {
            batchJobs.append(contentsOf: jobs)
            resumeBatch(pendingJobs: jobs)
            if showsActivity { showBatchActivity() }
        }
    }

    /// A run, a take, a batch in flight or the duplicate sheet: what the parked arrivals wait for.
    var foregroundIsHeld: Bool {
        linkArrivalsDeferred || recordingActive || duplicateImport != nil
    }

    /// The one place a drain is scheduled: on the next turn, if nothing holds the foreground by then, what waited goes.
    func foregroundLetGo() {
        guard arrivalDrain == nil else { return }
        arrivalDrain = Task { [weak self] in
            guard let self else { return }
            if !foregroundIsHeld { await dropParkedFilesThatAreGone() }
            arrivalDrain = nil
            guard !foregroundIsHeld else { return }
            drainDeferredArrivals()
            if let pausedAt = watchedLanePausedAt, foregroundClaims != pausedAt { resumeWatchedLane() }
            pumpWatchedLane()
        }
    }

    /// A file deleted while it waited, or a burn cancelled mid-write, leaves nothing to open. Off main and
    /// bounded: a stalled share keeps its files, and the run's own bounded read reports them.
    private func dropParkedFilesThatAreGone() async {
        let parked = deferredArrivals
        guard !parked.isEmpty else { return }
        let probe = parkedFileProbe
        let checked = await BoundedFileRead.run(deadline: fileReadDeadline) {
            Set(parked.filter(probe))
        }
        guard case .done(let present) = checked else { return }
        let gone = Set(parked).subtracting(present)
        deferredArrivals.removeAll { gone.contains($0) }
    }

    /// Waits for a scheduled drain, and for any drain it scheduled in turn.
    func awaitArrivalDrain() async {
        while let drain = arrivalDrain {
            await drain.value
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
                importBatchFiles(audioURLs, showsActivity: false)
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

    /// Rebuilds a queue that a quit interrupted: jobs come back pending under Activity and wait for Resume.
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
    }

    var canResumeBatch: Bool {
        batchTask == nil && !batchIsRunning && !batchBuckets.rows(.pending).isEmpty
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
            resumeWaitingBatchJobs()
        case .pending, .done, .failed, .cancelled:
            batchJobs.remove(at: idx)
            if selectedBatchJobID == id { selectedBatchJobID = batchJobs.first?.id }
        }
    }

    func presentBatchOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Select audio or video files to transcribe.")
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

    /// Marks the job's row; its transcript opens only through `openBatchJobTranscript`, where the user sees it.
    func selectBatchJob(_ id: BatchJob.ID) {
        selectedBatchJobID = id
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
        batchSidecars = [:]
        selectedBatchJobID = nil
        batchDuplicatesSkipped = 0
    }

    func cancelAllInFlightBatchJobs() {
        batchRunCancelled = true
        cancelAndTrack(&batchTask)
        stopBatchRun()
        var jobs = batchJobs
        for idx in jobs.indices where jobs[idx].status == .pending || jobs[idx].status == .transcribing {
            jobs[idx].status = .cancelled
        }
        batchJobs = jobs
    }

    func retryBatchJob(_ id: BatchJob.ID) {
        retryBatchJobs([id])
    }

    /// One run for all of them: a run per job would cancel the one before it.
    func retryBatchJobs(_ ids: Set<BatchJob.ID>) {
        var retried: [BatchJob] = []
        var jobs = batchJobs
        for idx in jobs.indices where ids.contains(jobs[idx].id) {
            jobs[idx].status = .pending
            jobs[idx].error = nil
            jobs[idx].transcript = nil
            jobs[idx].entryID = nil
            jobs[idx].segmentCount = nil
            // The file may have changed since it was hashed; the add takes its own digest.
            jobs[idx].sourceDigest = nil
            batchProgress.reset(jobs[idx].id)
            retried.append(jobs[idx])
        }
        batchJobs = jobs
        // Don't tear down a live batch to retry — runBatchTask cancels the running queue and
        // strands the in-flight job. Reset to .pending; the running batch's .finished resume picks them up.
        if !batchIsRunning, !retried.isEmpty {
            runBatchTask(jobs: retried)
        }
    }

    /// Return or a double-click: one finished job opens; the failed and cancelled ones run again.
    func openOrRetryBatchJobs(_ ids: Set<BatchJob.ID>) {
        let jobs = batchJobs.filter { ids.contains($0.id) }
        if jobs.count == 1, let job = jobs.first, job.status == .done {
            openBatchJobTranscript(job.id)
            return
        }
        retryBatchJobs(Set(jobs.filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)))
    }

    /// The running job goes last: cancelling it starts the jobs still waiting, and the ones going too must be gone by then.
    func deleteBatchJobs(_ ids: Set<BatchJob.ID>) {
        let jobs = batchJobs.filter { ids.contains($0.id) }
        for job in jobs where job.status != .transcribing { cancelBatchJob(job.id) }
        for job in jobs where job.status == .transcribing { cancelBatchJob(job.id) }
    }

    func clearFinishedBatchJobs() {
        batchJobs.removeAll { $0.status == .done || $0.status == .cancelled || $0.status == .failed }
        if let selected = selectedBatchJobID, !batchJobs.contains(where: { $0.id == selected }) {
            selectedBatchJobID = batchJobs.first?.id
        }
    }

    /// Shows a finished job on the transcript route: its entry, or its own copy while the add is in flight; returns the entry's load.
    @discardableResult
    func openBatchJobTranscript(_ id: BatchJob.ID) -> Task<Transcript, any Error>? {
        guard let job = batchJobs.first(where: { $0.id == id }) else { return nil }
        if let entryID = job.entryID {
            selectedBatchJobID = id
            return loadEntry(entryID)
        }
        if let t = job.transcript {
            selectedBatchJobID = id
            leaveFailedPhase()
            showUnsavedBatchJobReplacingSelection(job, t)
            phase = .ready
            route = .transcript
        }
        return nil
    }

    func reorderPendingBatchJobs(from source: IndexSet, to destination: Int) {
        let pendingIndices = batchJobs.indices.filter { batchJobs[$0].status == .pending }
        guard !pendingIndices.isEmpty else { return }
        var pending = pendingIndices.map { batchJobs[$0] }
        pending.move(fromOffsets: source, toOffset: destination)
        var jobs = batchJobs
        for (pendingPosition, originalIndex) in pendingIndices.enumerated() {
            jobs[originalIndex] = pending[pendingPosition]
        }
        batchJobs = jobs
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
