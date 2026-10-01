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

    /// A take saved as audio alone: no model has run on it, which isn't the same as finding no speech.
    var transcriptIsUntranscribed: Bool {
        guard let transcript else { return false }
        return transcript.modelName.isEmpty && transcript.segments.isEmpty
    }

    /// Transcribes the loaded entry's audio for the first time, with the selected model and language.
    func transcribeLoadedEntry() {
        retranscribeCurrentEntry(model: selectedModel, language: selectedLanguage)
    }

    /// Why the inspector's two menus are shut, or nil when they are open for business.
    var retranscribeUnavailableReason: String? {
        guard selectedEntryID != nil, !canRetranscribeSelectedEntry else { return nil }
        return String(localized: "This transcript came in without its audio, so there is nothing to transcribe again.")
    }

    /// Runs the loaded entry's own audio again and replaces what the entry holds; the one entry point. A take's Retry lands as the take would have.
    func retranscribeCurrentEntry(model modelName: String, language: String?, landingAs kind: RunLanding.Kind = .rerun) {
        guard let entryID = selectedEntryID, canRetranscribeSelectedEntry, retranscribeRequest == nil else { return }
        guard !takeIsRunning else {
            noteRunWaitsForTake()
            return
        }
        // Always transcribe: translating to English would ignore the language the menu just picked.
        let options = makeOptions(task: .transcribe, model: modelName, language: language)
        retranscribeRequest = RetranscribeRequest(
            entryID: entryID, modelName: modelName, language: options.language
        )
        let runToken = nextFileRunToken()
        stopTakeRunForNewWork()
        cancelAndTrack(&fileTranscribeTask)
        cancelLinkFetch()
        fileTranscribeTask = Task { [weak self] in
            await self?.runRetranscription(
                entryID: entryID, modelName: modelName, options: options, runToken: runToken, kind: kind
            )
        }
    }

    private func runRetranscription(
        entryID: LibraryEntry.ID,
        modelName: String,
        options: TranscriptionOptions,
        runToken: Int,
        kind: RunLanding.Kind
    ) async {
        var landing: Task<LibraryEntry, any Error>?
        var landed: Transcript?
        var engineFile: URL?
        defer { if let engineFile { try? FileManager.default.removeItem(at: engineFile) } }
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
            let meeting = await isMeetingStereo(audioURL, source: loaded.entry.manifest.source)
            if meeting { engineFile = await meetingEngineInput(for: audioURL) }
            let result = try await session.transcribe(
                source: FileAudioSource(url: engineFile ?? audioURL),
                options: meeting ? meetingOptions(options, stereo: audioURL) : options,
                downloadProgress: makeDownloadProgressHandler(for: modelName),
                partialHandler: makeFilePartialHandler(runToken: runToken),
                progressHandler: makeFileProgressHandler(runToken: runToken),
                stageHandler: makeFileStageHandler(fileURL: audioURL, runToken: runToken)
            )
            var processed = await postProcessDetached(result)
            if meeting { processed.sourceURL = audioURL }
            // The engine stamps the bundle file it read; a link's entry keeps pointing at its page.
            if let page = loaded.document.transcript.sourceURL, !page.isFileURL { processed.sourceURL = page }
            // Post-processing is a suspension a cancel can land in, and past this line the old
            // transcript is gone: check rather than overwrite a take the user stopped.
            try Task.checkCancellation()
            var rerun = RunLanding.rerun(of: entryID, transcript: processed, clearingNotes: loaded.entry.segmentNotes)
            if kind == .retriedTake {
                rerun = RunLanding(
                    kind: .retriedTake,
                    transcript: processed,
                    audioSource: audioURL,
                    source: loaded.entry.manifest.source,
                    category: loaded.entry.category,
                    title: Self.transcribedTitle(from: loaded.entry.title) ?? loaded.entry.title,
                    rerunEntryID: entryID,
                    clearingNotes: loaded.entry.segmentNotes
                )
            }
            landing = land(rerun)
            landed = processed
        } catch {
            // applyTranscriptionError parks a cancelled run at .idle and a failed one at .failed;
            // either way the phase stops reading "transcribing" once this task has let go.
            if fileRunGeneration == runToken { applyTranscriptionError(error) }
        }
        if let landing {
            let saved = (try? await landing.value) != nil
            if saved, let landed { assignMePerson(in: entryID, transcript: landed) }
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
