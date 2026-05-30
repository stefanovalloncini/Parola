import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("AppModel speaker renames")
@MainActor
struct AppModelSpeakersTests {
    private func makeModel() throws -> (AppModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-appmodel-speakers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (AppModel(libraryURL: tmp, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), tmp)
    }

    private func twoSpeakerTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello", speaker: "SPEAKER_00"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hi there", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "How are you", speaker: "SPEAKER_00"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
    }

    @Test("rewrites every segment for the renamed speaker")
    func rewritesMatchingSegments() async throws {
        let (model, _) = try makeModel()
        let entry = try await model.library.add(transcript: twoSpeakerTranscript(), audioSource: nil)

        let updated = await model.applySpeakerRenames(
            ["SPEAKER_00": "Alice"],
            on: twoSpeakerTranscript(),
            entryID: entry.id
        )

        #expect(updated.segments[0].speaker == "Alice")
        #expect(updated.segments[2].speaker == "Alice")
        #expect(updated.segments[1].speaker == "SPEAKER_01")
    }

    @Test("trims whitespace around the new name")
    func trimsName() async throws {
        let (model, _) = try makeModel()
        let entry = try await model.library.add(transcript: twoSpeakerTranscript(), audioSource: nil)

        let updated = await model.applySpeakerRenames(
            ["SPEAKER_01": "  Bob \n"],
            on: twoSpeakerTranscript(),
            entryID: entry.id
        )

        #expect(updated.segments[1].speaker == "Bob")
    }

    @Test("a blank replacement name leaves the speaker untouched")
    func skipsBlankNames() async throws {
        let (model, _) = try makeModel()
        let entry = try await model.library.add(transcript: twoSpeakerTranscript(), audioSource: nil)

        let updated = await model.applySpeakerRenames(
            ["SPEAKER_00": "   "],
            on: twoSpeakerTranscript(),
            entryID: entry.id
        )

        #expect(updated.segments[0].speaker == "SPEAKER_00")
        #expect(updated.segments[2].speaker == "SPEAKER_00")
    }

    @Test("the rename is persisted to the library bundle")
    func persistsRename() async throws {
        let (model, _) = try makeModel()
        let entry = try await model.library.add(transcript: twoSpeakerTranscript(), audioSource: nil)

        _ = await model.applySpeakerRenames(
            ["SPEAKER_00": "Alice", "SPEAKER_01": "Bob"],
            on: twoSpeakerTranscript(),
            entryID: entry.id
        )

        let loaded = try await model.library.load(entry.id)
        #expect(loaded.document.transcript.uniqueSpeakers.sorted() == ["Alice", "Bob"])
    }
}
