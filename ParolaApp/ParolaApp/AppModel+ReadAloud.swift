import Foundation
import ParolaCore

struct ReadAloudRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transcript
        case summary
        case translation
    }

    var kind: Kind
    var entryID: LibraryEntry.ID?
    var fromSegment: TranscriptSegment.ID?

    init(kind: Kind, entryID: LibraryEntry.ID? = nil, fromSegment: TranscriptSegment.ID? = nil) {
        self.kind = kind
        self.entryID = entryID
        self.fromSegment = fromSegment
    }
}

enum ReadAloudRefusal: Equatable, Sendable {
    case blocked(ReadAloudController.BlockedReason)
    case noTranscript
    case unknownEntry
    case nothingToRead
    case needsVoice
    case noVoice
}

extension AppModel {
    static let unsavedReadingID = "unsaved"

    var readingBlockedReason: ReadAloudController.BlockedReason? {
        if recordingActive { return .take }
        switch dictationState {
        case .listening, .transcribing: return .dictation
        case .idle, .failed: break
        }
        if liveCaptions?.isActive == true { return .captions }
        return nil
    }

    func wireReadAloud() {
        readAloud.bind(
            blocked: { [weak self] in self?.readingBlockedReason },
            introductionShown: { [weak self] in self?.introduction.isPresented ?? false },
            players: { [weak self] in self?.ownPlayers() ?? [] }
        )
        readAloud.setSpeed(readAloudRate)
    }

    @discardableResult
    func readAloud(
        _ request: ReadAloudRequest, using voice: VoiceID? = nil, origin: ReadAloudController.VoicePrompt.Origin = .main
    ) async -> ReadAloudRefusal? {
        if let blocked = readingBlockedReason { return .blocked(blocked) }
        guard let material = await readingMaterial(for: request.entryID) else {
            return request.entryID == nil ? .noTranscript : .unknownEntry
        }
        guard let (source, language) = readingSource(for: request, in: material.transcript) else { return .nothingToRead }
        let units = await readingUnits(source, of: material.transcript, language: language)
        guard !units.isEmpty else { return .nothingToRead }
        if let blocked = readingBlockedReason { return .blocked(blocked) }
        var plan = ReadAloudController.Plan(
            entryID: material.id, source: source, title: material.title, language: language, units: units
        )
        if let voice {
            plan.voice = voice
        } else {
            switch voiceDecision(for: language) {
            case .read(let resolved):
                plan.voice = resolved
            case .chooser:
                readAloud.present(.init(language: language, mode: .choose, request: request, origin: origin))
                return .needsVoice
            case .noVoice:
                let prompt = ReadAloudController.VoicePrompt(language: language, mode: .noVoice, request: request, origin: origin)
                await readAloud.declareNoVoice(plan, prompt: prompt)
                return .noVoice
            }
        }
        await readAloud.start(plan)
        return nil
    }

    private func readingSource(for request: ReadAloudRequest, in transcript: Transcript) -> (ReadingSource, String)? {
        let uiLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let transcriptLanguage = SpokenLanguage.forTranscript(transcript, uiLanguage: uiLanguage)
        switch request.kind {
        case .transcript:
            return (.transcript(fromSegment: request.fromSegment), transcriptLanguage)
        case .translation:
            guard let translation = transcript.translation else { return nil }
            return (
                .translation(language: translation.targetLanguage),
                SpokenLanguage.forTranslation(targetLanguage: translation.targetLanguage)
            )
        case .summary:
            guard let summary = transcript.summary else { return nil }
            return (
                .summary,
                SpokenLanguage.forSummary(
                    text: summary.text,
                    chapterTitles: summary.chapters.map(\.title),
                    actionItems: summary.actionItems,
                    transcriptLanguage: transcriptLanguage
                )
            )
        }
    }

