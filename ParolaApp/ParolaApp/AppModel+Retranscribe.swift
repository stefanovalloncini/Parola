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
        cancelLinkFetch()
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
        var landing: Task<LibraryEntry, any Error>?
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
            var processed = await postProcessDetached(result)
            // The engine stamps the bundle file it read; a link's entry keeps pointing at its page.
            if let page = loaded.document.transcript.sourceURL, !page.isFileURL { processed.sourceURL = page }
            // Post-processing is a suspension a cancel can land in, and past this line the old
            // transcript is gone: check rather than overwrite a take the user stopped.
            try Task.checkCancellation()
            landing = land(.rerun(of: entryID, transcript: processed, clearingNotes: loaded.entry.segmentNotes))
        } catch {
            // applyTranscriptionError parks a cancelled run at .idle and a failed one at .failed;
            // either way the phase stops reading "transcribing" once this task has let go.
            if fileRunGeneration == runToken { applyTranscriptionError(error) }
        }
        if let landing {
            let saved = (try? await landing.value) != nil
            // A save that failed leaves nothing else to move the phase off the run.
            if fileRunGeneration == runToken { phase = saved ? .ready : .idle }
        }
        retranscribeRequest = nil
        guard fileRunGeneration == runToken else { return }
        filePartialText = ""
        fileTranscribeFraction = nil
        fileTranscribeStage = nil
        fileTranscribeTask = nil
        retireFileRun(runToken)
    }
}
