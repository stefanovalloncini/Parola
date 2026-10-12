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
    private let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("labeler-models-tests-\(UUID().uuidString)"))

    @Test("takes share one load")
    func sharesOneLoad() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock())
        await models.prepare(store: store)
        #expect(try await models.embed([0, 0, 0][...], store: store) == [3])
        #expect(try await models.embed([0][...], store: store) == [1])
        await models.prepare(store: store)
        #expect(probe.loads.value == 1)
    }

    @Test("the models unload after the idle timeout and load again on the next embed")
    func idleUnloadThenReload() async throws {
        let probe = LoadProbe()
        let clock = TestClock()
        let models = makeModels(probe, clock: clock)
        _ = try await models.embed([0][...], store: store)
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        await probe.releases.wait(atLeast: 1, "the idle unload")
        #expect(await !models.isResident)

        _ = try await models.embed([0][...], store: store)
        #expect(probe.loads.value == 2)
    }

    @Test("an embed pushes the idle unload back")
    func embedRearmsTheTimer() async throws {
        let probe = LoadProbe()
        let clock = TestClock()
        let models = makeModels(probe, clock: clock)
        _ = try await models.embed([0][...], store: store)
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout - .seconds(1))
        _ = try await models.embed([0][...], store: store)
        clock.advance(by: ModelResidency.idleTimeout - .seconds(1))
        await clock.waitForSleeper()
        #expect(await models.isResident)
        #expect(probe.releases.value == 0)
    }

    @Test("a failed load is not retried until the next take prepares")
    func failureLatchesUntilPrepare() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock(), failures: 1)
        await #expect(throws: LoadFailed.self) { try await models.embed([0][...], store: store) }
        await #expect(throws: LoadFailed.self) { try await models.embed([0][...], store: store) }
        #expect(probe.loads.value == 1)

        await models.prepare(store: store)
        #expect(try await models.embed([0][...], store: store) == [1])
        #expect(probe.loads.value == 2)
    }

    @Test("unload drops the models at once, as memory pressure does")
    func unloadDropsTheModels() async throws {
        let probe = LoadProbe()
        let models = makeModels(probe, clock: TestClock())
        _ = try await models.embed([0][...], store: store)
        await models.unload()
        #expect(await !models.isResident)
        await probe.releases.wait(atLeast: 1, "the models to be released")
    }
}
