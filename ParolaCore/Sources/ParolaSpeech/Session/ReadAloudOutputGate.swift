import Foundation

/// The session's side of the shared sink: drops stale-epoch audio and what follows an ended stream.
@MainActor
final class ReadAloudOutputGate {
    enum Item: Sendable {
        case chunk(PCMChunk)
        case finish(unitID: Int, pauseAfter: Double)
    }

    enum Output: Sendable {
        case live
        case superseded
    }

    enum Resumed: Sendable {
        case playing
        case superseded
        case failed(any Error)
    }

    private let sink: any ReadAloudOutputSink
    private var epoch = 0
    private var subscription = 0
    private var isLive = false
    private var forwarder: Task<Void, Never>?

    nonisolated init(sink: any ReadAloudOutputSink) {
        self.sink = sink
    }

    func subscribe(id: Int, epoch: Int, session: ReadAloudSession) -> Double {
        self.epoch = epoch
        subscription = id
        let events = sink.unitFinishedEvents()
        isLive = true
        forwarder = Task { [weak self, weak session] in
            for await event in events {
                await session?.unitFinished(event)
            }
            guard let self, self.subscription == id, self.isLive else { return }
            self.isLive = false
            await session?.outputEnded(subscription: id)
        }
        return sink.speed
    }

    func restart(epoch: Int) -> Output {
        self.epoch = epoch
        guard isLive else { return .superseded }
        sink.stop()
        return .live
    }

    func deliver(_ items: [Item], epoch: Int, gainDB: Double) {
        guard isLive, epoch == self.epoch else { return }
        for item in items {
            switch item {
            case .chunk(let chunk):
                sink.schedule(chunk, epoch: epoch, gainDB: gainDB)
            case .finish(let unitID, let pauseAfter):
                sink.finishUnit(unitID, epoch: epoch, pauseAfter: pauseAfter)
            }
        }
    }

    func pause(fade: Bool) {
        sink.pause(fade: fade)
    }

    func resume() -> Resumed {
        guard isLive else { return .superseded }
        do {
            try sink.resume()
            return .playing
        } catch {
            return .failed(error)
        }
    }

    func setSpeed(_ speed: Double) -> Double {
        sink.setSpeed(speed)
        return sink.speed
    }

    func shutDown() {
        let ownsSink = isLive
        isLive = false
        forwarder?.cancel()
        forwarder = nil
        if ownsSink { sink.stop() }
    }
}
