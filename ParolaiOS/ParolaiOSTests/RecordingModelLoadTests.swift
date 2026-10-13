import Foundation
import Testing
@testable import Parola
import ParolaCore

private actor LoadingSession: StreamingTranscriber {
    enum Load: Sendable {
        case fails(String)
        case cancelsOnItsOwn
        case finishes(Transcript)
    }

    private let load: Load
    private let audio: URL?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loading = false
    private(set) var cancelCalls = 0

    private let stopWaitsForLoad: Bool

    init(load: Load, audio: URL? = nil, stopWaitsForLoad: Bool = true) {
        self.load = load
        self.audio = audio
        self.stopWaitsForLoad = stopWaitsForLoad
    }

    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        loading = true
        if !released { await withCheckedContinuation { gate = $0 } }
        if cancelCalls > 0 { throw CancellationError() }
        switch load {
        case .fails(let message):
            throw ParolaError.engineLoadFailed(message)
        case .cancelsOnItsOwn:
            throw CancellationError()
        case .finishes(let transcript):
            return AsyncStream { continuation in
                continuation.yield(.finished(transcript))
                continuation.finish()
            }
        }
    }

    func stop() async {
        guard stopWaitsForLoad, loading, !released else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func cancel() async {
        cancelCalls += 1
        if let audio { try? FileManager.default.removeItem(at: audio) }
        release()
    }

    func currentModel() async -> String? { nil }
    func recordingAudioURL() async -> URL? { audio }

    func release() {
        released = true
        gate?.resume()
        gate = nil
        for waiter in stopWaiters { waiter.resume() }
        stopWaiters = []
    }
}

private func makeAudio(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-recording-\(UUID().uuidString).wav")
    try Data(count: bytes).write(to: url)
    return url
}

@Suite("Recording while the model loads")
@MainActor
struct RecordingModelLoadTests {
    private func makeCoordinator(session: LoadingSession) throws -> (TranscriptionCoordinator, LibraryStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let library = LibraryStore(libraryURL: tmp)
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        let coord = TranscriptionCoordinator(library: library, settings: settings)
        coord.makeStreamingSession = { session }
        coord.requestMicrophonePermission = { true }
        return (coord, library)
    }

    @Test("Finish during the model load shows the finishing state and ignores a second Finish", .timeLimit(.minutes(1)))
    func finishDuringLoadShowsFinishing() async throws {
        let session = LoadingSession(load: .finishes(Transcript(segments: [], language: "en", modelName: "")))
        let (coord, _) = try makeCoordinator(session: session)
        coord.startRecording()
        while await !session.loading { await Task.yield() }

        coord.stopRecording()

        #expect(coord.phase == .finishing)
        coord.stopRecording()
        #expect(coord.phase == .finishing)
        await session.release()
        try await pollUntil { coord.phase == .idle }
    }

    @Test("Cancel after Finish during the load cancels the waiting session and leaves nothing behind", .timeLimit(.minutes(1)))
    func cancelAfterFinishDuringLoad() async throws {
        let audio = try makeAudio(bytes: 20_000)
        defer { try? FileManager.default.removeItem(at: audio) }
        let session = LoadingSession(load: .finishes(Transcript(
            segments: [], language: "en", modelName: "", sourceURL: audio
        )), audio: audio)
        let (coord, library) = try makeCoordinator(session: session)
        coord.startRecording()
        while await !session.loading { await Task.yield() }
        coord.stopRecording()

        coord.cancel()
        coord.reset()

        try await pollUntil { !FileManager.default.fileExists(atPath: audio.path) }
        #expect(await session.cancelCalls == 1)
        #expect(coord.phase == .idle)
        #expect(await library.list().isEmpty)
    }

    @Test("a finished take that was cancelled removes its working file")
    func cancelledFinishedTakeRemovesItsFile() async throws {
        let audio = try makeAudio(bytes: 20_000)
        defer { try? FileManager.default.removeItem(at: audio) }
        let (coord, library) = try makeCoordinator(session: LoadingSession(load: .fails("unused")))
        coord.cancelRecording()

        coord.handleStreamingEvent(.finished(Transcript(segments: [], language: "en", modelName: "", sourceURL: audio)), generation: 0)

        try await pollUntil { !FileManager.default.fileExists(atPath: audio.path) }
        #expect(await library.list().isEmpty)
    }

    @Test("a saved take removes its working file once the library holds the audio", .timeLimit(.minutes(1)))
    func savedTakeRemovesItsFile() async throws {
        let audio = try makeAudio(bytes: 20_000)
        defer { try? FileManager.default.removeItem(at: audio) }
        let (coord, library) = try makeCoordinator(session: LoadingSession(load: .fails("unused")))
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello there")

        coord.handleStreamingEvent(.finished(Transcript(segments: [segment], language: "en", modelName: "", sourceURL: audio)), generation: 0)

        try await pollUntil { !FileManager.default.fileExists(atPath: audio.path) }
        #expect(await library.list().count == 1)
    }

