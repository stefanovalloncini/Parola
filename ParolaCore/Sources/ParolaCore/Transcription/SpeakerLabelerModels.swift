import Foundation
import FluidAudio

/// The diarizer models a live take's speaker labeler embeds with, kept loaded between takes. They unload `idleTimeout`
/// after the last take ends, or when memory pressure lands with no take running; a take in progress keeps them.
actor SpeakerLabelerModels {
    static let shared = SpeakerLabelerModels()

    typealias Embedder = (ArraySlice<Float>) throws -> [Float]
    typealias Loader = @Sendable (ModelStore) throws -> sending Embedder

    private final class Resident {
        let embed: Embedder
        init(embed: @escaping Embedder) { self.embed = embed }
    }

    private let store: ModelStore
    private let loader: Loader
    private let idleTimeout: Duration
    private let clock: any Clock<Duration>
    private var resident: Resident?
    private var failure: (any Error)?
    private var takes = 0
    private var unloadsWhenIdle = false
    private var idleUnload = IdleUnloadTimer()
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    init(
        store: ModelStore = .shared,
        loader: @escaping Loader = SpeakerLabelerModels.loadInstalled,
        idleTimeout: Duration = ModelResidency.idleTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.loader = loader
        self.idleTimeout = idleTimeout
        self.clock = clock
    }

    var isResident: Bool { resident != nil }
    var activeTakes: Int { takes }

    /// A take starts using the models: a load that failed earlier is tried again and the load begins now.
    func beginTake() {
        takes += 1
        failure = nil
        idleUnload.disarm()
        installPressureSourceIfNeeded()
        _ = try? residentModels()
    }

    func ensureLoaded() throws { _ = try residentModels() }

    func endTake() {
        guard takes > 0 else { return }
        takes -= 1
        guard takes == 0 else { return }
        if unloadsWhenIdle {
            unload()
        } else {
            armIdleUnload()
        }
    }

    func embed(_ window: ArraySlice<Float>) throws -> [Float] {
        let models = try residentModels()
        if takes == 0 { armIdleUnload() }
        return try models.embed(window)
    }

    func unload() {
        idleUnload.disarm()
        unloadsWhenIdle = false
        resident = nil
    }

    private func residentModels() throws -> Resident {
        if let resident { return resident }
        if let failure { throw failure }
        do {
            let loaded = Resident(embed: try loader(store))
            resident = loaded
            return loaded
        } catch {
            failure = error
            ParolaLog.error(.streaming, "speaker labeler models failed to load", [.error: .error(error)])
            throw error
        }
    }

    private func armIdleUnload() {
        guard resident != nil, takes == 0 else { return }
        idleUnload.arm(after: idleTimeout, clock: clock) { [weak self] epoch in
            await self?.unloadAfterIdle(epoch: epoch)
        }
    }

    private func unloadAfterIdle(epoch: Int) {
        guard idleUnload.isCurrent(epoch), takes == 0 else { return }
        resident = nil
        ParolaLog.info(.streaming, "speaker labeler models unloaded after idle", [.elapsed: .duration(idleTimeout)])
    }

    private func unloadUnderPressure() {
        guard resident != nil else { return }
        guard takes == 0 else {
            if !unloadsWhenIdle {
                ParolaLog.notice(.streaming, "speaker labeler models will unload when the take ends (memory pressure)")
            }
            unloadsWhenIdle = true
            return
        }
        unload()
        ParolaLog.notice(.streaming, "speaker labeler models unloaded under memory pressure")
    }

    private func installPressureSourceIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.unloadUnderPressure() }
        }
        source.activate()
        pressureSource = source
    }

    /// Tests stand in for the pressure event the dispatch source delivers.
    func simulateMemoryPressure() { unloadUnderPressure() }

    private static func loadInstalled(store: ModelStore) throws -> sending Embedder {
        let dir = IncrementalSpeakerLabeler.modelsDirectory(store: store)
        let models = try DiarizerModels.load(
            localSegmentationModel: dir.appendingPathComponent(ModelNames.Diarizer.segmentationFile),
            localEmbeddingModel: dir.appendingPathComponent(ModelNames.Diarizer.embeddingFile)
        )
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return { window in try manager.extractSpeakerEmbedding(from: window) }
    }
}
