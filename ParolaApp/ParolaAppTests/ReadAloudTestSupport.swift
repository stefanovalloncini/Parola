import CoreAudio
import Foundation
import ParolaCore
import ParolaSpeech
import Testing
@testable import Parola

@MainActor
final class FakeReadAloudSink: ReadAloudOutputSink {
    enum Call: Equatable {
        case setSpeed(Double)
        case subscribe
        case schedule(unitID: Int)
        case finishUnit(Int)
        case pause(fade: Bool)
        case resume
        case stop
    }

    private(set) var calls: [Call] = []
    private(set) var speed: Double = 1
    private(set) var pending: [UnitFinished] = []
    private var listener: AsyncStream<UnitFinished>.Continuation?

    var scheduledCount: Int { calls.filter { if case .schedule = $0 { true } else { false } }.count }
    var resumeCount: Int { calls.filter { $0 == .resume }.count }
    var stopCount: Int { calls.filter { $0 == .stop }.count }

    func setSpeed(_ speed: Double) {
        calls.append(.setSpeed(speed))
        self.speed = speed
    }

    func unitFinishedEvents() -> AsyncStream<UnitFinished> {
        calls.append(.subscribe)
        pending.removeAll()
        listener?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: UnitFinished.self)
        listener = continuation
        return stream
    }

    func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double) {
        calls.append(.schedule(unitID: chunk.unitID))
    }

    func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double) {
        calls.append(.finishUnit(unitID))
        pending.append(UnitFinished(epoch: epoch, unitID: unitID))
    }

    func pause(fade: Bool) {
        calls.append(.pause(fade: fade))
    }

    func resume() throws {
        calls.append(.resume)
    }

    func stop() {
        calls.append(.stop)
        pending.removeAll()
    }

    @discardableResult
    func completeNextUnit() -> Bool {
        guard !pending.isEmpty else { return false }
        listener?.yield(pending.removeFirst())
        return true
    }

    func simulateOutputChange() {
        pending.removeAll()
        listener?.finish()
        listener = nil
    }
}

@MainActor
final class FakeDeviceMonitor: OutputDeviceMonitoring {
    var onChange: (@MainActor () -> Void)?
    private(set) var isWatching = false

    func start(boundDevice: AudioDeviceID?) { isWatching = true }
    func stop() { isWatching = false }
    func simulateChange() { onChange?() }
}

final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Hashable {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    typealias Duration = Swift.Duration

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var cancelledIDs: Set<UUID> = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    var minimumResolution: Swift.Duration { .zero }

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledIDs.insert(id)
                lock.unlock()
            }
        }
    }

    func advance(by duration: Swift.Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        let now = currentInstant
        var due: [Sleeper] = []
        sleepers.removeAll { sleeper in
            guard sleeper.deadline <= now else { return false }
            due.append(sleeper)
            return true
        }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }
}

@MainActor
final class ReadAloudRig {
    let sink = FakeReadAloudSink()
    let nowPlaying = RecordingNowPlaying()
    let clock = TestClock()
    let systemCenter = NotificationCenter()
    let appCenter = NotificationCenter()
    let renderer: MockSpeechRenderer
    let controller: ReadAloudController
    var blocked: ReadAloudController.BlockedReason?
    var introShown = false
    var players: [PlayerHandle] = []

    init(
        languages: Set<String> = [],
        failAtUnit: Int? = nil,
        events: MockSpeechRenderer.Observer? = nil,
        output: (any ReadAloudOutputSink)? = nil
    ) {
        let renderer = MockSpeechRenderer(
            capabilities: SpeechRendererCapabilities(
                languages: languages, expandsNumbers: true, usesNeuralEngine: false, nominalRTF: 0, maxUnitChars: 400
            ),
            secondsPerUnit: 0.2,
            failAtUnit: failAtUnit,
            observer: events
        )
        self.renderer = renderer
        let sink = sink
        let nowPlaying = nowPlaying
        let systemCenter = systemCenter
        let appCenter = appCenter
        let clock = clock
        controller = ReadAloudController(environment: ReadAloudEnvironment(
            renderer: { renderer },
            sink: { output ?? sink },
            nowPlaying: { nowPlaying },
            refreshVoices: {},
            systemNotifications: { systemCenter },
            appNotifications: appCenter,
            clock: clock,
            mockVoice: nil
        ))
        controller.bind(
            blocked: { [unowned self] in self.blocked },
            introductionShown: { [unowned self] in self.introShown },
            players: { [unowned self] in self.players }
        )
    }

    static func plan(
        units: Int = 3,
        entryID: String = "entry",
        source: ReadingSource = .transcript(fromSegment: nil),
        language: String = "en",
        title: String = "Weekly sync"
    ) -> ReadAloudController.Plan {
        ReadAloudController.Plan(
            entryID: entryID,
            source: source,
            title: title,
            language: language,
            units: (0..<units).map { index in
                ReadingUnit(
                    id: index,
                    text: "Sentence number \(index).",
                    anchors: [.init(anchor: .segment(index), range: NSRange(location: 0, length: 5))],
                    language: language,
                    pauseAfter: 0.1
                )
            }
        )
    }

    func start(_ plan: ReadAloudController.Plan = ReadAloudRig.plan()) async {
        await controller.start(plan)
        await waitUntil { self.controller.state == .reading }
    }
}

extension ReadAloudRig {
    func finishUnit() async {
        await waitUntil { !self.sink.pending.isEmpty }
        sink.completeNextUnit()
    }
}

final class SpeechEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MockSpeechRenderer.Event] = []

    var events: [MockSpeechRenderer.Event] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var observer: MockSpeechRenderer.Observer {
        { [self] event in
            lock.lock()
            stored.append(event)
            lock.unlock()
        }
    }
}
