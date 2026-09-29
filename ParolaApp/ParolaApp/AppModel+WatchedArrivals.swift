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

    /// Nobody opened this file, so a copy the library holds follows the batch rule whether Parola is idle
    /// or busy: skipped and counted with the batch's duplicates, never a sheet or a jump to the stored entry.
    func handleWatchedArrival(_ url: URL) {
        let previous = watchedImportTask
        let deadline = fileReadDeadline
        let skipsDuplicates = duplicateImportPolicy.batchSkipsDuplicates
        watchedImportTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var lookup: DuplicateNotice.Lookup?
            if skipsDuplicates {
                lookup = await DuplicateNotice.lookup(for: url, in: self.library, deadline: deadline)
            }
            if lookup?.entry != nil {
                guard !Task.isCancelled else { return }
                self.batchDuplicatesSkipped += 1
                ParolaLog.info(.library, "skipped a watched-folder file the library already holds")
                return
            }
            guard !Task.isCancelled else { return }
            self.enqueueWatchedArrival(WatchedArrival(url: url, sourceDigest: lookup?.digest))
        }
    }

    /// Waits for the duplicate check a watched arrival goes through before it joins the lane.
    func awaitWatchedImport() async {
        while let task = watchedImportTask {
            await task.value
            if watchedImportTask == task { watchedImportTask = nil }
        }
    }

    /// A file offered again before its turn keeps its place in the line.
    func enqueueWatchedArrival(_ arrival: WatchedArrival) {
        if let index = watchedArrivals.firstIndex(where: { $0.url == arrival.url }),
           watchedArrivals[index].id != backgroundArrivalID, watchedArrivals[index].id != visibleArrivalID {
            watchedArrivals[index].sourceDigest = arrival.sourceDigest
        } else {
            watchedArrivals.append(arrival)
        }
        pumpWatchedLane()
    }

    /// Starts the next watched file when the foreground is free: in the window when Parola is idle, out of sight otherwise.
    func pumpWatchedLane() {
        guard watchedLaneTask == nil, visibleArrivalID == nil, !foregroundIsHeld,
              let next = watchedArrivals.first else { return }
        // Off main: a watched folder can sit on a server that takes its time to answer.
        watchedLaneTask = Task { [weak self] in
            let present = (try? await AppModel.offMainIO(qos: .utility) {
                FileManager.default.fileExists(atPath: next.url.path)
            }) ?? false
            guard let self, !Task.isCancelled else { return }
            watchedLaneTask = nil
            guard present else {
                ParolaLog.info(.library, "a watched-folder file was gone by its turn")
                watchedArrivals.removeAll { $0.id == next.id }
                pumpWatchedLane()
                return
            }
            startArrival(next)
        }
    }

    private func startArrival(_ vetted: WatchedArrival) {
        guard visibleArrivalID == nil, !foregroundIsHeld else { return }
        guard let next = watchedArrivals.first, next.id == vetted.id else {
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

    /// The run in the window reached its landing.
    func visibleArrivalLanded(_ arrival: WatchedArrival) {
        if visibleArrivalID == arrival.id { visibleArrivalID = nil }
        watchedArrivals.removeAll { $0.id == arrival.id }
    }

    private func landBackgroundArrival(_ arrival: WatchedArrival, _ transcript: Transcript) {
        watchedLaneTask = nil
        backgroundArrivalID = nil
        watchedArrivals.removeAll { $0.id == arrival.id }
        land(RunLanding(
            kind: .backgroundArrival, transcript: transcript, audioSource: arrival.url,
            sourceDigest: arrival.sourceDigest
        ))
        if watchedArrivals.isEmpty { playCompletionSound() }
        pumpWatchedLane()
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
