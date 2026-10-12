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
    private var fileSession: (any LoadedModelHolder)?
    private var holders: [any LoadedModelHolder] = []
    private var fileWarmTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private(set) var warmingModel: String?
    private var pendingUnloads: Set<String> = []
    private var retry: Task<Void, Never>?

    init(streaming: any StreamingModelResidency) {
        self.streaming = streaming
    }

    func attach(fileSession: any LoadedModelHolder, dictationSession: any LoadedModelHolder) {
        self.fileSession = fileSession
        holders = [fileSession, dictationSession]
    }

    var isWarming: Bool { warmTask != nil }

    func warmStreaming(_ name: String) {
        if warmingModel == name, warmTask != nil { return }
        warmTask?.cancel()
        warmingModel = name
        let streaming = streaming
        warmTask = Task { [weak self] in
            await streaming.warm(name)
            guard !Task.isCancelled else { return }
            self?.warmFinished(name)
        }
    }

    func warmFileSession(_ name: String) {
        guard let fileSession else { return }
        let previous = fileWarmTask
        fileWarmTask = Task {
            await previous?.value
            await fileSession.prewarm(modelName: name)
        }
    }

    func awaitFileWarm() async {
        await fileWarmTask?.value
    }

    func cancelWarm() {
        warmTask?.cancel()
        warmTask = nil
        warmingModel = nil
    }

    func awaitWarm() async {
        await warmTask?.value
    }

    func releaseStreamingModels() async {
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
        await fileWarmTask?.value
        await unloadFromHolders(name)
    }

    func sessionRunEnded() {
        guard !pendingUnloads.isEmpty else { return }
        let previous = retry
        retry = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for name in Array(pendingUnloads) { await unloadFromHolders(name) }
        }
    }

    func awaitRetry() async {
        await retry?.value
    }

    private func warmFinished(_ name: String) {
        guard warmingModel == name else { return }
        warmTask = nil
        warmingModel = nil
    }

    private func unloadFromHolders(_ name: String) async {
        pendingUnloads.remove(name)
        for holder in holders {
            await holder.unloadModel(ifLoaded: name)
            if await holder.loadedModelName() == name { pendingUnloads.insert(name) }
        }
    }
}

extension AppModel {
    func modelPickerAppeared() {
        refreshModelList()
    }

    func pickModel(_ id: String, isInstalled: Bool, download: (String) -> Void) {
        // Activate first: a refused or failing download corrects the selection against this pick.
        activateModel(id)
        if isInstalled {
            prewarmSelectedModel()
        } else {
            download(id)
        }
    }
}
