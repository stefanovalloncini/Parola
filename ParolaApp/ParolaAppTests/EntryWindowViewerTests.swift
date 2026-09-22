import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Entry window viewer")
struct EntryWindowViewerTests {

    @Test("an edit that keeps the segment count still changes the flowing key")
    func aTextEditChangesTheFlowingKey() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerkey")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let before = EntryViewerContinuous.contentSignature(for: session)

        var edited = try #require(session.transcript)
        edited.segments[0].text = "alpha edited"
        try await EntryWindowTestSupport.store(model).updateTranscript(edited, for: entry.id, reindex: false)
        await EntryWindowTestSupport.syncLibrary(model)
        session.reload()
        await session.loadTask?.value

        #expect(session.transcript?.segments.count == 2)
        #expect(session.transcript?.segments.first?.text == "alpha edited")
        #expect(EntryViewerContinuous.contentSignature(for: session) != before)
    }

    @Test("a library bump for another entry does not re-read this one")
    func reloadOnlyFollowsThisEntry() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerreload")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        let session = await EntryWindowTestSupport.openSession(model, entry)
        let loads = session.loadGeneration

        session.reloadIfEntryChanged()
        #expect(session.loadGeneration == loads, "nothing about this entry changed, so nothing is re-read")

        var edited = try #require(session.transcript)
        edited.segments[0].text = "alpha edited"
        try await EntryWindowTestSupport.store(model).updateTranscript(edited, for: entry.id, reindex: false)
        await EntryWindowTestSupport.syncLibrary(model)

        session.reloadIfEntryChanged()
        await session.loadTask?.value
        #expect(session.loadGeneration == loads + 1)
        #expect(session.transcript?.segments.first?.text == "alpha edited")
    }

    @Test("the window reads favorites and the translation from the document")
    func favoritesAndTranslationComeFromTheDocument() async throws {
        let model = EntryWindowTestSupport.makeModel("viewerdoc")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: [nil, nil], audio: nil
        )
        let store = EntryWindowTestSupport.store(model)
        try await store.setFavoriteSegments([1], for: entry.id)
        try await store.setTranslation(
            TranscriptTranslation(
                targetLanguage: "it", segments: [0: "alfa"], createdAt: Date(), provider: "test"
            ),
            for: entry.id
        )

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.favorites == [1])
        #expect(session.translations == [0: "alfa"])
        #expect(session.transcriptText == "alpha beta")
    }

    @Test("a speaker assigned to a person wears that person's colour")
    func speakerColoursFollowThePerson() async throws {
        let model = EntryWindowTestSupport.makeModel("viewercolours")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha", "beta"], speakers: ["Ada", "SPEAKER_01"], audio: nil
        )
        await model.addPerson(named: "Ada")
        let ada = try #require(model.person(named: "Ada"))
        try await EntryWindowTestSupport.store(model).setSpeakerAssignments(["Ada": ada.id], for: entry.id)
        await model.refreshLibraryAndWait()

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.speakerColorIndices == ["Ada": ada.colorIndex])
        #expect(session.speakers == ["Ada", "SPEAKER_01"])
    }

    @Test("the colours belong to the window's entry, not the one the main pane holds")
    func speakerColoursKeyOnTheWindowsEntry() async throws {
        let model = EntryWindowTestSupport.makeModel("viewercolourskey")
        let shown = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: ["Ada"], audio: nil
        )
        let other = try await EntryWindowTestSupport.seed(
            model, texts: ["beta"], speakers: ["Grace"], audio: nil
        )
        await model.addPerson(named: "Grace")
        let grace = try #require(model.person(named: "Grace"))
        try await EntryWindowTestSupport.store(model).setSpeakerAssignments(["Grace": grace.id], for: other.id)
        await model.refreshLibraryAndWait()
        model.loadEntry(other.id)
        await waitUntil(timeoutMs: 3000) { model.selectedEntryID == other.id }

        let session = await EntryWindowTestSupport.openSession(model, shown)

        #expect(session.speakerColorIndices.isEmpty)
        #expect(model.speakerColorIndices == ["Grace": grace.colorIndex])
    }

    @Test("a search match is painted, the rest of the line is not")
    func matchesArePainted() {
        let highlighted = TranscriptSearchHighlight.attributed(
            "alpha beta",
            matches: [TranscriptMatch(segmentID: 0, range: 6..<10)],
            currentMatchID: nil
        )

        let runs = Array(highlighted.runs)
        #expect(runs.count == 2)
        #expect(runs.first?.backgroundColor == nil)
        #expect(runs.last?.backgroundColor != nil)
        #expect(String(highlighted[runs[1].range].characters) == "beta")
    }

    @Test("the match being stepped through is painted differently from the rest")
    func currentMatchStandsOut() {
        let first = TranscriptMatch(segmentID: 0, range: 0..<5)
        let second = TranscriptMatch(segmentID: 0, range: 6..<11)
        let highlighted = TranscriptSearchHighlight.attributed(
            "alpha alpha",
            matches: [first, second],
            currentMatchID: second.id
        )

        let runs = Array(highlighted.runs)
        #expect(runs.count == 3)
        #expect(runs[0].backgroundColor != runs[2].backgroundColor)
    }

    @Test("a match is painted the same way whether the segment carries stray whitespace or not")
    func paintingIgnoresSurroundingWhitespace() {
        let match = TranscriptMatch(segmentID: 0, range: 7..<11)
        let highlighted = TranscriptSearchHighlight.attributed(
            " alpha beta ",
            matches: [match],
            currentMatchID: match.id
        )

        #expect(String(highlighted.characters) == "alpha beta")
        let runs = Array(highlighted.runs)
        #expect(runs.count == 2)
        #expect(String(highlighted[runs[1].range].characters) == "beta")
        #expect(runs[1].backgroundColor != nil)
    }

    @Test("a match inside a flowing-text chunk is painted where the segment sits")
    func flowingChunkMatchesArePainted() {
        var chunk = AttributedString("alpha beta gamma")
        let match = TranscriptMatch(segmentID: 1, range: 1..<5)

        TranscriptSearchHighlight.paint(
            in: &chunk,
            runOffsets: 5..<10,
            rawText: " beta",
            matches: [match],
            currentMatchID: nil
        )

        let painted = Array(chunk.runs).filter { $0.backgroundColor != nil }
        #expect(painted.count == 1)
        #expect(String(chunk[painted[0].range].characters) == "beta")
    }

    @Test("an entry with no audio shows the transcript and no transport")
    func noAudioMeansNoTransport() async throws {
        let model = EntryWindowTestSupport.makeModel("viewernoaudio")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.player == nil)
        #expect(session.transcript?.segments.count == 1)
        #expect(session.loadFailed == false)
    }

    @Test("the window is titled after the entry")
    func windowCarriesTheEntryTitle() async throws {
        let model = EntryWindowTestSupport.makeModel("viewertitle")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        try await EntryWindowTestSupport.store(model).renameEntry(entry.id, to: "Kickoff call")
        await model.refreshLibraryAndWait()

        let session = await EntryWindowTestSupport.openSession(model, entry)

        #expect(session.title == "Kickoff call")
    }
}
