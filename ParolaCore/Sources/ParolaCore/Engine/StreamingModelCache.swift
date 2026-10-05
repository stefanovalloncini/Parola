import Foundation
import os
@preconcurrency import WhisperKit

// Safe because borrowers only read the kit (a session decodes with a TextDecoder of its own) and the cache unloads or reloads its models only while no lease on it is out.
struct SharedWhisperKit: @unchecked Sendable {
    let kit: WhisperKit
}

/// A model borrowed from the streaming cache. The model stays loaded while any lease on it is
/// out, so release it once nothing decodes with it; a lease dropped unreleased is returned late.
public final class StreamingModelLease: Sendable {
    let shared: SharedWhisperKit
    public let modelName: String
    private let cache: StreamingModelCache
    private let isReleased = OSAllocatedUnfairLock(initialState: false)

    init(shared: SharedWhisperKit, modelName: String, cache: StreamingModelCache) {
        self.shared = shared
        self.modelName = modelName
        self.cache = cache
    }

    public func release() async {
        guard markReleased() else { return }
        await cache.returnLease(modelName)
    }

    private func markReleased() -> Bool {
        isReleased.withLock { released in
            defer { released = true }
            return !released
        }
    }

    deinit {
        guard markReleased() else { return }
        Task { [cache, modelName] in await cache.returnDroppedLease(modelName) }
    }
}