    func voiceDecision(for language: String) -> ReadAloudVoiceDecision {
        let inventory = readAloud.appleInventory
        let saved = readAloudVoices[ReadAloudVoices.key(for: language)]
        return ReadAloudVoices.decide(
            saved: saved,
            savedIsUsable: saved.map { ReadAloudVoices.isUsable($0, for: language, in: inventory) } ?? false,
            neuralOffers: !ReadAloudVoices.neuralOffers(for: language).isEmpty,
            appleVoices: ReadAloudVoices.hasAppleVoice(for: language, in: inventory)
        )
    }

    func presentVoiceChooser(for kind: ReadAloudRequest.Kind) {
        guard let transcript, let (_, language) = readingSource(for: ReadAloudRequest(kind: kind), in: transcript) else { return }
        readAloud.present(.init(
            language: language, mode: chooserMode(for: language), request: ReadAloudRequest(kind: kind), origin: .main
        ))
    }

    func dismissVoicePrompt() {
        readAloud.dismissVoicePrompt()
    }

    func chooseVoice(_ voice: VoiceID, for language: String) async {
        let key = ReadAloudVoices.key(for: language)
        readAloudVoices[key] = voice
        guard let prompt = readAloud.voicePrompt, ReadAloudVoices.key(for: prompt.language) == key else { return }
        readAloud.dismissVoicePrompt()
        if let request = prompt.request { await readAloud(request) }
    }

    func readWithBuiltInVoiceForNow() async {
        guard let prompt = readAloud.voicePrompt else { return }
        readAloud.dismissVoicePrompt()
        if let request = prompt.request { await readAloud(request, using: .appleAutomatic) }
    }

    @discardableResult
    func previewVoice(_ voice: VoiceID, language: String) async -> Bool {
        await readAloud.preview(voice, language: language, text: previewSampleText(for: language))
    }

    func previewSampleText(for language: String) -> String {
        let sentence = transcript?.segments.first { $0.text.split(whereSeparator: \.isWhitespace).count >= 4 }?.text
        let transcriptLanguage = transcript.map {
            SpokenLanguage.forTranscript($0, uiLanguage: Bundle.main.preferredLocalizations.first ?? "en")
        }
        let matches = transcriptLanguage.map { ReadAloudVoices.key(for: $0) == ReadAloudVoices.key(for: language) } ?? false
        return ReadAloudVoices.sampleText(for: language, transcriptSentence: matches ? sentence : nil)
    }

    @discardableResult
    func openMoreVoices() -> Bool {
        ReadAloudVoices.systemSettingsURLs.contains { readAloud.openURL($0) }
    }

    func requestPersonalVoice() async {
        _ = await readAloud.requestPersonalVoice()
        readAloud.refreshVoices()
    }

    func readingUnits(_ source: ReadingSource, of transcript: Transcript, language: String) async -> [ReadingUnit] {
        guard transcript.segments.count > TranscriptDerive.synchronousCap else {
            return ReadingScriptBuilder.build(source, of: transcript, language: language)
        }
        return await Task.detached(priority: .userInitiated) {
            ReadingScriptBuilder.build(source, of: transcript, language: language)
        }.value
    }

    private func readingMaterial(
        for entryID: LibraryEntry.ID?
    ) async -> (id: String, title: String, transcript: Transcript)? {
        if entryID == nil || entryID == selectedEntryID {
            guard let transcript else { return nil }
            return (selectedEntryID ?? Self.unsavedReadingID, readingTitle(of: selectedEntryID), transcript)
        }
        guard let entryID else { return nil }
        if let open = entryWindows.existingSession(for: entryID)?.transcript {
            return (entryID, readingTitle(of: entryID), open)
        }
        guard let loaded = try? await library.load(entryID), loaded.entry.deletedAt == nil else { return nil }
        let title = LibraryEntryDisplay.listTitle(for: loaded.entry, showsAITitle: showAITitles)
        return (entryID, title, loaded.document.transcript)
    }

    private func readingTitle(of entryID: LibraryEntry.ID?) -> String {
        entryID.flatMap { libraryEntry(id: $0) }.map { LibraryEntryDisplay.listTitle(for: $0, showsAITitle: showAITitles) }
            ?? String(localized: "Transcript")
    }

    func pauseReading() async {
        await readAloud.pause()
    }

