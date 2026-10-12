import Foundation
import ParolaCore

/// The re-run in flight: which entry, and the model and language the engine was handed.
struct RetranscribeRequest: Equatable, Sendable {
    let entryID: LibraryEntry.ID
    let modelName: String
    /// nil is Auto, the same thing it means in the language picker.
    let language: String?
}

/// A re-run the user picked, waiting on the "Transcribe again?" alert.
struct RetranscribeAsk: Equatable, Sendable {
    let modelName: String
    let language: String?
    let choiceLabel: String
    /// Set when the run has to fall back off the entry's own model, so the alert can name it.
    let substituteModelLabel: String?
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

    /// A transcribed entry with its audio and no re-run going: what Transcribe Again needs.
    var canTranscribeAgain: Bool {
        transcript != nil && !transcriptIsUntranscribed && canRetranscribeSelectedEntry && retranscribeRequest == nil
    }

    /// The models a re-run can use without a download.
    var transcribeAgainModels: [ModelVariant] {
        Self.selectableModels(availableModels)
            .filter(\.isInstalled)
            .compactMap { ModelCatalog.variant(id: $0.name) }
    }

    /// Auto and "no language recorded" are the same answer, and the menus offer it once.
    var transcriptLanguageCode: String? {
        let code = transcript?.language ?? ""
        return code.isEmpty ? nil : code
    }

    /// The model a re-run keeps: the entry's own, or the selected one when that one is gone.
    func transcribeAgainModel(among variants: [ModelVariant]) -> String {
        let current = transcript?.modelName ?? ""
        return variants.contains { $0.id == current } ? current : selectedModel
    }

    /// What that model can transcribe, so the language menus can shut the codes it would refuse.
    func transcribeAgainLanguages(among variants: [ModelVariant]) -> ParolaCore.SupportedLanguages {
        ModelCatalog.staticCapabilities(forID: transcribeAgainModel(among: variants))?.supportedLanguages ?? .all
    }

    /// The same model and language as before; the run still reads today's Settings, such as Detect speakers.
    func askToTranscribeAgain() {
        guard canTranscribeAgain else { return }
        let runs = transcribeAgainModel(among: transcribeAgainModels)
        pendingRetranscribe = RetranscribeAsk(
            modelName: runs,
            language: transcriptLanguageCode,
            choiceLabel: Self.modelLabel(runs),
            substituteModelLabel: substituteModelLabel(for: runs)
        )
    }

    /// Picking the model the entry already carries asks nothing: the value menus are for changing it.
    func askToTranscribeAgain(model modelName: String, label: String) {
        guard modelName != transcript?.modelName else { return }
        pendingRetranscribe = RetranscribeAsk(
            modelName: modelName,
            language: transcriptLanguageCode,
            choiceLabel: label,
            substituteModelLabel: nil
        )
    }

    func askToTranscribeAgain(language code: String?, label: String) {
        guard code != transcriptLanguageCode else { return }
        let runs = transcribeAgainModel(among: transcribeAgainModels)
        pendingRetranscribe = RetranscribeAsk(
            modelName: runs,
            language: code,
            choiceLabel: label,
            substituteModelLabel: substituteModelLabel(for: runs)
        )
    }

    func confirmTranscribeAgain() {
        guard let ask = pendingRetranscribe else { return }
        pendingRetranscribe = nil
        retranscribeCurrentEntry(model: ask.modelName, language: ask.language)
    }

    private func substituteModelLabel(for runs: String) -> String? {
        runs == transcript?.modelName ? nil : Self.modelLabel(runs)
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
        defer { discardMeetingScratch([engineFile]) }
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
            if meeting, engineNeedsMonoMix(model: modelName) { engineFile = try await meetingEngineInput(for: audioURL) }
            modelResidency.sessionRunBegan()
            defer { modelResidency.sessionRunEnded() }
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
