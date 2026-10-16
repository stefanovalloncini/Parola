import AppKit
import Foundation
import os
import ParolaCore

/// The queue's file on disk: the latest snapshot is encoded and written on a utility queue a moment after the last change.
final class WatchedArrivalsFile: Sendable {
    private struct Pending {
        var latest: [WatchedArrival]?
        var scheduled = false
    }

    private let url: URL
    private let delay: DispatchTimeInterval
    private let queue = DispatchQueue(label: "app.parola.watched-arrivals", qos: .utility)
    private let pending = OSAllocatedUnfairLock(initialState: Pending())

    init(url: URL, delay: DispatchTimeInterval = .milliseconds(250)) {
        self.url = url
        self.delay = delay
    }

    /// An urgent save skips the wait but stays on the same queue, so it still lands after every write before it.
    func save(_ arrivals: [WatchedArrival], urgent: Bool = false) {
        let arm = pending.withLock { state in
            state.latest = arrivals
            guard urgent || !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard arm else { return }
        if urgent {
            queue.async { self.writePending() }
        } else {
            queue.asyncAfter(deadline: .now() + delay) { self.writePending() }
        }
    }

    func flush() {
        queue.sync { writePending() }
    }

    private func writePending() {
        let arrivals = pending.withLock { state in
            state.scheduled = false
            defer { state.latest = nil }
            return state.latest
        }
        guard let arrivals else { return }
        do {
            if arrivals.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try JSONEncoder().encode(arrivals).write(to: url, options: .atomic)
            }
        } catch {
            ParolaLog.error(.library, "watched-folder queue could not be saved", [.error: .error(error)])
        }
    }
}

/// A watched-folder file waiting its turn in the lane.
struct WatchedArrival: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let url: URL
    /// The digest the duplicate check took, for the library add to reuse.
    var sourceDigest: String?
    /// Set once the window let the run go: the file finishes out of sight.
    var inBackground = false
    /// Transcribed and on its way into the library; it leaves the line once the entry is saved.
    var isLanding = false
    /// Parola quit while its entry was being saved, so the library may already hold it.
    var landingInterrupted = false
    /// The watched folder it came from; nil when that isn't known, and the file's own folder stands in.
    var folderID: UUID?
    var folderPath: String?

    var folderURL: URL {
        folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? url.deletingLastPathComponent()
    }

    enum Reach: Sendable {
        case present
        case gone
        /// The folder itself is missing: an unmounted volume or a share that hasn't come back yet.
        case unreachable
    }

    /// What the pre-run check makes of a probe: nil when it didn't answer in time.
    static func verdict(probed: Reach?, folderIsUnavailable: Bool, folderVouches: Bool) -> Reach {
        guard !folderIsUnavailable, let probed else { return .unreachable }
        // An empty mount point looks like a folder that lost the file until the watch says it is the folder.
        return probed == .gone && !folderVouches ? .unreachable : probed
    }

    /// A file is only gone when the folder it came from is there without it.
    static func reach(_ file: URL, in folder: URL) -> Reach {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return .unreachable }
        return manager.fileExists(atPath: file.path) ? .present : .gone
    }
}

/// A watched file's finished run whose save failed; `install` is set when the window still shows it unsaved.
struct UnsavedLanding {
    let landing: RunLanding
    let install: Int?
}

/// What the toast says about a watched-folder file out of sight: running, landed or failed; or about a take saved out of sight.
struct ArrivalNotice: Equatable, Identifiable {
    enum State: Equatable {
        case running
        case saved(LibraryEntry.ID)
        case failed(String)
        /// The failure wasn't the file's: the lane stops with it still waiting, and Retry starts it again.
        case paused(String)
        /// Transcribed but not saved: the lane stops with it waiting, like `paused`.
        case unsaved(String)
        /// Waiting in Batch for the user to start it; the count is the files this one toast stands for.
        case queued(Int)
        /// Transcribed and exported by its folder's options, with no library entry to open; the first file written.
        case exported(URL?)
    }

