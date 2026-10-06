import Foundation

/// A reading unit whose audio, trailing pause included, has finished playing.
public struct UnitFinished: Hashable, Sendable {
    public let epoch: Int
    public let unitID: Int

    public init(epoch: Int, unitID: Int) {
        self.epoch = epoch
        self.unitID = unitID
    }
}

/// Where a reading's audio plays. The session schedules each unit's chunks with its epoch and the voice's
/// gain, then closes the unit with `finishUnit`, which adds the trailing pause (a unit with no audio gets
/// only that). `unitFinishedEvents()` reports each closed unit once it has played; a new call finishes the
/// previous stream, so one session listens at a time.
@MainActor
public protocol ReadAloudOutputSink: AnyObject {
    var speed: Double { get set }

    func unitFinishedEvents() -> AsyncStream<UnitFinished>

    func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double)

    func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double)

    func pause(fade: Bool)

    func resume() throws

    func stop()
}
