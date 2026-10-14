import Foundation

public actor MockStreamingTranscriber: StreamingTranscriber {
    private let response: MockTranscriberResponse
    private let sleeper: @Sendable (Int) async -> Void
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private var emitTask: Task<Void, Never>?
    private var isStarting = false
    private var endedWhileStarting: EndedWhileStarting?
    private var stopsWaitingForModel: [CheckedContinuation<Void, Never>] = []
    public nonisolated let levelMeter = LevelMeter()
    public private(set) var pauseCalls: [Bool] = []

    private enum EndedWhileStarting {
        case stop
        case stopAfterModel
        case cancel
    }

    public nonisolated let source: CaptionSource

    public init<C: Clock>(
        response: MockTranscriberResponse, clock: C, source: CaptionSource = .microphone(deviceUID: nil)
    ) where C.Duration == Duration {
        self.response = response
        self.source = source
        self.sleeper = { ms in try? await Task.sleep(for: .milliseconds(ms), clock: clock) }
    }

    public func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        if let fraction = response.downloadFractions.first { downloadProgress?(fraction) }
        if let gate = response.gate {
            // The gate stands in for the model load, so a stop or cancel landing now ends the take as a real one would.
            isStarting = true
            defer {
                isStarting = false
                releaseStopsWaitingForModel()
            }
            try await gate.wait()
            if endedWhileStarting != .cancel, let failure = response.startFailure { throw failure.asError() }
            switch endedWhileStarting {
            case .cancel?: throw CancellationError()
            case .stop?: return Self.endedBeforeCapture(response)
            case .stopAfterModel?: return Self.finishedAfterModel(response)
            case nil: break
            }
        }
        if response.gate == nil, let failure = response.startFailure { throw failure.asError() }
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

    private static func finishedAfterModel(_ response: MockTranscriberResponse) -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream<StreamingEvent>.makeStream()
        let finished = response.materialise(sourceURL: response.recordedAudio)
        for segment in finished.segments { continuation.yield(.confirmed(segment)) }
        continuation.yield(.finished(finished))
        continuation.finish()
        return stream
    }

    private static func endedBeforeCapture(_ response: MockTranscriberResponse) -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream<StreamingEvent>.makeStream()
        continuation.yield(.finished(Transcript(segments: [], language: response.language, modelName: response.modelName)))
        continuation.finish()
        return stream
    }

    public func setPaused(_ paused: Bool) async {
        pauseCalls.append(paused)
    }

    public func stop() async {
        await response.log?.recordEnding("stop")
        if isStarting, response.waitsForModelOnStop {
            endedWhileStarting = .stopAfterModel
            await withCheckedContinuation { stopsWaitingForModel.append($0) }
            return
        }
        if isStarting {
            endedWhileStarting = .stop
            await response.gate?.open()
            return
        }
        await emitTask?.value
        emitTask = nil
        continuation?.yield(.finished(response.materialise(sourceURL: response.recordedAudio)))
        continuation?.finish()
        continuation = nil
    }

    public func cancel() async {
        await response.log?.recordEnding("cancel")
        if isStarting {
            releaseStopsWaitingForModel()
            endedWhileStarting = .cancel
            await response.gate?.open()
            return
        }
        emitTask?.cancel()
        emitTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// How many stops wait for the gate, so a test can tell one has parked there.
    public var stopsWaitingForModelCount: Int { stopsWaitingForModel.count }

    private func releaseStopsWaitingForModel() {
        let waiting = stopsWaitingForModel
        stopsWaitingForModel = []
        for stop in waiting { stop.resume() }
    }

    public func currentModel() async -> String? { response.modelName }

    public func recordingAudioURL() async -> URL? { response.recordedAudio }
}