    enum Origin: Equatable {
        case watchedFolder
        /// A take that finished while another page showed.
        case take
        /// A file or link the user opened, finished after they moved on to something else.
        case run

        init(_ landing: RunLanding.Kind) {
            switch landing {
            case .backgroundTake: self = .take
            case .backgroundRun: self = .run
            default: self = .watchedFolder
            }
        }
    }

    let id = UUID()
    let name: String
    let state: State
    var origin: Origin = .watchedFolder
    /// The page a saved entry went to; nil for a file that never became one.
    var category: EntryCategory?
    /// A failed watched file, and the folder it came from, for Retry and Reveal.
    var file: URL?
    var folderID: UUID?
    var folderPath: String?

    var reason: String? {
        switch state {
        case .failed(let reason), .paused(let reason), .unsaved(let reason): reason
        case .running, .saved, .queued, .exported: nil
        }
    }

    /// Only a landing goes after a few seconds: a running file, a stopped lane and a failure stay until something changes.
    var dismissesItself: Bool {
        switch state {
        case .saved, .queued, .exported: true
        case .running, .paused, .unsaved, .failed: false
        }
    }

    init(landed entry: LibraryEntry, origin: Origin = .watchedFolder) {
        name = LibraryEntryDisplay.title(for: entry)
        state = .saved(entry.id)
        self.origin = origin
        category = entry.category
    }

    /// A take or a run says it as the saved take's toast does; a watched file also says where it came from.
    static func savedTitle(name: String, origin: Origin, category: EntryCategory, bundle: Bundle = .main) -> String {
        switch origin {
        case .take, .run: TakeSavedToast.message(title: name, category: category, bundle: bundle)
        case .watchedFolder: String(localized: "Transcribed \(name) from a watched folder", bundle: bundle)
        }
    }

    func savedTitle(bundle: Bundle = .main) -> String {
        Self.savedTitle(name: name, origin: origin, category: category ?? .transcription, bundle: bundle)
    }

    /// What the toast says, by where the file stands.
    func title(bundle: Bundle = .main) -> String {
        switch state {
        case .running: String(localized: "Transcribing \(name) from a watched folder", bundle: bundle)
        case .saved: savedTitle(bundle: bundle)
        case .failed, .paused: String(localized: "Couldn't transcribe \(name)", bundle: bundle)
        case .unsaved: String(localized: "Couldn't save \(name) to your library", bundle: bundle)
        case .queued(let count):
            count == 1
                ? String(localized: "Added \(name) to Batch", bundle: bundle)
                : String(localized: "Added \(count) files to Batch", bundle: bundle)
        case .exported: String(localized: "Transcribed \(name) and exported it", bundle: bundle)
        }
    }

    init(queued url: URL, count: Int = 1) {
        name = url.deletingPathExtension().lastPathComponent
        state = .queued(count)
    }

    init(exported url: URL, writing file: URL?) {
        name = url.deletingPathExtension().lastPathComponent
        state = .exported(file)
    }

    init(failed url: URL, reason: String, folderID: UUID? = nil, folderPath: String? = nil) {
        name = url.deletingPathExtension().lastPathComponent
        state = .failed(reason)
        file = url
        self.folderID = folderID
        self.folderPath = folderPath
    }

    init(paused url: URL, reason: String) {
        name = url.deletingPathExtension().lastPathComponent
        state = .paused(reason)
    }

    init(unsaved url: URL, reason: String) {
        name = url.deletingPathExtension().lastPathComponent
        state = .unsaved(reason)
    }

    init(running url: URL) {
        name = url.deletingPathExtension().lastPathComponent
        state = .running
    }
}

extension AppModel {

    /// Saved to the line before anything reads the file, so a quit during the duplicate check loses nothing.
    func handleWatchedArrival(_ url: URL) {
        let store = watchedFoldersIfWatching
        let folder = store?.folder(containing: url)
        if let store, let folder, !store.options(for: folder.id).autoTranscribes, holdWatchedFileInBatch(url) { return }
        enqueueWatchedArrival(WatchedArrival(url: url, folderID: folder?.id, folderPath: folder?.root.path))
    }

