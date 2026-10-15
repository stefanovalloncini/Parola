import Foundation
import ParolaCore

protocol StreamingModelResidency: Sendable {
    func warm(_ name: String) async
    func releaseIdleModels() async
    func evict(_ name: String) async
    func residentModelNames() async -> [String]
    func setIdleTimeout(_ timeout: Duration) async
}

struct LiveStreamingModelResidency: StreamingModelResidency {
    func warm(_ name: String) async { await StreamingTranscriberFactory.prewarm(modelName: name) }
    func releaseIdleModels() async { await StreamingTranscriberFactory.releaseIdleModels() }
    func evict(_ name: String) async { await StreamingTranscriberFactory.evict(modelName: name) }
    func residentModelNames() async -> [String] { await StreamingTranscriberFactory.residentModelNames() }
    func setIdleTimeout(_ timeout: Duration) async { await StreamingTranscriberFactory.setIdleTimeout(timeout) }
}

protocol LoadedModelHolder: Sendable {
    func loadedModelName() async -> String?
    func unloadModel(ifLoaded name: String) async
    func prewarm(modelName: String) async
}

extension TranscriptionSession: LoadedModelHolder {
    func loadedModelName() async -> String? { await currentModel() }
}

@MainActor
final class ModelResidencyCoordinator {
    private let streaming: any StreamingModelResidency
    private let fileWarmWait: Duration
    private var fileSession: (any LoadedModelHolder)?
    private var dictationSession: (@MainActor () -> (any LoadedModelHolder)?)?
    private var fileWarmTask: Task<Void, Never>?
    private var fileWarmGeneration = 0
    private var warmTask: Task<Void, Never>?
    private var pendingUnloads: [Int: Set<String>] = [:]
    private var retry: Task<Void, Never>?
    private var activeFileRuns = 0
    var isInstalled: @MainActor (String) -> Bool = { ModelStore.shared.isInstalled($0) }
    private(set) var warmingModel: String?
    private(set) var warmEpoch = 0

    private static let fileHolder = 0
    private static let dictationHolder = 1

    init(streaming: any StreamingModelResidency, fileWarmWait: Duration = .seconds(30)) {
        self.streaming = streaming
        self.fileWarmWait = fileWarmWait
    }

    func attach(fileSession: any LoadedModelHolder, dictationSession: @escaping @MainActor () -> (any LoadedModelHolder)?) {
        self.fileSession = fileSession
        self.dictationSession = dictationSession
    }

    private var holders: [any LoadedModelHolder] {
        [fileSession, dictationSession?() ?? nil].compactMap { $0 }
    }

    func requestWarm(_ name: String, start: Bool) {
        warmEpoch += 1
        guard start else { return }
        if warmingModel == name, warmTask != nil { return }
        warmTask?.cancel()
        warmingModel = name
        let streaming = streaming
        warmTask = Task(priority: .medium) { [weak self] in
            await streaming.warm(name)
            guard !Task.isCancelled else { return }
            self?.warmFinished(name)
        }
    }

    func warmStreaming(_ name: String) {
        requestWarm(name, start: true)
    }

    func warmFileSession(_ name: String) {
        guard let fileSession else { return }
        fileWarmGeneration += 1
        let generation = fileWarmGeneration
        let previous = fileWarmTask
        fileWarmTask = Task(priority: .medium) { [weak self] in
            await previous?.value
            guard self?.fileWarmGeneration == generation else { return }
            await fileSession.prewarm(modelName: name)
        }
    }

    func cancelWarm() {
        warmTask?.cancel()
        warmTask = nil
        warmingModel = nil
    }

    func awaitWarm() async {
        await warmTask?.value
    }

    func releaseStreamingModels(ifUnchangedSince epoch: Int) async {
        guard epoch == warmEpoch else { return }
        cancelWarm()
        await streaming.releaseIdleModels()
    }

    func residentModelNames() async -> [String] {
        var names = Set(await streaming.residentModelNames())
        for holder in holders {
            if let name = await holder.loadedModelName() { names.insert(name) }
        }
        return names.sorted()
    }

    func setStreamingIdleTimeout(_ timeout: Duration) async {
        await streaming.setIdleTimeout(timeout)
    }

    func free(_ name: String) async {
        if warmingModel == name { cancelWarm() }
        await streaming.evict(name)
        if let warm = fileWarmTask {
            _ = await AsyncTimeout.run(fileWarmWait) { await warm.value }
        }
        await unload(name, fromHolder: Self.fileHolder, mayBeRunning: activeFileRuns > 0)
        await unload(name, fromHolder: Self.dictationHolder, mayBeRunning: false)
    }

    func releaseDictationSession(ifUnchangedSince epoch: Int, configuredModel: String, mayBeRunning: Bool) async {
        guard epoch == warmEpoch, let holder = dictationSession?() ?? nil else { return }
        let loaded = await holder.loadedModelName()
        guard let name = loaded ?? (mayBeRunning ? configuredModel : nil) else { return }
        await unload(name, fromHolder: Self.dictationHolder, mayBeRunning: mayBeRunning)
    }

    func dictationArmed() {
        pendingUnloads[Self.dictationHolder] = nil
    }

    func sessionRunBegan() {
        activeFileRuns += 1
    }

    func sessionRunEnded() {
        activeFileRuns = max(0, activeFileRuns - 1)
        retryPendingUnloads()
    }

    func retryPendingUnloads() {
        guard !pendingUnloads.isEmpty else { return }
        let previous = retry
        retry = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for (index, names) in pendingUnloads {
                for name in names { await unload(name, fromHolder: index, mayBeRunning: false) }
            }
        }
    }

    private func warmFinished(_ name: String) {
        guard warmingModel == name else { return }
        warmTask = nil
        warmingModel = nil
    }

    private func unload(_ name: String, fromHolder index: Int, mayBeRunning: Bool) async {
        pendingUnloads[index]?.remove(name)
        let all = holders
        guard index < all.count else { return }
        let holder = all[index]
        await holder.unloadModel(ifLoaded: name)
        let stillLoaded = await holder.loadedModelName() == name
        if mayBeRunning || stillLoaded {
            pendingUnloads[index, default: []].insert(name)
        }
    }

#if DEBUG
    var isWarming: Bool { warmTask != nil }
    var activeRunCount: Int { activeFileRuns }
    var pendingUnloadCount: Int { pendingUnloads.values.reduce(0) { $0 + $1.count } }

    func awaitFileWarm() async {
        await fileWarmTask?.value
    }

    func awaitRetry() async {
        await retry?.value
    }
#endif
}
