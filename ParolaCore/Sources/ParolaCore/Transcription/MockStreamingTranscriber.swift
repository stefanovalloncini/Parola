import Foundation

public actor MockStreamingTranscriber: StreamingTranscriber {
    private let response: MockTranscriberResponse
    private let sleeper: @Sendable (Int) async throws -> Void
    private var continuation: AsyncStream<StreamingEvent>.Continuation?

    public init<C: Clock>(response: MockTranscriberResponse, clock: C) where C.Duration == Duration {
        self.response = response
        self.sleeper = { ms in
            try await Task.sleep(for: .milliseconds(ms), clock: clock)
        }
    }

    public func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = cont

        let partials = response.partials
        let segments = response.segments
        let fractions = response.downloadFractions
        let delayMs = response.delayMs
        let sleeper = self.sleeper

        Task {
            if let first = fractions.first {
                downloadProgress?(first)
            }

            let perStepMs = partials.count > 0 ? max(0, delayMs / partials.count) : 0
            for text in partials {
                cont.yield(.partial(text: text))
                if perStepMs > 0 {
                    try? await sleeper(perStepMs)
                }
            }

            for (index, seed) in segments.enumerated() {
                let segment = TranscriptSegment(
                    id: index,
                    start: seed.start,
                    end: seed.end,
                    text: seed.text,
                    speaker: seed.speaker
                )
                cont.yield(.confirmed(segment))
            }
        }

        return stream
    }

    public func stop() async {
        guard let cont = continuation else { return }
        let transcript = response.materialise(sourceURL: nil)
        cont.yield(.finished(transcript))
        cont.finish()
        continuation = nil
    }

    public func currentModel() async -> String? {
        response.modelName
    }
}