    /// A file offered again before its turn keeps its place in the line; one offered while it runs waits once behind it.
    func enqueueWatchedArrival(_ arrival: WatchedArrival) {
        let waiting = watchedArrivals.firstIndex {
            $0.url == arrival.url && !$0.isLanding && $0.id != backgroundArrivalID && $0.id != visibleArrivalID
        }
        if let index = waiting {
            watchedArrivals[index].sourceDigest = arrival.sourceDigest
        } else {
            watchedArrivals.append(arrival)
        }
        pumpWatchedLane()
    }

    func watchedOptions(for arrival: WatchedArrival) -> WatchedFolderOptions {
        guard let id = arrival.folderID, let store = watchedFoldersIfWatching else { return .default }
        var options = store.options(for: id)
        let known = Set(exportPresets.map(\.id))
        options.exportPresetIDs.removeAll { !known.contains($0) }
        if !features.isEnabled(.batch) { options.autoTranscribes = true }
        return options.normalized
    }

    /// A folder that doesn't transcribe by itself hands its new files to Batch as pending jobs; false when Batch is off.
    private func holdWatchedFileInBatch(_ url: URL) -> Bool {
        guard features.isEnabled(.batch) else { return false }
        if batchJobs.contains(where: { $0.url == url && $0.status == .pending }) { return true }
        let job = BatchJob(url: url)
        heldBatchJobIDs.insert(job.id)
        batchJobs.append(job)
        if selectedBatchJobID == nil { selectedBatchJobID = job.id }
        switch arrivalNotice?.state {
        case nil, .saved, .exported:
            arrivalNotice = ArrivalNotice(queued: url)
        case .queued(let earlier):
            arrivalNotice = ArrivalNotice(queued: url, count: earlier + 1)
        case .running, .failed, .paused, .unsaved:
            break
        }
        return true
    }

    func openBatchFromNotice() {
        arrivalNotice = nil
        openQueue()
    }

    /// Starts the next watched file when the foreground is free: in the window when Parola is idle, out of sight otherwise.
    func pumpWatchedLane() {
        guard watchedLaneTask == nil, visibleArrivalID == nil, watchedLanePausedAt == nil, !foregroundIsHeld,
              let next = nextWatchedArrival else { return }
        let deadline = fileReadDeadline
        let checksLibrary = (duplicateImportPolicy.batchSkipsDuplicates || next.landingInterrupted)
            && watchedOptions(for: next).keepsTranscriptInLibrary
        let folderIsUnavailable = next.folderID.map { watchedFoldersIfWatching?.isUnavailable($0) ?? false } ?? false
        let folderVouches = watchedFolderVouches(for: next)
        let returnsAtCheck = watchedFolderReturns
        let probe = watchedFileReach
        // Off main and bounded: a watched folder can sit on a server that takes its time to answer, or never does.
        watchedLaneTask = Task { [weak self, library] in
            var probed: WatchedArrival.Reach?
            if !folderIsUnavailable,
               case .done(let found) = await BoundedFileRead.run(deadline: deadline, { probe(next.url, next.folderURL) }) {
                probed = found
            }
            let reach = WatchedArrival.verdict(
                probed: probed, folderIsUnavailable: folderIsUnavailable, folderVouches: folderVouches
            )
            // Nobody opened this file, so a copy the library holds follows the batch rule: skipped and counted, never a sheet.
            var lookup: DuplicateNotice.Lookup?
            if reach == .present, next.sourceDigest == nil, checksLibrary {
                lookup = await DuplicateNotice.lookup(for: next.url, in: library, deadline: deadline)
            }
            guard let self, !Task.isCancelled else { return }
            watchedLaneTask = nil
            switch reach {
            case .present:
                break
            case .unreachable:
                // A folder that came back while this check ran would never be retried for it.
                if watchedFolderReturns == returnsAtCheck {
                    ParolaLog.info(.library, "a watched-folder file waits for its folder to come back")
                    unreachableArrivalIDs.insert(next.id)
                }
                pumpWatchedLane()
                return
            case .gone:
                ParolaLog.info(.library, "a watched-folder file was gone by its turn")
                watchedArrivals.removeAll { $0.id == next.id }
                pumpWatchedLane()
                return
            }
            if lookup?.entry != nil {
                // A save cut short by a quit that finished anyway is this file's own entry, not a duplicate to count.
                if !next.landingInterrupted {
                    batchDuplicatesSkipped += 1
                    ParolaLog.info(.library, "skipped a watched-folder file the library already holds")
                }
                watchedArrivals.removeAll { $0.id == next.id }
                pumpWatchedLane()
                return
            }
            if let digest = lookup?.digest, let index = watchedArrivals.firstIndex(where: { $0.id == next.id }) {
                watchedArrivals[index].sourceDigest = digest
            }
            startArrival(next)
        }
    }

