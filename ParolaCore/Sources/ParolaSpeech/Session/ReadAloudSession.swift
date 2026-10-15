import Foundation
import ParolaCore

/// What a reading reports while it plays. `unitStarted` comes on `play()`, on a skip, and when the sink
/// reports the unit before it finished; `interrupted` means the sink ended the reading's audio (the output
/// changed) and the reading stays paused until `resume()`.
public enum ReadAloudSessionEvent: Sendable, Hashable {
    public enum WaitReason: Sendable, Hashable {
        case slow
    }

    case unitStarted(index: Int, anchors: [ReadingUnit.Anchored])
    case waiting(WaitReason)
    case interrupted
    case finished
    case failed(String, unit: Int)
}

/// One reading of a script through a renderer and the shared sink. It renders units one at a time, a few
/// ahead of playback, keeps the last two played for Previous, and spells out and cuts each unit for the
/// renderer in use. A unit with nothing to say plays only its pause. `stop()`, the end of the script and a
/// failure end the session; a sink that ends its stream leaves it paused until `resume()`.
public actor ReadAloudSession {
    static let lookAheadUnits = 2
    static let lookAheadSeconds = 10.0
    static let playedUnitsKept = 2
    static let restartThreshold: Duration = .milliseconds(1500)
    static let rtfSmoothing = 0.5

    public nonisolated let events: AsyncStream<ReadAloudSessionEvent>

    private enum Phase {
        case ready
        case playing
        case paused
        case ended
    }

    private enum Ending {
        case finished
        case stopped
        case failed(String, unit: Int)
    }

    private struct UnitAudio {
        var chunks: [PCMChunk] = []
        var duration = 0.0
        var isComplete = false

        mutating func append(_ chunk: PCMChunk) {
            chunks.append(chunk)
            duration += chunk.duration
        }
    }

    private struct VoiceSwitch {
        let renderer: any SpeechRenderer
        let voice: VoiceID
        let gainDB: Double
        let fromUnit: Int
    }

    private struct RenderJob {
        let id: Int
        let unit: Int
        let token: Int
        let renderer: any SpeechRenderer
        let voice: VoiceID
        let language: String
        let pieces: [String]
    }

    private struct ActiveJob {
        let id: Int
        let unit: Int
        let renderer: any SpeechRenderer
        var isRendering = false
        var isConsuming = false
    }

    private struct StaleRender {
        let id: Int
        let renderer: any SpeechRenderer
        let needsCancel: Bool
        let isRendering: Bool
    }

    private enum JobOutcome {
        case rendered(Duration)
        case failed(any Error)
        case abandoned
    }

    private struct Batch {
        let items: [ReadAloudOutputGate.Item]
        let epoch: Int
        let gainDB: Double
    }

    private let units: [ReadingUnit]
    private let language: String
    private let gate: ReadAloudOutputGate
    private let continuation: AsyncStream<ReadAloudSessionEvent>.Continuation
    private let elapsed: @Sendable () -> Duration

    private var renderer: any SpeechRenderer
    private var voice: VoiceID
    private var gainDB: Double
    private var phase = Phase.ready
    private var current: Int
    private var epoch = 0
    private var subscriptionCount = 0
    private var subscription: Int?
    private var hasSubscribed = false
    private var isSuperseded = false
    private var isBlocked = false
    private var speed = 1.0

    private var cache: [Int: UnitAudio] = [:]
    private var scheduledUnit: Int
    private var scheduledChunks = 0
    private var pumpTask: Task<Void, Never>?

    private var renderTask: Task<Void, Never>?
    private var renderToken = 0
    private var lastJobID = 0
    private var activeJob: ActiveJob?
    private var isLaneBusy = false
    private var laneWaiters: [CheckedContinuation<Void, Never>] = []
    private var laneQueueWatchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var pendingCancels = 0
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var renderEndWaiters: [CheckedContinuation<Void, Never>] = []

    private var rtf: Double?
    private var isBaselinePending = true
    private var isAnnouncePending = false
    private var slowHold: Int?
    private var failure: (unit: Int, message: String)?
    private var pendingSwitch: VoiceSwitch?

    private var playedBefore: Duration = .zero
    private var playingSince: Duration?

    public init(
        units: [ReadingUnit],
        renderer: any SpeechRenderer,
        voice: VoiceID,
        language: String,
        sink: any ReadAloudOutputSink,
        clock: any Clock<Duration> = ContinuousClock(),
        startAt: Int = 0,
        gainDB: Double = 0
    ) {
        let start = min(max(startAt, 0), units.count)
        let (events, continuation) = AsyncStream.makeStream(of: ReadAloudSessionEvent.self)
        self.units = units
        self.language = language
        self.gate = ReadAloudOutputGate(sink: sink)
        self.events = events
        self.continuation = continuation
        self.elapsed = Self.stopwatch(clock)
        self.renderer = renderer
        self.voice = voice
        self.gainDB = gainDB
        self.current = start
        self.scheduledUnit = start
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Transport

    public func play() async {
        guard phase == .ready else { return }
        guard current < units.count else {
            await end(.finished)
            return
        }
        phase = .playing
        announce()
        let playEpoch = epoch
        await subscribe(epoch: playEpoch)
        guard epoch == playEpoch, phase == .playing else { return }
        kickRenderer()
        await flushPump()
        guard epoch == playEpoch, phase == .playing, !isSuperseded else { return }
        await resumeOutput()
    }

    public func pause(fade: Bool) async {
        guard phase == .playing else { return }
        phase = .paused
        updateTimer()
        await gate.pause(fade: fade)
    }

    public func resume() async {
        guard phase == .paused else { return }
        phase = .playing
        if !isSuperseded {
            updateTimer()
            let resumeEpoch = epoch
            switch await gate.resume() {
            case .playing:
                kickRenderer()
                requestPump()
                return
            case .failed(let error):
                await end(.failed(String(describing: error), unit: current))
                return
            case .superseded:
                guard epoch == resumeEpoch, isActive, phase == .playing || isSuperseded else { return }
                phase = .playing
            }
        }
        await reposition(to: current, resubscribing: true)
    }

    public func next() async {
        guard isActive else { return }
        await reposition(to: current + 1)
    }

    /// Restarts the current unit once more than 1.5 s of it has played, else goes back one unit.
    public func previous() async {
        guard isActive else { return }
        let target = playedInCurrent > Self.restartThreshold ? current : max(current - 1, 0)
        await reposition(to: target)
    }

    public func stop() async {
        await end(.stopped)
    }

    public func setSpeed(_ speed: Double) async {
        self.speed = await gate.setSpeed(speed)
    }

    /// While blocked, no unit starts scheduling; a unit already scheduling finishes.
    public func setBlocked(_ blocked: Bool) {
        isBlocked = blocked
        if !blocked { requestPump() }
    }

    public func continueReading() {
        guard slowHold != nil else { return }
        slowHold = nil
        rtf = nil
        if isAnnouncePending {
            isAnnouncePending = false
            announce()
        }
        kickRenderer()
        requestPump()
    }

    /// Takes effect at the end of the unit playing now, or at once when nothing of it plays yet or the
    /// reading is paused. The reading goes on from `fromUnit`, rendered again for the new renderer.
    public func switchRenderer(_ renderer: any SpeechRenderer, voice: VoiceID, fromUnit: Int, gainDB: Double = 0) async {
        guard phase != .ended else { return }
        let request = VoiceSwitch(
            renderer: renderer, voice: voice, gainDB: gainDB, fromUnit: min(max(fromUnit, 0), units.count)
        )
        switch phase {
        case .ready:
            adopt(request)
            current = request.fromUnit
            scheduledUnit = current
        case .playing where currentHasAudio:
            pendingSwitch = request
        default:
            pendingSwitch = request
            await reposition(to: request.fromUnit)
        }
    }

    /// Runs the renderer's prewarm between renders, never alongside one.
    public func prewarm() async throws {
        await acquireLane()
        defer { releaseLane() }
        await cancelsSettled()
        try await renderer.prewarm(voice: voice, language: language)
    }

    // MARK: - Sink events

    func unitFinished(_ event: UnitFinished) async {
        guard isActive, event.epoch == epoch, event.unitID == current else { return }
        if let pendingSwitch {
            await reposition(to: pendingSwitch.fromUnit)
            return
        }
        let next = current + 1
        guard next < units.count else {
            await end(.finished)
            return
        }
        if let failure, failure.unit == next {
            await end(.failed(failure.message, unit: failure.unit))
            return
        }
        current = next
        resetTimer()
        trimCache()
        if let slowHold, next > slowHold {
            isAnnouncePending = true
        } else {
            announce()
        }
        kickRenderer()
        requestPump()
    }

    func outputEnded(subscription id: Int) {
        guard id == subscription, isActive else { return }
        markSuperseded()
    }

    // MARK: - Testing

    var cachedUnits: [Int] {
        cache.keys.sorted()
    }

    func laneQueued(_ count: Int) async {
        guard laneWaiters.count < count else { return }
        await withCheckedContinuation { laneQueueWatchers.append((count, $0)) }
    }

    func settlePump() async {
        await pumpTask?.value
    }

    func settle() async {
        while true {
            if let renderTask {
                await renderTask.value
            } else if let pumpTask {
                await pumpTask.value
            } else {
                return
            }
        }
    }

    // MARK: - Position

    private var isActive: Bool {
        phase == .playing || phase == .paused
    }

    private var currentHasAudio: Bool {
        scheduledUnit > current || (scheduledUnit == current && scheduledChunks > 0)
    }

    private var playedInCurrent: Duration {
        playedBefore + (playingSince.map { elapsed() - $0 } ?? .zero)
    }

    private func reposition(to target: Int, resubscribing: Bool = false) async {
        guard target < units.count else {
            await end(.finished)
            return
        }
        epoch += 1
        let repositionEpoch = epoch
        let switching = pendingSwitch
        pendingSwitch = nil
        let stale = abandonActiveJob(unlessNeededFrom: target, force: switching != nil)
        if let switching { adopt(switching) }
        current = target
        scheduledUnit = target
        scheduledChunks = 0
        failure = nil
        isBaselinePending = true
        isAnnouncePending = false
        resetTimer()
        trimCache()
        announce()
        if resubscribing {
            await subscribe(epoch: repositionEpoch)
        } else if !isSuperseded, hasSubscribed {
            let output = await gate.restart(epoch: repositionEpoch)
            if output == .superseded, epoch == repositionEpoch { markSuperseded() }
        }
        if let stale { await finishAbandoning(stale) }
        guard epoch == repositionEpoch, isActive else { return }
        kickRenderer()
        await flushPump()
        guard epoch == repositionEpoch, phase == .playing, !isSuperseded else { return }
        await resumeOutput()
    }

    private func adopt(_ request: VoiceSwitch) {
        renderer = request.renderer
        voice = request.voice
        gainDB = request.gainDB
        cache.removeAll()
        rtf = nil
        isBaselinePending = true
        slowHold = nil
    }

    private func subscribe(epoch: Int) async {
        subscriptionCount += 1
        subscription = subscriptionCount
        isSuperseded = false
        hasSubscribed = true
        speed = await gate.subscribe(id: subscriptionCount, epoch: epoch, session: self)
    }

    private func resumeOutput() async {
        let resumeEpoch = epoch
        switch await gate.resume() {
        case .playing:
            break
        case .superseded:
            if epoch == resumeEpoch { markSuperseded() }
        case .failed(let error):
            await end(.failed(String(describing: error), unit: current))
        }
    }

    private func markSuperseded() {
        guard !isSuperseded, isActive else { return }
        isSuperseded = true
        subscription = nil
        if phase == .playing { phase = .paused }
        updateTimer()
        emit(.interrupted)
    }

    private func end(_ ending: Ending) async {
        guard phase != .ended else { return }
        phase = .ended
        epoch += 1
        pendingSwitch = nil
        slowHold = nil
        subscription = nil
        playingSince = nil
        let stale = abandonActiveJob(unlessNeededFrom: units.count, force: true)
        cache.removeAll()
        switch ending {
        case .finished: emit(.finished)
        case .failed(let message, let unit): emit(.failed(message, unit: unit))
        case .stopped: break
        }
        continuation.finish()
        if hasSubscribed { await gate.shutDown() }
        if let stale { await finishAbandoning(stale) }
    }

    private func announce() {
        emit(.unitStarted(index: current, anchors: units[current].anchors))
    }

    private func emit(_ event: ReadAloudSessionEvent) {
        continuation.yield(event)
    }

    private func trimCache() {
        let keptFrom = current - Self.playedUnitsKept
        cache = cache.filter { $0.key >= keptFrom }
    }

    private func updateTimer() {
        let isRunning = phase == .playing && !isSuperseded && currentHasAudio
        if isRunning, playingSince == nil {
            playingSince = elapsed()
        } else if !isRunning, let since = playingSince {
            playedBefore += elapsed() - since
            playingSince = nil
        }
    }

    private func resetTimer() {
        playedBefore = .zero
        playingSince = nil
        updateTimer()
    }

    // MARK: - Scheduling

    private func requestPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { await self.drainPump() }
    }

    private func flushPump() async {
        requestPump()
        await pumpTask?.value
    }

    private func drainPump() async {
        while let batch = nextBatch() {
            await gate.deliver(batch.items, epoch: batch.epoch, gainDB: batch.gainDB)
        }
        pumpTask = nil
    }

    private func nextBatch() -> Batch? {
        guard isActive, !isSuperseded, subscription != nil else { return nil }
        var items: [ReadAloudOutputGate.Item] = []
        while scheduledUnit < units.count {
            let unit = scheduledUnit
            if scheduledChunks == 0, !mayStartScheduling(unit) { break }
            guard let audio = cache[unit] else { break }
            if scheduledChunks < audio.chunks.count {
                items += audio.chunks[scheduledChunks...].map(ReadAloudOutputGate.Item.chunk)
                scheduledChunks = audio.chunks.count
            }
            guard audio.isComplete else { break }
            items.append(.finish(unitID: unit, pauseAfter: units[unit].pauseAfter))
            scheduledUnit += 1
            scheduledChunks = 0
        }
        guard !items.isEmpty else { return nil }
        updateTimer()
        return Batch(items: items, epoch: epoch, gainDB: gainDB)
    }

    private func mayStartScheduling(_ unit: Int) -> Bool {
        if isBlocked { return false }
        if let slowHold, unit > slowHold { return false }
        if pendingSwitch != nil, unit > current { return false }
        return true
    }

    // MARK: - Rendering

    private func kickRenderer() {
        guard renderTask == nil else { return }
        renderTask = Task { await self.runRenderLoop() }
    }

    private func runRenderLoop() async {
        while let job = nextRenderJob() {
            activeJob = ActiveJob(id: job.id, unit: job.unit, renderer: job.renderer)
            let outcome = await perform(job)
            activeJob = nil
            await complete(job, outcome)
        }
        renderTask = nil
    }

    private func nextRenderJob() -> RenderJob? {
        guard phase == .playing, !isSuperseded, slowHold == nil, failure == nil, pendingSwitch == nil else {
            return nil
        }
        var aheadUnits = 0
        var aheadSeconds = 0.0
        var unit = current
        while unit < units.count {
            if let audio = cache[unit], audio.isComplete {
                if unit > current {
                    aheadUnits += 1
                    aheadSeconds += audio.duration
                }
                unit += 1
                continue
            }
            if unit > current, aheadUnits >= Self.lookAheadUnits, aheadSeconds >= Self.lookAheadSeconds {
                return nil
            }
            let language = units[unit].language ?? self.language
            let pieces = RenderText.pieces(of: units[unit].text, language: language, capabilities: renderer.capabilities)
            guard !pieces.isEmpty else {
                cache[unit] = UnitAudio(isComplete: true)
                requestPump()
                continue
            }
            lastJobID += 1
            return RenderJob(
                id: lastJobID, unit: unit, token: renderToken, renderer: renderer, voice: voice,
                language: language, pieces: pieces
            )
        }
        return nil
    }

    private func perform(_ job: RenderJob) async -> JobOutcome {
        cache[job.unit] = UnitAudio()
        var renderTime = Duration.zero
        for piece in job.pieces {
            await acquireLane()
            await cancelsSettled()
            guard job.token == renderToken else {
                releaseLane()
                return .abandoned
            }
            activeJob?.isRendering = true
            let started = elapsed()
            var thrown: (any Error)?
            do {
                let stream = try await job.renderer.render(
                    text: piece, unitID: job.unit, voice: job.voice, language: job.language
                )
                if job.token == renderToken {
                    activeJob?.isConsuming = true
                } else {
                    await job.renderer.cancel()
                }
                for try await chunk in stream where job.token == renderToken {
                    cache[job.unit]?.append(chunk)
                    requestPump()
                }
            } catch {
                thrown = error
            }
            renderTime += elapsed() - started
            activeJob?.isRendering = false
            activeJob?.isConsuming = false
            resumeAll(&renderEndWaiters)
            releaseLane()
            guard job.token == renderToken else { return .abandoned }
            if let thrown { return .failed(thrown) }
        }
        return .rendered(renderTime)
    }

    private func complete(_ job: RenderJob, _ outcome: JobOutcome) async {
        switch outcome {
        case .abandoned:
            return
        case .failed(let error):
            cache[job.unit] = nil
            ParolaLog.error(
                .readAloud, "a reading unit could not be rendered",
                [.engine: .safe(job.renderer.engine), .error: .error(error)]
            )
            let message = String(describing: error)
            if job.unit == current {
                await end(.failed(message, unit: current))
            } else {
                failure = (job.unit, message)
            }
        case .rendered(let renderTime):
            cache[job.unit]?.isComplete = true
            measure(renderTime, of: job)
            requestPump()
        }
    }

    private func measure(_ renderTime: Duration, of job: RenderJob) {
        guard let audio = cache[job.unit], audio.duration > 0 else { return }
        let sample = renderTime.secondsValue / audio.duration
        if isBaselinePending {
            isBaselinePending = false
            return
        }
        let smoothed = rtf.map { $0 + Self.rtfSmoothing * (sample - $0) } ?? sample
        rtf = smoothed
        guard phase == .playing, job.unit == current, job.unit < units.count - 1, smoothed * speed > 1 else { return }
        slowHold = job.unit
        ParolaLog.notice(
            .readAloud, "the voice renders slower than it plays; the reading waits",
            [.engine: .safe(job.renderer.engine)]
        )
        emit(.waiting(.slow))
    }

    private func abandonActiveJob(unlessNeededFrom target: Int, force: Bool) -> StaleRender? {
        guard let job = activeJob else { return nil }
        if !force, isNeeded(job.unit, from: target) { return nil }
        renderToken += 1
        cache[job.unit] = nil
        if job.isConsuming { pendingCancels += 1 }
        return StaleRender(id: job.id, renderer: job.renderer, needsCancel: job.isConsuming, isRendering: job.isRendering)
    }

    private func isNeeded(_ unit: Int, from target: Int) -> Bool {
        unit >= target && (target..<unit).allSatisfy { cache[$0]?.isComplete == true }
    }

    private func finishAbandoning(_ stale: StaleRender) async {
        if stale.needsCancel {
            await stale.renderer.cancel()
            pendingCancels -= 1
            if pendingCancels == 0 { resumeAll(&cancelWaiters) }
        }
        guard stale.isRendering else { return }
        while let job = activeJob, job.id == stale.id, job.isRendering {
            await withCheckedContinuation { renderEndWaiters.append($0) }
        }
    }

    // MARK: - Renderer lane

    private func acquireLane() async {
        guard isLaneBusy else {
            isLaneBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            laneWaiters.append(continuation)
            let queued = laneWaiters.count
            let ready = laneQueueWatchers.filter { $0.count <= queued }
            laneQueueWatchers.removeAll { $0.count <= queued }
            for watcher in ready { watcher.continuation.resume() }
        }
    }

    private func releaseLane() {
        if laneWaiters.isEmpty {
            isLaneBusy = false
        } else {
            laneWaiters.removeFirst().resume()
        }
    }

    private func cancelsSettled() async {
        while pendingCancels > 0 {
            await withCheckedContinuation { cancelWaiters.append($0) }
        }
    }

    private func resumeAll(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }

    private static func stopwatch<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }
}

private extension Duration {
    var secondsValue: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
