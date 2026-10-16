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

// @unchecked: every mutable field sits behind `lock`.
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
final class ActivityLog {
    private(set) var begun = 0
    private(set) var ended = 0

    var held: Int { begun - ended }

    var seam: ReadAloudActivity {
        ReadAloudActivity(
            begin: { [self] in
                begun += 1
                return NSObject()
            },
            end: { [self] _ in ended += 1 }
        )
    }
}

@MainActor
final class ReadAloudRig {
    let sink = FakeReadAloudSink()
    let nowPlaying = RecordingNowPlaying()
    let clock = TestClock()
    let activity = ActivityLog()
    let systemCenter = NotificationCenter()
    let appCenter = NotificationCenter()
    let renderer: MockSpeechRenderer
    let cancelGate: CancelGateRenderer?
    let controller: ReadAloudController
    var blocked: ReadAloudController.BlockedReason?
    private(set) var blockedReads = 0
    var blockedFromRead: Int?
    var introShown = false
    var players: [PlayerHandle] = []

    init(
        languages: Set<String> = [],
        failAtUnit: Int? = nil,
        events: MockSpeechRenderer.Observer? = nil,
        output: (any ReadAloudOutputSink)? = nil,
        gatesCancel: Bool = false
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
        let cancelGate = gatesCancel ? CancelGateRenderer(renderer) : nil
        self.cancelGate = cancelGate
        let sink = sink
        let nowPlaying = nowPlaying
        let systemCenter = systemCenter
        let appCenter = appCenter
        let clock = clock
        let activity = activity
        controller = ReadAloudController(environment: ReadAloudEnvironment(
            renderer: { () -> any SpeechRenderer in
                if let cancelGate { return cancelGate }
                return renderer
            },
            sink: { output ?? sink },
            nowPlaying: { nowPlaying },
            refreshVoices: {},
            systemNotifications: { systemCenter },
            appNotifications: appCenter,
            clock: clock,
            mockVoice: nil,
            activity: activity.seam
        ))
        controller.bind(
            blocked: { [unowned self] in
                self.blockedReads += 1
                if let from = self.blockedFromRead, self.blockedReads >= from { return .take }
                return self.blocked
            },
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

// @unchecked: `stored` is only read or written under `lock`.
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

/// A renderer whose `cancel()` waits for the test, so a stop that must finish first can be seen not finishing.
actor CancelGateRenderer: SpeechRenderer {
    nonisolated let engine: SpeechEngineKind
    nonisolated let capabilities: SpeechRendererCapabilities
    private let inner: MockSpeechRenderer
    private var isHolding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelCalls = 0

    init(_ inner: MockSpeechRenderer) {
        self.inner = inner
        engine = inner.engine
        capabilities = inner.capabilities
    }

    func holdCancel() {
        isHolding = true
    }

    func releaseCancel() {
        isHolding = false
        let released = waiters
        waiters.removeAll()
        for waiter in released { waiter.resume() }
    }

    func render(
        text: String, unitID: Int, voice: VoiceID, language: String
    ) async throws -> AsyncThrowingStream<PCMChunk, any Error> {
        try await inner.render(text: text, unitID: unitID, voice: voice, language: language)
    }

    func cancel() async {
        cancelCalls += 1
        if isHolding { await withCheckedContinuation { waiters.append($0) } }
        await inner.cancel()
    }

    func prewarm(voice: VoiceID, language: String) async throws {
        try await inner.prewarm(voice: voice, language: language)
    }
}