    private func startArrival(_ vetted: WatchedArrival) {
        guard visibleArrivalID == nil, !foregroundIsHeld else { return }
        guard let next = nextWatchedArrival, next.id == vetted.id else {
            pumpWatchedLane()
            return
        }
        if let unsaved = unsavedLandings.removeValue(forKey: next.id) {
            saveAgain(next, unsaved)
            return
        }
        if !next.inBackground, arrivalMayTakeWindow, watchedOptions(for: next).keepsTranscriptInLibrary {
            beginFileTranscription(
                fileURL: next.url, translateOverride: nil, sourceDigest: next.sourceDigest, arrival: next
            )
            visibleArrivalID = next.id
        } else {
            runArrivalInBackground(next)
        }
    }

    /// The first file in the line that still has to run, whose folder answered, and that isn't being saved already.
    var nextWatchedArrival: WatchedArrival? {
        let saving = Set(watchedArrivals.filter(\.isLanding).map(\.url))
        return watchedArrivals.first {
            !$0.isLanding && !saving.contains($0.url) && !unreachableArrivalIDs.contains($0.id)
        }
    }

    /// Whether a missing file is really gone: its folder is watched and answering, or there is no watch to wait for.
    func watchedFolderVouches(for arrival: WatchedArrival) -> Bool {
        guard let id = arrival.folderID, let store = watchedFoldersIfWatching,
              store.folders.contains(where: { $0.id == id }) else { return true }
        return store.watcher(for: id) != nil && !store.isUnavailable(id)
    }

    /// A folder is back: the files that waited on it try again, in their places.
    func retryUnreachableArrivals() {
        watchedFolderReturns &+= 1
        guard !unreachableArrivalIDs.isEmpty else { return }
        unreachableArrivalIDs = []
        pumpWatchedLane()
    }

    /// The whole library with nothing open, playing, recording or asking: an arrival may run where the user can see it, as a file they opened would.
    var arrivalMayTakeWindow: Bool {
        guard route == .transcript, isBrowsingWholeLibrary, transcript == nil, !isPlaying, !takeIsRunning,
              entryWindows.openIDs.isEmpty, !introduction.isPresented, !sheetIsUp else { return false }
        switch phase {
        case .idle, .ready: return true
        default: return false
        }
    }

    var sheetIsUp: Bool {
        youtubeSheetOpen || duplicateImport != nil || promptOutput != nil || showingSpeakersSheet
            || editingSegmentNote != nil || showingPeopleSheet || exportSheetOpen || burnSheetOpen
            || meetingDetectedApp != nil || pendingRecovery != nil || pendingLargeDrop != nil
    }

    /// True once every watched file has landed or failed and nothing of the lane is running.
    var watchedLaneIsIdle: Bool {
        watchedArrivals.isEmpty && watchedLaneTask == nil && visibleArrivalID == nil
    }