/// Keeps loaded streaming WhisperKit instances alive across sessions so a dictation press
/// or live-captions start doesn't pay the model load again. Borrowers share one instance
/// per model name and hold a lease while they decode; loads are single-flight. A model with
/// no lease out unloads after `idleTimeout` or on memory pressure and keeps its kit, so the
/// next borrow reloads only the CoreML models.
actor StreamingModelCache {
    static let shared = StreamingModelCache()

    typealias Loader = @Sendable (_ modelName: String, _ store: ModelStore) async throws -> SharedWhisperKit
    typealias Reloader = @Sendable (SharedWhisperKit) async throws -> Void
    typealias Unloader = @Sendable (SharedWhisperKit) async -> Void

    private struct Entry {
        let shared: SharedWhisperKit
        var isResident = true
        var unloading: Task<Void, Never>?
    }

    private struct Load {
        let id: Int
        let task: Task<SharedWhisperKit, Error>
        var dropUnlessLeased = false
    }

    private let loader: Loader
    private let reloader: Reloader
    private let unloader: Unloader
    private let idleTimeout: Duration
    private let clock: any Clock<Duration>
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Load] = [:]
    private var leases: [String: Int] = [:]
    private var currentModelName: String?
    private var lastLoadID = 0
    private(set) var droppedLeases = 0
    private var idleUnload = IdleUnloadTimer()
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    init(
        loader: @escaping Loader = StreamingModelCache.loadKit,
        reloader: @escaping Reloader = StreamingModelCache.reloadKit,
        unloader: @escaping Unloader = StreamingModelCache.unloadKit,
        idleTimeout: Duration = ModelResidency.idleTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.loader = loader
        self.reloader = reloader
        self.unloader = unloader
        self.idleTimeout = idleTimeout
        self.clock = clock
    }

    func borrow(_ modelName: String, store: ModelStore) async throws -> StreamingModelLease {
        installPressureSourceIfNeeded()
        idleUnload.disarm()
        // Counted before the load is awaited, so an evict or pressure unload landing while the load
        // is in flight already sees this borrower.
        leases[modelName, default: 0] += 1
        do {
            let shared = try await residentKit(modelName, store: store)
            return StreamingModelLease(shared: shared, modelName: modelName, cache: self)
        } catch {
            returnLease(modelName)
            throw error
        }
    }

    /// Loads the model without holding it: it idles out unless a borrow comes first.
    func warm(_ modelName: String, store: ModelStore) async {
        installPressureSourceIfNeeded()
        _ = try? await residentKit(modelName, store: store)
        armIdleUnloadIfUnleased()
    }

    func returnLease(_ modelName: String) {
        let remaining = max(leaseCount(for: modelName) - 1, 0)
        leases[modelName] = remaining == 0 ? nil : remaining
        if remaining == 0 { armIdleUnloadIfUnleased() }
    }

    func returnDroppedLease(_ modelName: String) {
        droppedLeases += 1
        ParolaLog.fault(.streaming, "a model lease was dropped without release", [.model: .safe(ModelToken(modelName))])
        returnLease(modelName)
    }

    func leaseCount(for modelName: String) -> Int {
        leases[modelName, default: 0]
    }

    func residentModelNames() -> [String] {
        entries.filter(\.value.isResident).keys.sorted()
    }

    /// Unloads every model no lease holds; a load nobody has borrowed is dropped when it lands.
    @discardableResult
    func unloadUnleased() -> [String] {
        for name in inFlight.keys where leaseCount(for: name) == 0 {
            inFlight[name]?.dropUnlessLeased = true
        }
        return unloadIdleModels()
    }

    /// Drops the model and its kit unless a lease holds it, so deleting its files frees the disk.
    func evict(_ modelName: String) {
        guard leaseCount(for: modelName) == 0 else { return }
        inFlight[modelName]?.dropUnlessLeased = true
        entries[modelName] = nil
    }

    func unloadAll() {
        idleUnload.disarm()
        for load in inFlight.values { load.task.cancel() }
        entries.removeAll()
        inFlight.removeAll()
    }

    private func residentKit(_ modelName: String, store: ModelStore) async throws -> SharedWhisperKit {
        // Borrowing a new name is a model switch: dropping the other entries frees their
        // multi-GB kits once running sessions release theirs.
        currentModelName = modelName
        entries = entries.filter { $0.key == modelName }
        if let entry = entries[modelName], entry.isResident { return entry.shared }
        if let pending = inFlight[modelName] {
            return try await Self.awaitCancellable(pending.task)
        }
        return try await Self.awaitCancellable(startLoad(modelName, store: store))
    }

    private func startLoad(_ modelName: String, store: ModelStore) -> Task<SharedWhisperKit, Error> {
        lastLoadID &+= 1
        let loadID = lastLoadID
        let load: @Sendable () async throws -> SharedWhisperKit
        if let kept = entries[modelName] {
            let reloader = reloader
            load = { [shared = kept.shared, unloading = kept.unloading] in
                await unloading?.value
                try await reloader(shared)
                return shared
            }
        } else {
            let loader = loader
            load = { try await loader(modelName, store) }
        }
        // Books its own result before any borrower resumes; Task {}, not detached, so the log scope follows the load.
        let task = Task { [weak self] in
            let kit: SharedWhisperKit
            do {
                kit = try await load()
            } catch {
                if !isCancellation(error) {
                    ParolaLog.error(
                        .streaming, "model load failed",
                        [.model: .safe(ModelToken(modelName)), .error: .error(error)]
                    )
                }
                await self?.finishLoad(modelName, loadID: loadID, kit: nil)
                throw error
            }
            await self?.finishLoad(modelName, loadID: loadID, kit: kit)
            return kit
        }
        inFlight[modelName] = Load(id: loadID, task: task)
        return task
    }

    private func finishLoad(_ modelName: String, loadID: Int, kit: SharedWhisperKit?) {
        guard let load = inFlight[modelName], load.id == loadID else { return }
        inFlight[modelName] = nil
        let unleased = leaseCount(for: modelName) == 0
        // Cache only the latest requested name: a switch may have superseded this load
        // while it ran, and caching both would leave two multi-GB kits resident.
        guard let kit, currentModelName == modelName, !(load.dropUnlessLeased && unleased) else {
            entries[modelName] = nil
            return
        }
        entries[modelName] = Entry(shared: kit)
        if unleased { armIdleUnloadIfUnleased() }
    }

    private func unloadIdleModels() -> [String] {
        let idle = residentModelNames().filter { leaseCount(for: $0) == 0 }
        idle.forEach(unloadModels(of:))
        return idle
    }

    private func unloadModels(of modelName: String) {
        guard var entry = entries[modelName], entry.isResident, leaseCount(for: modelName) == 0 else { return }
        let unloader = unloader
        let shared = entry.shared
        entry.isResident = false
        entry.unloading = Task { await unloader(shared) }
        entries[modelName] = entry
    }

    private func armIdleUnloadIfUnleased() {
        guard residentModelNames().contains(where: { leaseCount(for: $0) == 0 }) else { return }
        idleUnload.arm(after: idleTimeout, clock: clock) { [weak self] epoch in
            await self?.unloadAfterIdle(epoch: epoch)
        }
    }

    private func unloadAfterIdle(epoch: Int) {
        guard idleUnload.isCurrent(epoch) else { return }
        for name in unloadIdleModels() {
            ParolaLog.info(
                .streaming, "model unloaded after idle",
                [.model: .safe(ModelToken(name)), .elapsed: .duration(idleTimeout)]
            )
        }
    }

    private func unloadUnderPressure() {
        for name in unloadUnleased() {
            ParolaLog.notice(.streaming, "model unloaded under memory pressure", [.model: .safe(ModelToken(name))])
        }
    }

    /// Awaits the load task but lets the borrower's own cancellation end the wait: releasing
    /// the dictation key mid-load shouldn't sit out a multi-second (or hung) model load.
    /// The continuation is taken exactly once, by whichever side gets there first.
    private static func awaitCancellable(
        _ task: Task<SharedWhisperKit, Error>
    ) async throws -> SharedWhisperKit {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<SharedWhisperKit, Error>?>(initialState: nil)
        @Sendable func take() -> CheckedContinuation<SharedWhisperKit, Error>? {
            pending.withLock { held in
                defer { held = nil }
                return held
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending.withLock { $0 = continuation }
                Task {
                    let result: Result<SharedWhisperKit, Error>
                    do { result = .success(try await task.value) } catch { result = .failure(error) }
                    take()?.resume(with: result)
                }
            }
        } onCancel: {
            take()?.resume(throwing: CancellationError())
        }
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

    private static func loadKit(modelName: String, store: ModelStore) async throws -> SharedWhisperKit {
        let kit = try await WhisperKit(
            model: modelName,
            downloadBase: store.directory,
            modelFolder: store.installedURL(for: modelName).path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        return SharedWhisperKit(kit: kit)
    }

    private static func reloadKit(_ shared: SharedWhisperKit) async throws {
        try await shared.kit.loadModels()
    }

    private static func unloadKit(_ shared: SharedWhisperKit) async {
        await shared.kit.unloadModels()
    }
}
