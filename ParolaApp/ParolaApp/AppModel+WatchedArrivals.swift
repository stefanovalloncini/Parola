import Foundation
import ParolaCore

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

    /// A file is only gone when the folder it came from is there without it.
    static func reach(_ file: URL, in folder: URL) -> Reach {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return .unreachable }
        return manager.fileExists(atPath: file.path) ? .present : .gone
    }
}

/// What the toast says about the last watched-folder file that ran out of sight.
struct ArrivalNotice: Equatable, Identifiable {
    enum State: Equatable {
        case saved(LibraryEntry.ID)
        case failed(String)
    }

    let id = UUID()
    let name: String
    let state: State

    init(landed entry: LibraryEntry) {
        name = LibraryEntryDisplay.title(for: entry)
        state = .saved(entry.id)
    }

    init(failed url: URL, reason: String) {
        name = url.deletingPathExtension().lastPathComponent
        state = .failed(reason)
    }
}

extension AppModel {

    /// Saved to the line before anything reads the file, so a quit during the duplicate check loses nothing.
    func handleWatchedArrival(_ url: URL) {
        let folder = watchedFoldersIfWatching?.folder(containing: url)
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

    /// Starts the next watched file when the foreground is free: in the window when Parola is idle, out of sight otherwise.
    func pumpWatchedLane() {
        guard watchedLaneTask == nil, visibleArrivalID == nil, !foregroundIsHeld,
              let next = nextWatchedArrival else { return }
        let deadline = fileReadDeadline
        let skipsDuplicates = duplicateImportPolicy.batchSkipsDuplicates
        let folderIsUnavailable = next.folderID.map { watchedFoldersIfWatching?.isUnavailable($0) ?? false } ?? false
        let probe = watchedFileReach
        // Off main and bounded: a watched folder can sit on a server that takes its time to answer, or never does.
        watchedLaneTask = Task { [weak self, library] in
            var reach = WatchedArrival.Reach.unreachable
            if !folderIsUnavailable,
               case .done(let found) = await BoundedFileRead.run(deadline: deadline, { probe(next.url, next.folderURL) }) {
                reach = found
            }
            // Nobody opened this file, so a copy the library holds follows the batch rule: skipped and counted, never a sheet.
            var lookup: DuplicateNotice.Lookup?
            if reach == .present, next.sourceDigest == nil, skipsDuplicates {
                lookup = await DuplicateNotice.lookup(for: next.url, in: library, deadline: deadline)
            }
            guard let self, !Task.isCancelled else { return }
            watchedLaneTask = nil
            switch reach {
            case .present:
                break
            case .unreachable:
                ParolaLog.info(.library, "a watched-folder file waits for its folder to come back")
                unreachableArrivalIDs.insert(next.id)
                pumpWatchedLane()
                return
            case .gone:
                ParolaLog.info(.library, "a watched-folder file was gone by its turn")
                watchedArrivals.removeAll { $0.id == next.id }
                pumpWatchedLane()
                return
            }
            if lookup?.entry != nil {
                batchDuplicatesSkipped += 1
                ParolaLog.info(.library, "skipped a watched-folder file the library already holds")
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
        if !next.inBackground, arrivalMayTakeWindow {
            beginFileTranscription(
                fileURL: next.url, translateOverride: nil, sourceDigest: next.sourceDigest, arrival: next
            )
            visibleArrivalID = next.id
        } else {
            runArrivalInBackground(next)
        }
    }

    /// The first file in the line that still has to run and whose folder answered.
    var nextWatchedArrival: WatchedArrival? {
        watchedArrivals.first { !$0.isLanding && !unreachableArrivalIDs.contains($0.id) }
    }

    /// A folder is back: the files that waited on it try again, in their places.
    func retryUnreachableArrivals() {
        guard !unreachableArrivalIDs.isEmpty else { return }
        unreachableArrivalIDs = []
        pumpWatchedLane()
    }

    /// Nothing open, playing or asking: an arrival may run where the user can see it, as a file they opened would.
    var arrivalMayTakeWindow: Bool {
        guard route == .transcript, batchIsEmpty, !isBrowsingLibrary, transcript == nil, !isPlaying,
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
        watchedLaneTask = Task { [weak self, session] in
            do {
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

    /// The foreground needs the session: the file out of sight stops and waits at the head of the line.
    func preemptWatchedLane() {
        guard let task = watchedLaneTask else { return }
        task.cancel()
        watchedLaneTask = nil
        backgroundArrivalID = nil
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
    func visibleArrivalLanded(_ arrival: WatchedArrival, saving: Task<LibraryEntry, any Error>) {
        guard visibleArrivalID == arrival.id else { return }
        visibleArrivalID = nil
        holdUntilSaved(arrival, saving, ringsWhenDry: false)
    }

    private func landBackgroundArrival(_ arrival: WatchedArrival, _ transcript: Transcript) {
        watchedLaneTask = nil
        backgroundArrivalID = nil
        let saving = land(RunLanding(
            kind: .backgroundArrival, transcript: transcript, audioSource: arrival.url,
            sourceDigest: arrival.sourceDigest
        ))
        holdUntilSaved(arrival, saving, ringsWhenDry: true)
        pumpWatchedLane()
    }

    /// The file stays in the line until its entry is saved: a quit during the copy runs it again, a failed save hands it back.
    private func holdUntilSaved(_ arrival: WatchedArrival, _ saving: Task<LibraryEntry, any Error>, ringsWhenDry: Bool) {
        guard let index = watchedArrivals.firstIndex(where: { $0.id == arrival.id }) else { return }
        watchedArrivals[index].isLanding = true
        Task { [weak self] in
            do {
                _ = try await saving.value
                guard let self else { return }
                watchedArrivals.removeAll { $0.id == arrival.id }
                if ringsWhenDry, watchedArrivals.isEmpty { playCompletionSound() }
            } catch {
                self?.failArrival(arrival, error: error)
            }
        }
    }

    /// A file that couldn't be transcribed leaves the line and a change brings it back; the error pane or the toast says why.
    func failArrival(_ arrival: WatchedArrival, error: any Error) {
        if backgroundArrivalID == arrival.id {
            watchedLaneTask = nil
            backgroundArrivalID = nil
            arrivalNotice = ArrivalNotice(failed: arrival.url, reason: Self.transcriptionFailureMessage(for: error))
        }
        if visibleArrivalID == arrival.id { visibleArrivalID = nil }
        watchedArrivals.removeAll { $0.id == arrival.id }
        if let offerWatchedFileAgain {
            offerWatchedFileAgain(arrival.url)
        } else if activeSideEffects.contains(.watchedFolders) {
            watchedFolders.offerAgainOnChange(arrival.url)
        }
        pumpWatchedLane()
    }

    /// Cancel gives the window back: the files still waiting finish out of sight instead of taking it again.
    func sendWaitingArrivalsOutOfSight() {
        var waiting = watchedArrivals
        for index in waiting.indices { waiting[index].inBackground = true }
        watchedArrivals = waiting
    }

    // MARK: - Across a quit

    var watchedArrivalsFileURL: URL {
        library.libraryURL.appendingPathComponent("watched-arrivals.json")
    }

    func saveWatchedArrivals() {
        let url = watchedArrivalsFileURL
        do {
            if watchedArrivals.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try JSONEncoder().encode(watchedArrivals).write(to: url, options: .atomic)
            }
        } catch {
            ParolaLog.error(.library, "watched-folder queue could not be saved", [.error: .error(error)])
        }
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
}
