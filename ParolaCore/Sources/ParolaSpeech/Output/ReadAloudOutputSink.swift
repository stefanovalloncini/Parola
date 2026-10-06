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

/// Where a reading's audio plays; one sink serves every reading. A caller subscribes with
/// `unitFinishedEvents()` before its first `schedule` or `finishUnit`. Each call starts a new generation:
/// it finishes the previous stream and drops the completions of everything scheduled before it, whatever
/// their epoch, and `stop()` drops every pending completion the same way. Chunks carry the caller's epoch
/// and the voice's gain; `finishUnit` closes a unit and adds its trailing pause (a unit with no audio gets
/// only that), and the stream reports the unit once all of it has played. After a subscription or a
/// `stop()` the sink is idle and holds what is scheduled until `resume()`. A caller whose stream ends
/// without its own `stop()` was superseded, by another subscription or by the sink itself when the output
/// device changes and it pauses: it doesn't report the reading finished, and to go on it subscribes again
/// and reschedules from its current unit.
@MainActor
public protocol ReadAloudOutputSink: AnyObject, Sendable {
    var speed: Double { get }

    func setSpeed(_ speed: Double)

    func unitFinishedEvents() -> AsyncStream<UnitFinished>

    func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double)

    func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double)

    func pause(fade: Bool)

    func resume() throws

    func stop()
}
