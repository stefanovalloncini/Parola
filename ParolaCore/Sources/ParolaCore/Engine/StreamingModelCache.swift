import Foundation
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
        if let pending = inFlight[modelName] { return try await pending.value }

        let loader = loader
        let task = Task { try await loader(modelName, store) }
        inFlight[modelName] = task
        let myEpoch = evictionEpoch
        do {
            let shared = try await task.value
            if evictionEpoch == myEpoch {
                inFlight[modelName] = nil
                // Cache only the latest requested name: a switch may have superseded this load
                // while it ran, and caching both would leave two multi-GB kits resident.
                if currentModelName == modelName {
                    loaded[modelName] = shared
                }
            }
            return shared
        } catch {
            if evictionEpoch == myEpoch {
                inFlight[modelName] = nil
            }
            throw error
        }
    }

    func unloadAll() {
        evictionEpoch += 1
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
