import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("TranscriptionCoordinator")
@MainActor
struct TranscriptionCoordinatorTests {
    private func makeCoordinator() throws -> (TranscriptionCoordinator, LibraryStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-coord-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let library = LibraryStore(libraryURL: tmp)
        let settings = UserSettings()
        return (TranscriptionCoordinator(library: library, settings: settings), library)
    }

    @Test("partial event updates livePartialText")
    func partialUpdates() throws {
        let (coord, _) = try makeCoordinator()
        coord.handleStreamingEvent(.partial(text: "hello"))
        #expect(coord.livePartialText == "hello")
        coord.handleStreamingEvent(.partial(text: "hello world"))
        #expect(coord.livePartialText == "hello world")
    }

    @Test("confirmed event appends to liveSegments and clears partial")
    func confirmedAppendsAndClears() throws {
        let (coord, _) = try makeCoordinator()
        coord.handleStreamingEvent(.partial(text: "hello"))
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.")
        coord.handleStreamingEvent(.confirmed(segment))
        #expect(coord.liveSegments.count == 1)
        #expect(coord.liveSegments.first?.text == "Hello.")
        #expect(coord.livePartialText == "")
    }

    @Test("failed event flips phase to failed")
    func failedFlipsPhase() throws {
        let (coord, _) = try makeCoordinator()
        coord.handleStreamingEvent(.failed("boom"))
        #expect(coord.phase == .failed(message: "boom"))
    }

    @Test("reset clears partial, segments, and phase")
    func resetClearsState() throws {
        let (coord, _) = try makeCoordinator()
        coord.handleStreamingEvent(.partial(text: "hi"))
        coord.handleStreamingEvent(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi.")))
        coord.handleStreamingEvent(.failed("oops"))

        coord.reset()
        #expect(coord.phase == .idle)
        #expect(coord.liveSegments.isEmpty)
        #expect(coord.livePartialText == "")
    }

    @Test("finished event after cancelRecording does not persist")
    func cancelRecordingDiscards() async throws {
        let (coord, library) = try makeCoordinator()
        var observed: LibraryEntry?
        coord.onComplete = { entry in observed = entry }

        coord.cancelRecording()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "Discarded")],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        coord.handleStreamingEvent(.finished(transcript))

        try await Task.sleep(for: .milliseconds(100))
        #expect(observed == nil)
        let entries = await library.list()
        #expect(entries.isEmpty)
    }

    @Test("finished event saves a transcript-only library entry")
    func finishedPersistsTranscript() async throws {
        let (coord, library) = try makeCoordinator()
        var observed: LibraryEntry?
        coord.onComplete = { entry in observed = entry }

        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "Hi")],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        coord.handleStreamingEvent(.finished(transcript))

        for _ in 0..<50 {
            if observed != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(observed != nil)

        let entries = await library.list()
        #expect(entries.count == 1)
        let loaded = try await library.load(entries[0].id)
        #expect(loaded.document.audioURL == nil)
        #expect(loaded.document.transcript.segments.first?.text == "Hi")
    }
}
