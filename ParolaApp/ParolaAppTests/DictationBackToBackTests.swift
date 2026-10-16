import CoreGraphics
import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

private final class SpySession: StreamingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private(set) var calls: [String] = []
    let text: String
    let stopGate: AsyncStream<Void>

    init(text: String, stopGate: AsyncStream<Void>) {
        self.text = text
        self.stopGate = stopGate
    }

    var log: [String] { lock.withLock { calls } }

    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingEvent.self)
        lock.withLock { self.continuation = continuation; calls.append("start") }
        continuation.yield(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: text)))
        return stream
    }

    func stopCapturing() async { lock.withLock { calls.append("stopCapturing") } }

    func stop() async {
        lock.withLock { calls.append("stop") }
        for await _ in stopGate {}
        lock.withLock { continuation }?.finish()
    }

    func cancel() async {
        lock.withLock { calls.append("cancel") }
        lock.withLock { continuation }?.finish()
    }

    func currentModel() async -> String? { nil }
}

@MainActor
@Suite("Dictation back-to-back capture")
struct DictationBackToBackCaptureTests {
    @Test("the hotkey modifiers never reach a paste or a typed insertion")
    func eventsCarryOnlyTheirOwnFlags() {
        let paste = ClipboardPasteInserter.cmdVEvents()
        #expect(paste.down?.flags == .maskCommand)
        #expect(paste.up?.flags == .maskCommand)

        let typed = KeystrokeTextInserter.events(for: Array("w".utf16))
        #expect(typed.down?.flags.isEmpty == true)
        #expect(typed.up?.flags.isEmpty == true)
    }

    @Test("a take's mic is released at the stop and its tail decodes while the next take records", .timeLimit(.minutes(1)))
    func nextTakeStartsDuringTheTailDecode() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let made = OSAllocatedUnfairLock<[SpySession]>(initialState: [])
        let texts = OSAllocatedUnfairLock<[String]>(initialState: ["one", "two"])
        let recorder = MicDictationRecorder(
            model: "openai_whisper-large-v3_turbo",
            language: nil,
            streamingEnabled: true,
            makeStreamingSession: {
                let text = texts.withLock { $0.removeFirst() }
                let session = SpySession(text: text, stopGate: gate)
                made.withLock { $0.append(session) }
                return session
            },
            warmFallbackModel: { _ in }
        )

        try await recorder.start()
        await settle()
        let first = try await recorder.stopCapture()
        #expect(made.withLock { $0[0].log } == ["start", "stopCapturing"])

        try await recorder.start()
        #expect(made.withLock { $0.count } == 2)
        let finalizing = Task { try await first.finalize() }
        await waitUntil { made.withLock { $0[0].log.contains("stop") } }
        #expect(made.withLock { $0[1].log } == ["start"], "the next take captures while the first still decodes")

        open.finish()
        #expect(try await finalizing.value == "one")
        #expect(try await recorder.stopAndTranscribe() == "two")
    }

    @Test("an insertion mode is fixed when the take is bound")
    func insertionModeIsBoundAtRelease() async {
        let mode = OSAllocatedUnfairLock(initialState: DictationInsertionMode.keystroke)
        let inserter = PerAppTextInserter(resolver: { _ in mode.withLock { $0 } })
        let configuration = DictationPipelineConfiguration(postProcessor: PassThrough(), pasteDelayMs: 5000)

        let typed = await inserter.bound(to: configuration)
        mode.withLock { $0 = .paste }
        let pasted = await inserter.bound(to: configuration)

        #expect(typed is KeystrokeTextInserter)
        #expect((pasted as? ClipboardPasteInserter)?.preDelayMs == 2000)
    }
}

private struct PassThrough: TextPostProcessor {
    func process(_ text: String) async -> String { text }
}