    private func runArrivalInBackground(_ arrival: WatchedArrival) {
        let options = currentOptions
        backgroundArrivalID = arrival.id
        runningArrivalNotice = ArrivalNotice(running: arrival.url)
        watchedLaneTask = Task { [weak self, session] in
            do {
                self?.modelResidency.sessionRunBegan()
                defer { self?.modelResidency.sessionRunEnded() }
                let result = try await session.transcribe(source: FileAudioSource(url: arrival.url), options: options)
                try Task.checkCancellation()
                guard let self else { return }
                let processed = await postProcessDetached(result)
                try Task.checkCancellation()
                landBackgroundArrival(arrival, processed)
            } catch {
                // A run the foreground took the session from stays at the head of the line.
                guard let self, !Task.isCancelled else { return }
                failArrival(arrival, error: error)
            }
        }
    }

    /// A run, a batch or a take claimed the session: counted, so a paused lane knows a later let-go is news.
    func foregroundClaimedSession() {
        foregroundClaims &+= 1
        preemptWatchedLane()
    }

    /// The foreground needs the session: the file out of sight stops and waits at the head of the line.
    func preemptWatchedLane() {
        guard let task = watchedLaneTask else { return }
        task.cancel()
        watchedLaneTask = nil
        backgroundArrivalID = nil
        runningArrivalNotice = nil
    }

    /// Stop on the running strip: the file leaves the line, and only a change to it brings it back.
    func stopBackgroundArrival() {
        guard let id = backgroundArrivalID, let arrival = watchedArrivals.first(where: { $0.id == id }) else { return }
        preemptWatchedLane()
        watchedArrivals.removeAll { $0.id == id }
        handBack(arrival.url)
        pumpWatchedLane()
    }

    /// Cancel on a watched file in the window stops it the same way, without a word: the user asked for it.
    func cancelVisibleArrival() {
        guard let id = visibleArrivalID, let arrival = watchedArrivals.first(where: { $0.id == id }) else { return }
        visibleArrivalID = nil
        watchedArrivals.removeAll { $0.id == id }
        handBack(arrival.url)
    }

    /// Hides the running strip until the next file starts; the run goes on.
    func hideRunningArrival() {
        runningArrivalNotice = nil
    }

    /// The watcher offers a file it handed over again once it changes.
    private func handBack(_ url: URL) {
        if let offerWatchedFileAgain {
            offerWatchedFileAgain(url)
        } else if let store = watchedFoldersIfWatching {
            store.offerAgainOnChange(url)
        }
    }

    /// The run in the window was replaced or stopped before it landed: the file finishes out of sight.
    func visibleArrivalLostTheWindow() {
        guard let id = visibleArrivalID else { return }
        visibleArrivalID = nil
        if let index = watchedArrivals.firstIndex(where: { $0.id == id }) {
            watchedArrivals[index].inBackground = true
        }
    }

    /// The run in the window reached its landing. One the window already let go is the lane's to run.
    func visibleArrivalLanded(_ arrival: WatchedArrival, landing: RunLanding, saving: Task<LibraryEntry, any Error>) {
        guard visibleArrivalID == arrival.id else { return }
        visibleArrivalID = nil
        holdUntilSaved(arrival, landing, Task { _ = try await saving.value }, ringsWhenDry: false, install: derivedArtifactsGeneration)
    }

    /// The window's run of an arrival finished after the user moved on: it lands like one out of sight.
    func landVisibleArrivalOutOfSight(_ arrival: WatchedArrival, _ transcript: Transcript) {
        guard visibleArrivalID == arrival.id else { return }
        visibleArrivalID = nil
        let landing = RunLanding(
            kind: .backgroundArrival, transcript: transcript, audioSource: arrival.url,
            sourceDigest: arrival.sourceDigest, watchedOptions: watchedOptions(for: arrival)
        )
        holdUntilSaved(arrival, landing, landWatched(landing), ringsWhenDry: true)
    }

