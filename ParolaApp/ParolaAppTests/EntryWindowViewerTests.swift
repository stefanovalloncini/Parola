import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Entry window viewer")
struct EntryWindowViewerTests {

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
        try await PeopleTestSupport.until { model.selectedEntryID == other.id }

        let session = await EntryWindowTestSupport.openSession(model, shown)

        #expect(session.speakerColorIndices.isEmpty)
        #expect(model.speakerColorIndices == ["Grace": grace.colorIndex])
    }

    @Test("a search match is painted, the rest of the line is not")
    func matchesArePainted() {
        let highlighted = EntryViewerText.highlighted(
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
        let highlighted = EntryViewerText.highlighted(
            "alpha alpha",
            matches: [first, second],
            currentMatchID: second.id
        )

        let runs = Array(highlighted.runs)
        #expect(runs.count == 3)
        #expect(runs[0].backgroundColor != runs[2].backgroundColor)
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
