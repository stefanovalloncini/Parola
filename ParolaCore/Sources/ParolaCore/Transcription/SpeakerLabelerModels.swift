import Foundation
import FluidAudio

/// The diarizer models a live take's speaker labeler embeds with, kept loaded between takes and dropped after `idleTimeout` or on memory pressure.
actor SpeakerLabelerModels {
    static let shared = SpeakerLabelerModels()

    typealias Embedder = (ArraySlice<Float>) throws -> [Float]
    typealias Loader = @Sendable (ModelStore) throws -> sending Embedder

    private final class Resident {
        let embed: Embedder
        init(embed: @escaping Embedder) { self.embed = embed }
    }

    private let loader: Loader
    private let idleTimeout: Duration
    private let clock: any Clock<Duration>
    private var resident: Resident?
    private var failure: (any Error)?
    private var idleUnload = IdleUnloadTimer()
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    init(
        loader: @escaping Loader = SpeakerLabelerModels.loadInstalled,
        idleTimeout: Duration = ModelResidency.idleTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.loader = loader
        self.idleTimeout = idleTimeout
        self.clock = clock
    }

    var isResident: Bool { resident != nil }

    /// Starts a take's use of the models: a load that failed earlier is tried again, and one not yet resident begins now.
    func prepare(store: ModelStore) {
        failure = nil
        installPressureSourceIfNeeded()
        _ = try? residentModels(store: store)
        armIdleUnload()
    }

    func embed(_ window: ArraySlice<Float>, store: ModelStore) throws -> [Float] {
        installPressureSourceIfNeeded()
        let models = try residentModels(store: store)
        defer { armIdleUnload() }
        return try models.embed(window)
    }

    func unload() {
        idleUnload.disarm()
        resident = nil
    }

    private func residentModels(store: ModelStore) throws -> Resident {
        if let resident { return resident }
        if let failure { throw failure }
        do {
            let loaded = Resident(embed: try loader(store))
            resident = loaded
            return loaded
        } catch {
            failure = error
            throw error
        }
    }

    private func armIdleUnload() {
        guard resident != nil else { return }
        idleUnload.arm(after: idleTimeout, clock: clock) { [weak self] epoch in
            await self?.unloadAfterIdle(epoch: epoch)
        }
    }

    private func unloadAfterIdle(epoch: Int) {
        guard idleUnload.isCurrent(epoch) else { return }
        resident = nil
        ParolaLog.info(.streaming, "speaker labeler models unloaded after idle", [.elapsed: .duration(idleTimeout)])
    }

    private func unloadUnderPressure() {
        guard resident != nil else { return }
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