    private func landBackgroundArrival(_ arrival: WatchedArrival, _ transcript: Transcript) {
        watchedLaneTask = nil
        backgroundArrivalID = nil
        runningArrivalNotice = nil
        let landing = RunLanding(
            kind: .backgroundArrival, transcript: transcript, audioSource: arrival.url,
            sourceDigest: arrival.sourceDigest, watchedOptions: watchedOptions(for: arrival)
        )
        holdUntilSaved(arrival, landing, landWatched(landing), ringsWhenDry: true)
        pumpWatchedLane()
    }

    /// Retry after a failed save lands the transcript it kept. A pane still showing it unsaved becomes the entry,
    /// edits included; anything else lands out of sight.
    private func saveAgain(_ arrival: WatchedArrival, _ unsaved: UnsavedLanding) {
        var landing = unsaved.landing
        let options = landing.watchedOptions.flatMap { $0.keepsTranscriptInLibrary ? $0 : nil }
        var install: Int?
        if let shown = unsaved.install, shown == derivedArtifactsGeneration, selectedEntryID == nil, let transcript {
            landing = RunLanding(
                kind: .arrival, transcript: transcript, audioSource: landing.audioSource, sourceDigest: landing.sourceDigest
            )
            install = shown
        } else {
            landing = RunLanding(
                kind: .backgroundArrival, transcript: landing.transcript, audioSource: landing.audioSource,
                sourceDigest: landing.sourceDigest
            )
        }
        landing.watchedOptions = options
        holdUntilSaved(arrival, landing, landWatched(landing), ringsWhenDry: install == nil, install: install)
        pumpWatchedLane()
    }

    /// A folder that keeps nothing in the library exports the transcript instead, and saves it anyway when no export lands.
    private func landWatched(_ landing: RunLanding) -> Task<Void, any Error> {
        guard let options = landing.watchedOptions, !options.keepsTranscriptInLibrary else {
            let saving = land(landing)
            return Task { _ = try await saving.value }
        }
        return Task { [weak self] in try await self?.exportWithoutLibrary(landing, options) }
    }

    private func exportWithoutLibrary(_ landing: RunLanding, _ options: WatchedFolderOptions) async throws {
        let batch = await exportTranscript(
            landing.transcript, audioSource: landing.audioSource, source: landing.source, entry: nil,
            title: landing.title, folderOptions: options
        )?.value ?? ExportBatch()
        let own = batch.own
        let landed = batch.problem == nil && !own.isEmpty && own.allSatisfy { $0.written != nil }
        if landed, let url = landing.audioSource {
            arrivalNotice = ArrivalNotice(exported: url, writing: own.first?.written)
            return
        }
        if let problem = batch.problem {
            exportNotice = problem.notice
        } else if let error = own.lazy.compactMap(\.error).first {
            exportNotice = .autoExportFailed(error)
        }
        var kept = landing
        kept.watchedOptions = nil
        _ = try await land(kept).value
    }

    /// The file stays in the line until its entry is saved: a quit during the copy runs it again, a failed save hands it back.
    private func holdUntilSaved(
        _ arrival: WatchedArrival, _ landing: RunLanding, _ saving: Task<Void, any Error>,
        ringsWhenDry: Bool, install: Int? = nil
    ) {
        guard let index = watchedArrivals.firstIndex(where: { $0.id == arrival.id }) else { return }
        watchedArrivals[index].isLanding = true
        Task { [weak self] in
            do {
                _ = try await saving.value
                guard let self else { return }
                watchedArrivals.removeAll { $0.id == arrival.id }
                if ringsWhenDry { laneOwesRing = true }
                if laneOwesRing, watchedArrivals.isEmpty {
                    laneOwesRing = false
                    playCompletionSound()
                }
                pumpWatchedLane()
            } catch {
                guard let self else { return }
                // Nothing about the file stopped the save, so it waits in the line like a model failure would.
                unsavedLandings[arrival.id] = UnsavedLanding(landing: landing, install: install)
                pauseWatchedLane(at: arrival, error: error, unsaved: true)
            }
        }
    }

