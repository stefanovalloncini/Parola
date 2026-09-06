import Foundation
import os
@preconcurrency import WhisperKit

// Safe because borrowers only read model components off the kit; concurrent reads match what
// WhisperKit's own transcribe TaskGroup does when concurrentWorkerCount > 1.
struct SharedWhisperKit: @unchecked Sendable {
    let kit: WhisperKit
}

/// Keeps loaded streaming WhisperKit instances alive across sessions so a dictation press
/// or live-captions start doesn't pay the model load again. Borrowers share one instance
/// per model name; loads are single-flight. Eviction is explicit (`unloadAll`) or driven
/// by the critical memory-pressure hook; sessions never unload on stop.
actor StreamingModelCache {
    static let shared = StreamingModelCache()

    typealias Loader = @Sendable (_ modelName: String, _ store: ModelStore) async throws -> SharedWhisperKit

    private let loader: Loader
    private var loaded: [String: SharedWhisperKit] = [:]
    private var inFlight: [String: Task<SharedWhisperKit, Error>] = [:]
    private var currentModelName: String?
    private var evictionEpoch = 0
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    init(loader: @escaping Loader = StreamingModelCache.loadKit) {
        self.loader = loader
    }

    func borrow(_ modelName: String, store: ModelStore) async throws -> SharedWhisperKit {
        installPressureSourceIfNeeded()
        // Borrowing a new name is a model switch: dropping the other entries frees their
        // multi-GB kits once running sessions release theirs.
        currentModelName = modelName
        loaded = loaded.filter { $0.key == modelName }
        if let shared = loaded[modelName] { return shared }
        if let pending = inFlight[modelName] {
            return try await Self.awaitCancellable(pending)
        }

        let loader = loader
        let task = Task { try await loader(modelName, store) }
        inFlight[modelName] = task
        let myEpoch = evictionEpoch
        // Bookkeeping is detached from the borrower: a cancelled borrow returns early while
        // the load runs on, and this is what lands the finished kit in the cache.
        // Task {}, not detached: the log scope has to follow this bookkeeping.
        Task { [weak self] in
            let kit: SharedWhisperKit?
            do {
                kit = try await task.value
            } catch {
                kit = nil
                if !isCancellation(error) {
                    ParolaLog.error(
                        .streaming, "model load failed",
                        [.model: .safe(ModelToken(modelName)), .error: .error(error)]
                    )
                }
            }
            await self?.finishLoad(modelName, epoch: myEpoch, kit: kit)
        }
        return try await Self.awaitCancellable(task)
    }

    private func finishLoad(_ modelName: String, epoch: Int, kit: SharedWhisperKit?) {
        guard evictionEpoch == epoch else { return }
        inFlight[modelName] = nil
        // Cache only the latest requested name: a switch may have superseded this load
        // while it ran, and caching both would leave two multi-GB kits resident.
        if let kit, currentModelName == modelName {
            loaded[modelName] = kit
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

    func unloadAll() {
        evictionEpoch += 1
        for task in inFlight.values { task.cancel() }
        loaded.removeAll()
        inFlight.removeAll()
    }

    private func installPressureSourceIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.unloadAll() }
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
}
