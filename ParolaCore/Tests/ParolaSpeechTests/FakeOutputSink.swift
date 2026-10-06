import Foundation
import ParolaSpeech

@MainActor
final class FakeOutputSink: ReadAloudOutputSink {
    enum Call: Equatable {
        case schedule(PCMChunk, epoch: Int, gainDB: Double)
        case finishUnit(Int, epoch: Int, pauseAfter: Double)
        case pause(fade: Bool)
        case resume
        case stop
    }

    struct ResumeFailure: Error {}

    private(set) var calls: [Call] = []
    var speed: Double = 1
    var failsResume = false
    private var finished: AsyncStream<UnitFinished>.Continuation?

    var scheduledChunks: [PCMChunk] {
        calls.compactMap { call in
            guard case .schedule(let chunk, _, _) = call else { return nil }
            return chunk
        }
    }

    func unitFinishedEvents() -> AsyncStream<UnitFinished> {
        finished?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: UnitFinished.self)
        finished = continuation
        return stream
    }

    func emitUnitFinished(epoch: Int, unitID: Int) {
        finished?.yield(UnitFinished(epoch: epoch, unitID: unitID))
    }

    func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double) {
        calls.append(.schedule(chunk, epoch: epoch, gainDB: gainDB))
    }

    func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double) {
        calls.append(.finishUnit(unitID, epoch: epoch, pauseAfter: pauseAfter))
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
    }
}
