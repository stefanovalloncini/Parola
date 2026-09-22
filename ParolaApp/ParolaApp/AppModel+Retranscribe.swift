import Foundation
import ParolaCore

/// The re-run in flight: which entry, and the model and language the engine was handed.
struct RetranscribeRequest: Equatable, Sendable {
    let entryID: LibraryEntry.ID
    let modelName: String
    /// nil is Auto, the same thing it means in the language picker.
    let language: String?
}

extension AppModel {

    /// Imported subtitles and fetched captions carry no audio, so there is nothing to run again.
    var canRetranscribeSelectedEntry: Bool {
        guard let id = selectedEntryID, let entry = libraryEntry(id: id) else { return false }
        return entry.manifest.audioFilename != nil
    }

    /// Why the inspector's two menus are shut, or nil when they are open for business.
    var retranscribeUnavailableReason: String? {
        guard selectedEntryID != nil, !canRetranscribeSelectedEntry else { return nil }
        return String(localized: "This transcript came in without its audio, so there is nothing to transcribe again.")
    }

    /// Runs the loaded entry's own audio again and replaces what the entry holds; the one entry point.
    func retranscribeCurrentEntry(model modelName: String, language: String?) {
        guard let entryID = selectedEntryID, canRetranscribeSelectedEntry, retranscribeRequest == nil else { return }
        // Always transcribe: translating to English would ignore the language the menu just picked.
        let options = makeOptions(task: .transcribe, model: modelName, language: language)
        retranscribeRequest = RetranscribeRequest(
            entryID: entryID, modelName: modelName, language: options.language
        )
        let runToken = nextFileRunToken()
        cancelAndTrack(&fileTranscribeTask)
        fileTranscribeTask = Task { [weak self] in
            await self?.runRetranscription(
                entryID: entryID, modelName: modelName, options: options, runToken: runToken
            )
        }
    }

    private func runRetranscription(
        entryID: LibraryEntry.ID,
        modelName: String,
        options: TranscriptionOptions,
        runToken: Int
    ) async {
        do {
            let loaded = try await library.load(entryID)
            guard let audioURL = loaded.document.audioURL else {
                throw ParolaError.ioError(String(localized: "This transcript came in without its audio."))
            }
            filePartialText = ""
            fileTranscribeFraction = nil
            fileTranscribeStage = nil
            phase = ModelStore.shared.isInstalled(modelName)
                ? .loadingModel(name: modelName)
                : .downloadingModel(name: modelName, progress: 0)
            let result = try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: options,
                downloadProgress: makeDownloadProgressHandler(for: modelName),
                partialHandler: makeFilePartialHandler(runToken: runToken),
                progressHandler: makeFileProgressHandler(runToken: runToken),
                stageHandler: makeFileStageHandler(fileURL: audioURL, runToken: runToken)
            )
            try Task.checkCancellation()
            let processed = await postProcessDetached(result)
            // Post-processing is another suspension a cancel can land in, and past this line the
            // old transcript is gone: re-check rather than overwrite a take the user stopped.
            try Task.checkCancellation()
            await replaceEntry(entryID, with: processed, clearingNotes: loaded.entry.segmentNotes)
        } catch {
            // applyTranscriptionError parks a cancelled run at .idle and a failed one at .failed;
            // either way the phase stops reading "transcribing" once this task has let go.
            if fileRunGeneration == runToken { applyTranscriptionError(error) }
        }
        retranscribeRequest = nil
        guard fileRunGeneration == runToken else { return }
        filePartialText = ""
        fileTranscribeFraction = nil
        fileTranscribeStage = nil
        fileTranscribeTask = nil
    }

    /// Favorites, notes, the speaker map and the card metadata all name segments and labels this run replaced.
    private func replaceEntry(
        _ entryID: LibraryEntry.ID,
        with transcript: Transcript,
        clearingNotes notes: [String: String]
    ) async {
        guard !Task.isCancelled else { return }
        do {
            try await library.updateTranscript(transcript, for: entryID)
            try await library.setTranscriptionDetails(
                modelName: transcript.modelName, language: transcript.language, for: entryID
            )
            try await library.setFavoriteSegments([], for: entryID)
            for segmentID in notes.keys.compactMap(Int.init) {
                try await library.setSegmentNote(nil, segmentID: segmentID, for: entryID)
            }
            try await library.mutateSpeakerAssignments(for: entryID) { $0 = [:] }
            try await library.setCardMetadata(aiTitle: nil, shortSummary: nil, for: entryID)
        } catch {
            ParolaLog.error(.library, "re-transcription could not be saved", [.error: .error(error)])
            nonFatalWarning = String(
                localized: "The transcript ran again, but Parola couldn't save the result. \(error.localizedDescription)"
            )
            // The task is already letting go, so nothing else will move the phase off the run.
            phase = .idle
            return
        }
        refreshLibrary()
        if selectedEntryID == entryID {
            installStoredTranscript(transcript)
            adoptLoadedMediaDuration()
        }
        phase = .ready
        playCompletionSound()
        // The card-metadata hook lives in persistToLibrary, which a re-run never passes through.
        _ = await AsyncTimeout.run(.seconds(30)) { [weak self] in
            await self?.generateCardMetadata(for: entryID, transcript: transcript)
        }
    }
}
