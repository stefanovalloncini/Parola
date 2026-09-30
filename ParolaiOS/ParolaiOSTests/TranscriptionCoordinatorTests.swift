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
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
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

    @Test("file-import failure surfaces the error as a failed phase")
    func fileImportFailureFlipsPhase() throws {
        let (coord, _) = try makeCoordinator()
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The file couldn't be opened."]
        )
        coord.reportFileImportFailure(error)
        #expect(coord.phase == .failed(message: "The file couldn't be opened."))
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

    @Test("a failed streaming event releases the recording session so Record works again")
    func failedEventReleasesSession() throws {
        let (coord, _) = try makeCoordinator()
        coord.startRecording()
        #expect(coord.isRecordingSessionActive)

        coord.handleStreamingEvent(.failed("engine died"))

        #expect(coord.phase == .failed(message: "engine died"))
        #expect(
            !coord.isRecordingSessionActive,
            "a leaked session leaves the Record button silently dead"
        )
        coord.cancelRecording()
    }

    @Test("a completed model download hands the phase back to the active flow")
    func downloadCompletionRestoresPhase() async throws {
        let (coord, _) = try makeCoordinator()
        let handler = coord.makeDownloadProgressHandler(resumingTo: { .recording })

        handler(0.4)
        var settled = false
        for _ in 0..<100 {
            if case .downloadingModel = coord.phase { settled = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(settled, "mid-download progress should surface as the downloading phase")

        handler(1.0)
        var restored = false
        for _ in 0..<100 {
            if coord.phase == .recording { restored = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restored, "finishing the download must not leave the phase stuck at downloading")
    }

    @Test("streaming events restore the recording phase after a download stall")
    func streamingEventRestoresRecordingPhase() async throws {
        let (coord, _) = try makeCoordinator()
        let handler = coord.makeDownloadProgressHandler(resumingTo: { .recording })
        handler(0.4)
        var downloading = false
        for _ in 0..<100 {
            if case .downloadingModel = coord.phase { downloading = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloading)

        coord.handleStreamingEvent(.partial(text: "speech arrived"))
        #expect(
            coord.phase == .recording,
            "live speech means the mic is up; the sheet must show Finish, not a spinner"
        )
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
        coord.handleStreamingEvent(.finished(transcript), generation: 0)

        try await Task.sleep(for: .milliseconds(100))
        #expect(observed == nil)
        let entries = await library.list()
        #expect(entries.isEmpty)
    }

    @Test("a picked file lands under its own name, as a file import, and its copy is removed")
    func pickedFileLandsUnderItsName() async throws {
        await MockTranscriberRegistry.shared.install(
            engineID: .appleSpeech,
            response: MockTranscriberResponse(segments: [.init(start: 0, end: 1, text: "hello there")])
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-coord-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let library = LibraryStore(libraryURL: tmp.appendingPathComponent("Library", isDirectory: true))
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settings.modelName = "apple-speech-analyzer"
        let coord = TranscriptionCoordinator(library: library, settings: settings)
        let name = "Interview \(UUID().uuidString.prefix(8))"
        let picked = tmp.appendingPathComponent("\(name).wav")
        try FileManager.default.copyItem(
            at: try #require(Bundle(for: CoordinatorBundleAnchor.self).url(forResource: "sample", withExtension: "wav")),
            to: picked
        )
        let (landings, landing) = AsyncStream.makeStream(of: LibraryEntry.self)
        coord.onComplete = { landing.yield($0) }
        let giveUp = Task {
            try? await Task.sleep(for: .seconds(30))
            landing.finish()
        }

        coord.startFileTranscription(at: picked)
        var landed: LibraryEntry?
        for await entry in landings {
            landed = entry
            break
        }
        giveUp.cancel()
        await MockTranscriberRegistry.shared.clear()

        let entry = try #require(landed, "the picked file never landed")
        #expect(entry.title == name)
        #expect(entry.manifest.source == .file)
        #expect(entry.manifest.originalAudioName == "\(name).wav", "the copy carried the file's own name")
        let temporary = FileManager.default.temporaryDirectory
        let leftovers = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("parola-import-") }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(name).wav").path) }
        #expect(leftovers.isEmpty, "the import copy is removed once the entry holds its own")
        #expect(FileManager.default.fileExists(atPath: picked.path), "the user's file stays where it was")
    }

    @Test("removing an import copy leaves a file outside an import folder alone")
    func removeImportCopyIsScoped() throws {
        let stray = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-stray-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: stray)
        defer { try? FileManager.default.removeItem(at: stray) }

        TranscriptionCoordinator.removeImportCopy(stray)

        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test("a file run cancelled during the rules pass saves nothing")
    func cancelDuringRulesPassSavesNothing() async throws {
        let (coord, library) = try makeCoordinator()
        coord.postProcessor = { TranscriptPostProcessor.orthographyOnly }
        let result = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 0.5, text: "Non so perchè")],
            language: "it",
            modelName: "openai_whisper-tiny"
        )
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("parola-cancelled-\(UUID().uuidString).m4a")

        let run = Task { try await coord.saveFileResult(result, audio: audio) }
        run.cancel()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(await library.list().isEmpty)
    }

    @Test("a take stopped before capture came up saves nothing and goes back to idle")
    func emptyTakeWithoutAudioIsNotSaved() async throws {
        let (coord, library) = try makeCoordinator()
        var observed: LibraryEntry?
        coord.onComplete = { entry in observed = entry }

        coord.handleStreamingEvent(.finished(Transcript(segments: [], language: "en", modelName: "openai_whisper-tiny")))

        try await Task.sleep(for: .milliseconds(200))
        #expect(observed == nil)
        #expect(coord.phase == .idle)
        #expect(await library.list().isEmpty)
    }

    @Test("a short take with audio but no words is still saved")
    func silentTakeWithAudioIsSaved() async throws {
        let (coord, library) = try makeCoordinator()
        var observed: LibraryEntry?
        coord.onComplete = { entry in observed = entry }
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-silent-take-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        coord.handleStreamingEvent(.finished(Transcript(
            segments: [], language: "en", modelName: "openai_whisper-tiny", sourceURL: audio
        )))

        for _ in 0..<50 {
            if observed != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(observed != nil)
        #expect(await library.list().count == 1)
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

private final class CoordinatorBundleAnchor {}
