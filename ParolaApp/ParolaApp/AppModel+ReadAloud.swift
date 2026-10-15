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
    func readAloud(_ request: ReadAloudRequest) async -> ReadAloudRefusal? {
        if let blocked = readingBlockedReason { return .blocked(blocked) }
        guard let material = await readingMaterial(for: request.entryID) else {
            return request.entryID == nil ? .noTranscript : .unknownEntry
        }
        let transcript = material.transcript
        let source: ReadingSource
        let language: String
        let uiLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        switch request.kind {
        case .transcript:
            source = .transcript(fromSegment: request.fromSegment)
            language = SpokenLanguage.forTranscript(transcript, uiLanguage: uiLanguage)
        case .translation:
            guard let translation = transcript.translation else { return .nothingToRead }
            source = .translation(language: translation.targetLanguage)
            language = SpokenLanguage.forTranslation(targetLanguage: translation.targetLanguage)
        case .summary:
            guard let summary = transcript.summary else { return .nothingToRead }
            source = .summary
            language = SpokenLanguage.forSummary(
                text: summary.text,
                chapterTitles: summary.chapters.map(\.title),
                actionItems: summary.actionItems,
                transcriptLanguage: SpokenLanguage.forTranscript(transcript, uiLanguage: uiLanguage)
            )
        }
        let units = await readingUnits(source, of: transcript, language: language)
        guard !units.isEmpty else { return .nothingToRead }
        if let blocked = readingBlockedReason { return .blocked(blocked) }
        await readAloud.start(ReadAloudController.Plan(
            entryID: material.id, source: source, title: material.title, language: language, units: units
        ))
        return nil
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

    func skipReading(by direction: Int) async {
        await readAloud.skip(by: direction)
    }

    func stopReading() async {
        await readAloud.stop()
    }

    func retryReading() async {
        await readAloud.retry()
    }

    func setReadingSpeed(_ rate: Double) {
        guard ReadAloudController.speeds.contains(rate) else { return }
        readAloudRate = rate
    }
}