    /// A file that couldn't be transcribed leaves the line and a change brings it back; the error pane or the toast says why.
    func failArrival(_ arrival: WatchedArrival, error: any Error, announces: Bool = false) {
        if Self.stopsWatchedLane(error) {
            pauseWatchedLane(at: arrival, error: error, announces: announces)
            return
        }
        if Self.waitsForItsFolder(error) {
            waitForFolder(arrival)
            return
        }
        if backgroundArrivalID == arrival.id || announces {
            if backgroundArrivalID == arrival.id {
                watchedLaneTask = nil
                backgroundArrivalID = nil
                runningArrivalNotice = nil
            }
            arrivalNotice = ArrivalNotice(
                failed: arrival.url, reason: Self.transcriptionFailureMessage(for: error),
                folderID: arrival.folderID, folderPath: arrival.folderPath
            )
        }
        if visibleArrivalID == arrival.id { visibleArrivalID = nil }
        watchedArrivals.removeAll { $0.id == arrival.id }
        handBack(arrival.url)
        pumpWatchedLane()
    }

    /// A model, download or engine failure would fail every file in turn, so the line waits instead of emptying.
    nonisolated static func stopsWatchedLane(_ error: any Error) -> Bool {
        if offlineMessage(for: error) != nil { return true }
        switch error as? ParolaError {
        case .modelNotFound, .unknownModel, .policyRestricted, .featureDisabled, .modelDownloadFailed,
             .modelChecksumMismatch, .engineLoadFailed, .engineNotRegistered, .unsupportedForEngine, .invalidLanguage:
            return true
        default:
            return false
        }
    }

    /// A read that stalled or found no file is what the pre-run check calls an unreachable folder, and waits the same way.
    nonisolated static func waitsForItsFolder(_ error: any Error) -> Bool {
        switch error as? ParolaError {
        case .fileReadTimedOut, .fileMissing:
            return true
        default:
            return false
        }
    }

    private func waitForFolder(_ arrival: WatchedArrival) {
        if backgroundArrivalID == arrival.id {
            watchedLaneTask = nil
            backgroundArrivalID = nil
            runningArrivalNotice = nil
        }
        if visibleArrivalID == arrival.id { visibleArrivalID = nil }
        if let index = watchedArrivals.firstIndex(where: { $0.id == arrival.id }) {
            watchedArrivals[index].isLanding = false
        }
        ParolaLog.info(.library, "a watched-folder file couldn't be read and waits for its folder")
        unreachableArrivalIDs.insert(arrival.id)
        pumpWatchedLane()
    }

    /// The file keeps its place; the next foreground run that ends, a model install or Retry starts the lane again.
    private func pauseWatchedLane(
        at arrival: WatchedArrival, error: any Error, announces: Bool = false, unsaved: Bool = false
    ) {
        if backgroundArrivalID == arrival.id || announces {
            if backgroundArrivalID == arrival.id {
                watchedLaneTask = nil
                backgroundArrivalID = nil
                runningArrivalNotice = nil
            }
            arrivalNotice = ArrivalNotice(paused: arrival.url, reason: Self.transcriptionFailureMessage(for: error))
        }
        if unsaved {
            arrivalNotice = ArrivalNotice(unsaved: arrival.url, reason: FailureText.message(for: error))
        }
        if visibleArrivalID == arrival.id { visibleArrivalID = nil }
        if let index = watchedArrivals.firstIndex(where: { $0.id == arrival.id }) {
            watchedArrivals[index].isLanding = false
        }
        watchedLanePausedAt = foregroundClaims
        ParolaLog.notice(.library, "watched-folder files wait on a failure that isn't the file's", [.error: .error(error)])
    }

    func resumeWatchedLane() {
        watchedLanePausedAt = nil
        switch arrivalNotice?.state {
        case .paused, .unsaved: arrivalNotice = nil
        default: break
        }
        pumpWatchedLane()
    }

