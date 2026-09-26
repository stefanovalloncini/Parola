import Foundation

public actor MockStreamingTranscriber: StreamingTranscriber {
    private let response: MockTranscriberResponse
    private let sleeper: @Sendable (Int) async -> Void
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private var emitTask: Task<Void, Never>?

    public init<C: Clock>(response: MockTranscriberResponse, clock: C) where C.Duration == Duration {
        self.response = response
        self.sleeper = { ms in try? await Task.sleep(for: .milliseconds(ms), clock: clock) }
    }

    public func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        if let fraction = response.downloadFractions.first { downloadProgress?(fraction) }
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = cont
        let response = self.response
        let sleeper = self.sleeper
        emitTask = Task {
            let perStep = response.partials.isEmpty ? 0 : response.delayMs / response.partials.count
            for partial in response.partials {
                if Task.isCancelled { return }
                cont.yield(.partial(text: partial))
                if perStep > 0 { await sleeper(perStep) }
            }
            // Failure with canned segments models a take that dies mid-stream:
            // the confirmed segments land first, then the failure.
            var nextID = 0
            for seed in response.segments {
                if Task.isCancelled { return }
                cont.yield(.confirmed(TranscriptSegment(id: nextID, start: seed.start, end: seed.end, text: seed.text, speaker: seed.speaker)))
                nextID += 1
            }
            if let failure = response.failure {
                cont.yield(.failed(failure.message))
                return
            }
        }
        return stream
    }

    public func stop() async {
        await emitTask?.value
        emitTask = nil
        continuation?.yield(.finished(response.materialise(sourceURL: nil)))
        continuation?.finish()
        continuation = nil
    }

    public func cancel() async {
        emitTask?.cancel()
        emitTask = nil
        continuation?.finish()
        continuation = nil
    }

    public func currentModel() async -> String? { response.modelName }
}