    @Test("a model that fails to load after capture lands the audio as an entry and says so", .timeLimit(.minutes(1)))
    func loadFailureKeepsTheAudio() async throws {
        let audio = try makeAudio(bytes: 20_000)
        defer { try? FileManager.default.removeItem(at: audio) }
        let session = LoadingSession(load: .fails("the model would not load"), audio: audio)
        let (coord, library) = try makeCoordinator(session: session)
        var salvaged = 0
        coord.onSalvage = { salvaged += 1 }
        coord.startRecording()
        while await !session.loading { await Task.yield() }

        await session.release()

        try await pollUntil { if case .failed = coord.phase { return true } else { return false } }
        let entries = await library.list()
        #expect(entries.count == 1)
        #expect(salvaged == 1)
        if case .failed(let message) = coord.phase { #expect(message.contains("saved to your library")) }
        #expect(!FileManager.default.fileExists(atPath: audio.path), "the working copy goes once the entry holds the audio")
        #expect(!coord.isRecordingSessionActive)
    }

    @Test("a model that fails to load before any audio leaves no file and no entry", .timeLimit(.minutes(1)))
    func loadFailureWithoutAudioKeepsNothing() async throws {
        let audio = try makeAudio(bytes: 44)
        defer { try? FileManager.default.removeItem(at: audio) }
        let session = LoadingSession(load: .fails("the model would not load"), audio: audio)
        let (coord, library) = try makeCoordinator(session: session)
        coord.startRecording()
        while await !session.loading { await Task.yield() }

        await session.release()

        try await pollUntil { if case .failed = coord.phase { return true } else { return false } }
        #expect(await library.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("Cancel during the load does not turn into a failure once the load unwinds", .timeLimit(.minutes(1)))
    func cancelDuringLoadStaysIdle() async throws {
        let session = LoadingSession(load: .fails("unused"))
        let (coord, _) = try makeCoordinator(session: session)
        coord.startRecording()
        while await !session.loading { await Task.yield() }

        let recording = coord.streamingTask
        coord.cancel()
        coord.reset()

        await recording?.value
        #expect(coord.phase == .idle)
        #expect(!coord.isRecordingSessionActive)
    }

    @Test("a second Record while the first take is finishing is ignored", .timeLimit(.minutes(1)))
    func recordDuringFinishingIsIgnored() async throws {
        let session = LoadingSession(load: .finishes(Transcript(segments: [], language: "en", modelName: "")))
        let (coord, _) = try makeCoordinator(session: session)
        let made = Counter()
        coord.makeStreamingSession = { made.count += 1; return session }
        coord.startRecording()
        while await !session.loading { await Task.yield() }
        coord.stopRecording()

        coord.startRecording()

        #expect(made.count == 1)
        #expect(coord.phase == .finishing)
        await session.release()
        try await pollUntil { coord.phase == .idle }
    }

    @Test("a cancellation nobody asked for is a failure, not a quiet exit", .timeLimit(.minutes(1)))
    func unaskedCancellationFails() async throws {
        let session = LoadingSession(load: .cancelsOnItsOwn)
        let (coord, _) = try makeCoordinator(session: session)
        coord.startRecording()
        while await !session.loading { await Task.yield() }

        await session.release()

        try await pollUntil { if case .failed = coord.phase { return true } else { return false } }
    }

    @Test("finishing keeps the words on screen and a download tick does not leave the finishing phase", .timeLimit(.minutes(1)))
    func finishingKeepsTheTranscriptAndPhase() async throws {
        let session = LoadingSession(load: .finishes(Transcript(segments: [], language: "en", modelName: "")))
        let (coord, _) = try makeCoordinator(session: session)
        coord.startRecording()
        while await !session.loading { await Task.yield() }
        coord.handleStreamingEvent(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "so far")))
        let progress = coord.makeDownloadProgressHandler(resumingTo: { .recording })

        coord.stopRecording()
        progress(0.4)
        await Task.yield()
        await Task.yield()

        #expect(coord.phase == .finishing)
        #expect(coord.liveSegments.map(\.text) == ["so far"])
        await session.release()
        try await pollUntil { coord.phase == .idle }
    }

    @Test("a stop that returns at once during a download keeps the take finishing until its stream ends", .timeLimit(.minutes(1)))
    func stopDuringADownloadKeepsFinishing() async throws {
        let session = LoadingSession(
            load: .finishes(Transcript(segments: [], language: "en", modelName: "")), stopWaitsForLoad: false
        )
        let (coord, _) = try makeCoordinator(session: session)
        let made = Counter()
        coord.makeStreamingSession = { made.count += 1; return session }
        coord.startRecording()
        while await !session.loading { await Task.yield() }
        let progress = coord.makeDownloadProgressHandler(resumingTo: { .recording })

        coord.stopRecording()
        progress(0.4)
        await Task.yield()
        await Task.yield()
        coord.startRecording()

        #expect(coord.phase == .finishing)
        #expect(made.count == 1, "a second Record is ignored until the first take's stream ends")
        progress(1)
        await Task.yield()
        await Task.yield()
        #expect(coord.phase == .finishing, "the end of a download hands the phase back to finishing, not recording")
        await session.release()
        try await pollUntil { coord.phase == .idle }
    }
}

@MainActor
private final class Counter {
    var count = 0
}