    /// Cancel gives the window back: the files still waiting finish out of sight instead of taking it.
    func sendWaitingArrivalsOutOfSight() {
        var waiting = watchedArrivals
        for index in waiting.indices { waiting[index].inBackground = true }
        watchedArrivals = waiting
    }

    // MARK: - Across a quit

    var watchedArrivalsFileURL: URL {
        library.libraryURL.appendingPathComponent("watched-arrivals.json")
    }

    func saveWatchedArrivals(urgent: Bool = false) {
        watchedArrivalsFile.save(watchedArrivals, urgent: urgent)
    }

    /// A new arrival or a landing that has begun must reach the disk at once: a crash after it would otherwise restore a line that forgets the file or runs a saved one twice.
    nonisolated static func needsPromptSave(from old: [WatchedArrival], to new: [WatchedArrival]) -> Bool {
        if new.count > old.count { return true }
        let wasLanding = Set(old.filter(\.isLanding).map(\.id))
        return new.contains { $0.isLanding && !wasLanding.contains($0.id) }
    }

    func flushWatchedArrivals() {
        watchedArrivalsFile.flush()
    }

    /// The files may have changed while Parola was closed, so each add takes its own digest.
    func restoreWatchedArrivals() {
        guard features.isEnabled(.watchedFolders), watchedArrivals.isEmpty,
              let data = try? Data(contentsOf: watchedArrivalsFileURL),
              let saved = try? JSONDecoder().decode([WatchedArrival].self, from: data),
              !saved.isEmpty else { return }
        watchedArrivals = saved.map { arrival in
            var restored = arrival
            restored.sourceDigest = nil
            restored.landingInterrupted = arrival.landingInterrupted || arrival.isLanding
            restored.isLanding = false
            return restored
        }
        Task { [weak self] in self?.pumpWatchedLane() }
    }

    func openArrivalNotice() {
        guard case .saved(let entryID) = arrivalNotice?.state else { return }
        arrivalNotice = nil
        loadEntry(entryID)
    }

    func dismissArrivalNotice() {
        arrivalNotice = nil
    }

    /// Retry on the toast: a stopped lane starts again; a file that failed goes back in the line.
    func retryArrivalNotice() {
        guard let notice = arrivalNotice else { return }
        switch notice.state {
        case .paused, .unsaved:
            resumeWatchedLane()
        case .failed:
            arrivalNotice = nil
            guard let file = notice.file else { return }
            enqueueWatchedArrival(WatchedArrival(url: file, folderID: notice.folderID, folderPath: notice.folderPath))
        case .running, .saved, .queued, .exported:
            break
        }
    }

    func revealExportedArrival() {
        guard case .exported(let file?)? = arrivalNotice?.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    enum ArrivalReveal: Equatable {
        case file(URL)
        case folder(URL)
        case gone
    }

    /// The failed file while it is there; once it moved, the folder it was in, or else its watched folder.
    nonisolated static func arrivalReveal(file: URL, folderPath: String?) -> ArrivalReveal {
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) { return .file(file) }
        var folders = [file.deletingLastPathComponent()]
        if let folderPath { folders.append(URL(fileURLWithPath: folderPath, isDirectory: true)) }
        for folder in folders {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue { return .folder(folder) }
        }
        return .gone
    }

    func revealFailedArrival() {
        guard let notice = arrivalNotice, case .failed = notice.state, let file = notice.file else { return }
        switch Self.arrivalReveal(file: file, folderPath: notice.folderPath) {
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .folder(let url):
            NSWorkspace.shared.open(url)
        case .gone:
            arrivalNotice = ArrivalNotice(
                failed: file, reason: String(localized: "The file was moved or deleted."),
                folderID: notice.folderID, folderPath: notice.folderPath
            )
        }
    }

    /// The toast's countdown; its view starts it only while its window is on screen.
    func dismissArrivalNotice(_ notice: ArrivalNotice, after delay: Duration) async {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, arrivalNotice == notice else { return }
        dismissArrivalNotice()
    }
}
