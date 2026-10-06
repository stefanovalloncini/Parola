import Foundation
import ParolaSpeech

@MainActor
final class FakeOutputSink: ReadAloudOutputSink {
    enum Call: Equatable {
        case setSpeed(Double)
        case subscribe
        case schedule(PCMChunk, epoch: Int, gainDB: Double)
        case finishUnit(Int, epoch: Int, pauseAfter: Double)
        case pause(fade: Bool)
        case resume
        case stop
    }

    struct Completion: Hashable {
        let generation: Int
        let finished: UnitFinished
    }

    struct ResumeFailure: Error {}

    private(set) var calls: [Call] = []
    private(set) var speed: Double = 1
    private(set) var pending: [Completion] = []
    private(set) var schedulesBeforeSubscribing = 0
    var failsResume = false
    private var generation = 0
    private var listener: AsyncStream<UnitFinished>.Continuation?

    var scheduledChunks: [PCMChunk] {
        calls.compactMap { call in
            guard case .schedule(let chunk, _, _) = call else { return nil }
            return chunk
        }
    }

    func setSpeed(_ speed: Double) {
        calls.append(.setSpeed(speed))
        self.speed = speed
    }

    func unitFinishedEvents() -> AsyncStream<UnitFinished> {
        calls.append(.subscribe)
        generation += 1
        pending.removeAll()
        listener?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: UnitFinished.self)
        listener = continuation
        return stream
    }

    func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double) {
        calls.append(.schedule(chunk, epoch: epoch, gainDB: gainDB))
        if listener == nil { schedulesBeforeSubscribing += 1 }
    }

    func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double) {
        calls.append(.finishUnit(unitID, epoch: epoch, pauseAfter: pauseAfter))
        if listener == nil { schedulesBeforeSubscribing += 1 }
        pending.append(Completion(generation: generation, finished: UnitFinished(epoch: epoch, unitID: unitID)))
    }

    @discardableResult
    func completeNextUnit() -> UnitFinished? {
        guard let next = pending.first else { return nil }
        return deliver(next) ? next.finished : nil
    }

    @discardableResult
    func deliver(_ completion: Completion) -> Bool {
        pending.removeAll { $0 == completion }
        guard completion.generation == generation, let listener else { return false }
        listener.yield(completion.finished)
        return true
    }

    func pause(fade: Bool) {
        calls.append(.pause(fade: fade))
    }

    func resume() throws {
        calls.append(.resume)
        if failsResume { throw ResumeFailure() }
    }

    func stop() {
        calls.append(.stop)
        generation += 1
        pending.removeAll()
    }
}
