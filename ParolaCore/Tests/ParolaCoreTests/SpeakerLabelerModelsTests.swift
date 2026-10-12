import Foundation
import Testing
@testable import ParolaCore

private final class LoadProbe: Sendable {
    let loads = Awaitable(0)
    let releases = Awaitable(0)
}

private final class ReleaseSignal: Sendable {
    let probe: LoadProbe
    init(_ probe: LoadProbe) { self.probe = probe }
    deinit { probe.releases.increment() }
}

private struct LoadFailed: Error {}

private func makeModels(_ probe: LoadProbe, clock: TestClock, failures: Int = 0) -> SpeakerLabelerModels {
    let remaining = Awaitable(failures)
    return SpeakerLabelerModels(
        store: ModelStore(modelsDirectory: FileManager.default.temporaryDirectory),
        loader: { _ in
            probe.loads.increment()
            if remaining.value > 0 {
                remaining.update { $0 -= 1 }
                throw LoadFailed()
            }
            let signal = ReleaseSignal(probe)
            return { window in
                _ = signal
                return [Float(window.count)]
            }
        },
        clock: clock
    )
}

@Suite("Speaker labeler models")
struct SpeakerLabelerModelsTests {
    @Test("takes share one load")
    func sharesOneLoad() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock())
        await models.beginTake()
        #expect(try await models.embed([0, 0, 0][...]) == [3])
        #expect(try await models.embed([0][...]) == [1])
        await models.endTake()
        await models.beginTake()
        #expect(probe.loads.value == 1)
    }

    @Test("the models unload after the idle timeout once no take is running, and load again on the next embed")
    func idleUnloadThenReload() async throws {
        let probe = LoadProbe()
        let clock = TestClock()
        let models = makeModels(probe, clock: clock)
        await models.beginTake()
        await models.endTake()
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        await probe.releases.wait(atLeast: 1, "the idle unload")
        #expect(await !models.isResident)

        await models.beginTake()
        #expect(probe.loads.value == 2)
    }

    @Test("a take running keeps the models past the idle timeout")
    func takeBlocksIdleUnload() async throws {
        let probe = LoadProbe()
        let clock = TestClock()
        let models = makeModels(probe, clock: clock)
        await models.beginTake()
        _ = try await models.embed([0][...])
        #expect(clock.sleeperCount == 0, "no timer runs while a take is using the models")
        clock.advance(by: ModelResidency.idleTimeout * 3)
        #expect(await models.isResident)
        #expect(probe.releases.value == 0)

        await models.endTake()
        await clock.waitForSleeper()
        #expect(await models.isResident, "the timer starts when the take ends")
    }

    @Test("memory pressure during a take waits for the take to end")
    func pressureWaitsForTheTake() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock())
        await models.beginTake()
        _ = try await models.embed([0][...])
        await models.simulateMemoryPressure()
        #expect(await models.isResident)
        _ = try await models.embed([0][...])
        #expect(probe.loads.value == 1)

        await models.endTake()
        #expect(await !models.isResident)
        await probe.releases.wait(atLeast: 1, "the models to be released")
    }

    @Test("memory pressure with no take running unloads at once")
    func pressureUnloadsWhenIdle() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock())
        await models.beginTake()
        await models.endTake()
        await models.simulateMemoryPressure()
        #expect(await !models.isResident)
    }

    @Test("a failed load is not retried until the next take begins")
    func failureLatchesUntilTheNextTake() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock(), failures: 1)
        await models.beginTake()
        await #expect(throws: LoadFailed.self) { try await models.embed([0][...]) }
        await #expect(throws: LoadFailed.self) { try await models.embed([0][...]) }
        #expect(probe.loads.value == 1)
        await models.endTake()

        await models.beginTake()
        #expect(try await models.embed([0][...]) == [1])
        #expect(probe.loads.value == 2)
    }

    @Test("a labeler holds a take until it is released")
    func labelerHoldsATake() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock())
        var labeler: IncrementalSpeakerLabeler? = IncrementalSpeakerLabeler.labeler(using: models)
        let taking = await eventually { await models.activeTakes == 1 }
        #expect(taking)
        labeler = nil
        let released = await eventually { await models.activeTakes == 0 }
        #expect(released)
        _ = labeler
    }

    @Test("a cancelled label returns nil without waiting for a slow embedding")
    func cancelledLabelDoesNotWait() async throws {
        let gate = TestSignal()
        let labeler = IncrementalSpeakerLabeler { _ in
            await gate.wait("the test to release the embedding")
            return [1, 0]
        }
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")
        let window = [Float](repeating: 0.1, count: 16_000)
        let task = Task { await labeler.labelSpeaker(for: segment, audioWindow: window[...], windowStartTime: 0, sampleRate: 16_000) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(await task.value == nil)
        gate.fire()
    }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