    @discardableResult
    func resumeReading() async -> ReadAloudRefusal? {
        if let blocked = readingBlockedReason { return .blocked(blocked) }
        await readAloud.resume()
        return nil
    }

    func toggleReading() async {
        switch readAloud.state {
        case .preparing, .reading: await pauseReading()
        default: await resumeReading()
        }
    }

    func skipReading(by direction: Int) async {
        await readAloud.skip(by: direction)
    }

    func stopReading() async {
        await readAloud.stop()
    }

    func retryReading(origin: ReadAloudController.VoicePrompt.Origin = .main) async {
        guard let item = readAloud.item, case .failed = readAloud.state,
              !ReadAloudVoices.isUsable(item.voice, for: item.language, in: readAloud.appleInventory) else {
            await readAloud.retry()
            return
        }
        let kind: ReadAloudRequest.Kind
        switch item.source {
        case .transcript: kind = .transcript
        case .summary: kind = .summary
        case .translation: kind = .translation
        }
        let request = ReadAloudRequest(
            kind: kind,
            entryID: item.entryID == Self.unsavedReadingID ? nil : item.entryID,
            fromSegment: kind == .transcript ? readAloud.failedSegmentID() : nil
        )
        readAloud.present(.init(language: item.language, mode: chooserMode(for: item.language), request: request, origin: origin))
    }

    private func chooserMode(for language: String) -> ReadAloudController.VoicePrompt.Mode {
        let hasVoice = ReadAloudVoices.hasAppleVoice(for: language, in: readAloud.appleInventory)
            || !ReadAloudVoices.neuralOffers(for: language).isEmpty
        return hasVoice ? .choose : .noVoice
    }

    func retryReadingWithBuiltInVoice() async {
        await readAloud.retry(using: .appleAutomatic)
    }

    func setReadingSpeed(_ rate: Double) {
        guard ReadAloudController.speeds.contains(rate) else { return }
        readAloudRate = rate
    }
}

struct ReadAloudMenuTarget: Equatable {
    var request: ReadAloudRequest
    var entryID: String
    var origin: ReadAloudController.VoicePrompt.Origin
    var hasContent: Bool
}

extension AppModel {
    var readAloudMenuTarget: ReadAloudMenuTarget? {
        if let session = keyViewerSession {
            let hasText = session.transcript?.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            return ReadAloudMenuTarget(
                request: ReadAloudRequest(kind: .transcript, entryID: session.entryID),
                entryID: session.entryID,
                origin: .entryWindow(session.entryID),
                hasContent: hasText
            )
        }
        guard transcriptIsOnScreen else { return nil }
        let kind: ReadAloudRequest.Kind
        switch transcriptPaneMode {
        case .transcript: kind = .transcript
        case .summary: kind = .summary
        case .chat: return nil
        }
        return ReadAloudMenuTarget(
            request: ReadAloudRequest(kind: kind),
            entryID: selectedEntryID ?? Self.unsavedReadingID,
            origin: .main,
            hasContent: kind == .summary ? transcript?.summary != nil : !transcriptIsEmpty
        )
    }

    var readingTransport: ReadingTransport {
        ReadingTransport.resolve(
            state: readAloud.state, blocked: readingBlockedReason, sentenceStarted: readAloud.sentenceStarted
        )
    }

    var readAloudMenuStatus: ReadAloudButtonStatus? {
        guard let target = readAloudMenuTarget else { return nil }
        return ReadAloudButtonStatus.resolve(
            state: readAloud.state,
            readsThis: readAloud.reads(entryID: target.entryID, inPane: target.request.kind),
            blocked: readingBlockedReason,
            hasContent: target.hasContent
        )
    }

    func readAloudFromMenu() async {
        guard let target = readAloudMenuTarget, let status = readAloudMenuStatus, status.isEnabled else { return }
        switch status.action {
        case .start: await readAloud(target.request, origin: target.origin)
        case .pause: await pauseReading()
        case .resume: await resumeReading()
        case .retry: await retryReading(origin: target.origin)
        case .none: break
        }
    }
}
