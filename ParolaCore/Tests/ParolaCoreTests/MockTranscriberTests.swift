import Foundation
import Testing
import Clocks
@testable import ParolaCore

@Suite("MockTranscriber + MockTranscriberRegistry")
struct MockTranscriberTests {

    @Test("transcribe returns the materialised transcript and fires every partial")
    func transcribeYieldsSegmentsAndPartials() async throws {
        let response = MockTranscriberResponse(
            segments: [
                TranscriptSegmentSeed(start: 0, end: 1, text: "hello"),
                TranscriptSegmentSeed(start: 1, end: 2, text: "world"),
            ],
            partials: ["hello", "hello world"],
            language: "en",
            durationSeconds: 2,
            modelName: "mock-tiny"
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        let received = LockedBox<[String]>(value: [])
        let url = URL(fileURLWithPath: "/tmp/mock-input.wav")
        let transcript = try await mock.transcribe(
            url: url,
            options: .default,
            handlers: TranscribeHandlers(onPartial: { text in received.mutate { $0.append(text) } })
        )

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.map(\.text) == ["hello", "world"])
        #expect(transcript.language == "en")
        #expect(transcript.modelName == "mock-tiny")
        #expect(transcript.sourceURL == url)
        #expect(received.value == ["hello", "hello world"])
    }

    @Test("transcribe fires progressSeconds through the progress handler, in step with partials")
    func transcribeEmitsProgress() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 3, text: "hi there")],
            partials: ["hi", "hi there"],
            progressSeconds: [1.5, 3.0],
            language: "en",
            durationSeconds: 3,
            modelName: "mock"
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        let partials = LockedBox<[String]>(value: [])
        let progresses = LockedBox<[Double]>(value: [])
        _ = try await mock.transcribe(
            url: URL(fileURLWithPath: "/tmp/mock-input.wav"),
            options: .default,
            handlers: TranscribeHandlers(
                onPartial: { text in partials.mutate { $0.append(text) } },
                onProgress: { value in progresses.mutate { $0.append(value) } }
            )
        )

        #expect(partials.value == ["hi", "hi there"])
        #expect(progresses.value == [1.5, 3.0])
    }

    @Test("a response with no progressSeconds never fires the progress handler")
    func transcribeWithoutProgressStaysSilent() async throws {
        let response = MockTranscriberResponse(
            partials: ["a", "b"],
            durationSeconds: 2
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        let partials = LockedBox<[String]>(value: [])
        let progresses = LockedBox<[Double]>(value: [])
        _ = try await mock.transcribe(
            url: URL(fileURLWithPath: "/tmp/mock-input.wav"),
            options: .default,
            handlers: TranscribeHandlers(
                onPartial: { text in partials.mutate { $0.append(text) } },
                onProgress: { value in progresses.mutate { $0.append(value) } }
            )
        )

        #expect(partials.value == ["a", "b"])
        #expect(progresses.value.isEmpty)
    }

    @Test("transcribe throws the failure error when one is installed")
    func transcribeFailureThrows() async {
        let response = MockTranscriberResponse(
            failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        do {
            _ = try await mock.transcribe(
                url: URL(fileURLWithPath: "/tmp/x.wav"),
                options: .default
            )
            Issue.record("expected transcribe to throw")
        } catch let error as ParolaError {
            guard case .transcriptionFailed(let message) = error else {
                Issue.record("unexpected ParolaError: \(error)")
                return
            }
            #expect(message == "boom")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("cancelling a run parked at the gate throws instead of hanging", .timeLimit(.minutes(1)))
    func cancellingAGatedRunReturns() async throws {
        let gate = MockTranscriberGate()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello")],
            language: "en",
            modelName: "mock-tiny",
            gate: gate
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())
        let atTheGate = LockedBox(value: false)

        let run = Task {
            try await mock.transcribe(
                url: URL(fileURLWithPath: "/tmp/mock-input.wav"),
                options: .default,
                handlers: TranscribeHandlers(onStage: { stage in
                    if stage == .transcribing { atTheGate.mutate { $0 = true } }
                })
            )
        }
        while !atTheGate.value { await Task.yield() }
        await Task.yield()
        run.cancel()

        await #expect(throws: CancellationError.self) { try await run.value }
    }

    @Test("registry install + resolve only matches the engine the mock was installed for")
    func registryResolvesPerEngine() async {
        let registry = MockTranscriberRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "mock"
        )
        await registry.install(engineID: .whisperKit, response: response)

        let whisper = await registry.resolve(for: .whisperKit)
        let parakeet = await registry.resolve(for: .parakeet)

        #expect(whisper?.segments.first?.text == "hi")
        #expect(parakeet == nil)
    }

    @Test("clear() removes every installed mock")
    func clearWipesRegistry() async {
        let registry = MockTranscriberRegistry()
        await registry.install(
            engineID: .whisperKit,
            response: MockTranscriberResponse(modelName: "a")
        )
        await registry.install(
            engineID: nil,
            response: MockTranscriberResponse(modelName: "global")
        )

        await registry.clear()

        #expect(await registry.resolve(for: .whisperKit) == nil)
        #expect(await registry.resolve(for: .parakeet) == nil)
        #expect(await registry.list().isEmpty)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(value: T) { self._value = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func mutate(_ change: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&_value)
    }
}
