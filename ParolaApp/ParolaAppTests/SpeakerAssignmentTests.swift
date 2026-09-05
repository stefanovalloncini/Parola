import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Per-segment speaker assignment")
struct SpeakerAssignmentTests {
    let model: AppModel
    let undo = UndoManager()

    init() {
        model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("assignspeaker")
        )
        undo.groupsByEvent = false
        model.undoManager = undo
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Speaker 1"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hi there."),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "Bye.", speaker: "Speaker 2"),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("assigning a speaker touches only the target segment")
    func assignTouchesOneSegment() {
        model.assignSpeaker("Alice", toSegmentID: 1)

        #expect(model.transcript?.segments.map(\.speaker) == ["Speaker 1", "Alice", "Speaker 2"])
        #expect(undo.undoActionName == "Assign Speaker")
    }

    @Test("assigning nil clears the segment's speaker")
    func assignNilClears() {
        model.assignSpeaker(nil, toSegmentID: 0)

        #expect(model.transcript?.segments[0].speaker == nil)
    }

    @Test("a whitespace-only name clears like nil, and names are trimmed")
    func trimsAndTreatsBlankAsNil() {
        model.assignSpeaker("  Bob  ", toSegmentID: 1)
        #expect(model.transcript?.segments[1].speaker == "Bob")

        model.assignSpeaker("   ", toSegmentID: 1)
        #expect(model.transcript?.segments[1].speaker == nil)
    }

    @Test("re-assigning the same speaker registers no undo step")
    func sameSpeakerIsNoOp() {
        model.assignSpeaker("Speaker 1", toSegmentID: 0)
        model.assignSpeaker(nil, toSegmentID: 1)

        #expect(!undo.canUndo)
    }

    @Test("assignment overwrites stale word-level speaker labels")
    func overwritesWordSpeakers() throws {
        var t = try #require(model.transcript)
        t.segments[0].words = [
            WordTiming(id: "0-0", word: "Hello.", start: 0, end: 1, probability: 1, speaker: "Speaker 1")
        ]
        model.transcript = t

        model.assignSpeaker("Alice", toSegmentID: 0)

        #expect(model.transcript?.segments[0].words?.map(\.speaker) == ["Alice"])
    }

    @Test("assignment round-trips through undo and updates the speaker list")
    func undoRoundTripAndSpeakerList() {
        model.assignSpeaker("Alice", toSegmentID: 1)
        #expect(model.transcriptSpeakers == ["Speaker 1", "Alice", "Speaker 2"])

        undo.undo()
        #expect(model.transcript?.segments[1].speaker == nil)
        #expect(model.transcriptSpeakers == ["Speaker 1", "Speaker 2"])

        undo.redo()
        #expect(model.transcript?.segments[1].speaker == "Alice")
    }

    @Test("assigning to a missing segment is a no-op")
    func missingSegmentNoOps() {
        model.assignSpeaker("Alice", toSegmentID: 99)

        #expect(model.transcript?.segments.map(\.speaker) == ["Speaker 1", nil, "Speaker 2"])
        #expect(!undo.canUndo)
    }
}

@MainActor
@Suite("Expected speakers option")
struct ExpectedSpeakersTests {

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("expectedspeakers"))
    }

    @Test("defaults to Auto, which threads nil into the transcription options")
    func defaultsToAuto() {
        let model = makeModel(temporaryDefaults())

        #expect(model.expectedSpeakersRaw == 0)
        #expect(model.currentOptions.expectedSpeakers == nil)
    }

    @Test("a positive count threads into the transcription options")
    func countThreadsIntoOptions() {
        let model = makeModel(temporaryDefaults())
        model.expectedSpeakersRaw = 3

        #expect(model.currentOptions.expectedSpeakers == 3)
    }

    @Test("the count persists in defaults and reloads")
    func persistsAndReloads() {
        let defaults = temporaryDefaults()
        let first = makeModel(defaults)
        first.expectedSpeakersRaw = 4

        #expect(defaults.integer(forKey: "expectedSpeakersRaw") == 4)

        let second = makeModel(defaults)
        #expect(second.expectedSpeakersRaw == 4)

        defaults.set(5, forKey: "expectedSpeakersRaw")
        second.reloadSettings()
        #expect(second.expectedSpeakersRaw == 5)
    }

    @Test("the key belongs to the transcription defaults settings scope")
    func keyIsScoped() {
        #expect(SettingsPaneScope.transcriptionDefaults.defaultsKeys.contains("expectedSpeakersRaw"))
    }
}
