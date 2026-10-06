import Foundation
import ParolaCore

/// Weights an earlier release installed for a model that now lives in another folder.
struct SupersededCopy: Identifiable, Equatable, Sendable {
    let variantID: String
    let displayName: String
    let url: URL
    let bytes: Int64

    /// A path, so it never collides with a model name in `modelsBeingDeleted`.
    var id: String { url.path }
}

struct ModelsDiskSummary: Equatable, Sendable {
    /// Catalog models with files on disk: Apple Speech owns none, and other folders aren't models.
    let count: Int
    /// Everything the Models pane lists, earlier downloads included, so it matches Finder.
    let bytes: Int64
    let earlierBytes: Int64

    var usageText: String {
        let models = AppFormat.byteSize(bytes - earlierBytes)
        guard earlierBytes > 0 else { return models }
        return models + " · " + String(localized: "Earlier downloads: \(AppFormat.byteSize(earlierBytes))")
    }
}

extension AppModel {

    /// The Models pane and About both read this, so the two never disagree.
    var modelsOnDiskSummary: ModelsDiskSummary {
        Self.modelsDiskSummary(models: availableModels, sizes: modelSizes, earlier: supersededCopies)
    }

    nonisolated static func modelsDiskSummary(
        models: [ModelInfo],
        sizes: [String: Int64],
        earlier: [SupersededCopy]
    ) -> ModelsDiskSummary {
        let onDisk = models.filter { $0.isInstalled && $0.installedURL != nil }
        let listedBytes = onDisk.reduce(Int64(0)) { total, info in
            total + (sizes[info.name] ?? info.approximateSizeBytes.map(Int64.init) ?? 0)
        }
        let earlierBytes = earlier.reduce(Int64(0)) { $0 + $1.bytes }
        return ModelsDiskSummary(
            count: selectableModels(onDisk).count,
            bytes: listedBytes + earlierBytes,
            earlierBytes: earlierBytes
        )
    }

    /// Chained like the model scan, so a slow walk that started first never lands over a newer list.
    func refreshSupersededCopies(in store: ModelStore = .shared) {
        let previous = supersededCopiesTask
        supersededCopiesTask = Task { [weak self] in
            _ = await previous?.value
            guard let copies = try? await AppModel.offMainIO(qos: .utility, {
                AppModel.supersededCopies(in: store)
            }) else { return }
            self?.supersededCopies = copies
        }
    }

    func awaitSupersededCopiesRefresh() async {
        while let task = supersededCopiesTask {
            await task.value
            if supersededCopiesTask == task { supersededCopiesTask = nil }
        }
    }

    /// Walks every copy's tree, so it runs off the main thread.
    nonisolated static func supersededCopies(in store: ModelStore) -> [SupersededCopy] {
        store.supersededInstalls().map { install in
            SupersededCopy(
                variantID: install.variantID,
                displayName: install.displayName,
                url: install.url,
                bytes: Int64(store.sizeOnDisk(at: install.url) ?? 0)
            )
        }
    }

    func earlierCopies(of variantID: String) -> [SupersededCopy] {
        supersededCopies.filter { $0.variantID == variantID }
    }

    /// Deleting the model itself removes its earlier copies too.
    func isReclaiming(_ copy: SupersededCopy) -> Bool {
        modelsBeingDeleted.contains(copy.id) || modelsBeingDeleted.contains(copy.variantID)
    }

    /// Clearing an earlier copy touches the model's folders too, so the model reads as busy meanwhile.
    func isDeletingModel(_ name: String) -> Bool {
        modelsBeingDeleted.contains(name) || earlierCopies(of: name).contains { modelsBeingDeleted.contains($0.id) }
    }

    @discardableResult
    func reclaimSupersededCopy(_ variantID: String, in store: ModelStore = .shared) -> Task<Void, Never>? {
        let copies = earlierCopies(of: variantID)
        guard let first = copies.first, !copies.contains(where: isReclaiming) else { return nil }
        let keys = Set(copies.map(\.id))
        modelsBeingDeleted.formUnion(keys)
        return Task { [weak self] in
            let failure: (any Error)?
            do {
                try await AppModel.offMainIO { try store.deleteLeftovers(variant: variantID) }
                failure = nil
            } catch ParolaError.modelNotFound {
                // Already gone: a model delete or the CLI cleared it first.
                failure = nil
            } catch {
                failure = error
            }
            guard let self else { return }
            self.modelsBeingDeleted.subtract(keys)
            if let failure {
                self.modelActionError = String(
                    localized: "Could not delete \(first.displayName): \(failure.localizedDescription)"
                )
            } else {
                self.supersededCopies.removeAll { $0.variantID == variantID }
            }
            self.refreshModelList()
        }
    }

    /// A folder the user picked may be one another WhisperKit app downloads into as well.
    var modelStoreIsRelocated: Bool {
        ModelStore.shared.directory.standardizedFileURL.path
            != ModelStore.defaultDirectory.standardizedFileURL.path
    }
}
