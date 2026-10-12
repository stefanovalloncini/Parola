import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func refreshModelList(listing: @escaping @Sendable () -> [ModelInfo] = { ModelStore.shared.listedCatalog() }) {
        modelListTask?.cancel()
        modelListTask = Task { [weak self] in
            let listed = await Task.detached(priority: .utility, operation: listing).value
            guard !Task.isCancelled else { return }
            self?.installModelList(listed)
        }
    }

    private func installModelList(_ listed: [ModelInfo]) {
        availableModels = listed
        if !availableModels.contains(where: { $0.name == settings.modelName }) {
            settings.modelName = UserSettings.defaultModelID()
        }
    }

    func deleteModel(_ name: String) {
        try? ModelStore.shared.deleteLeftovers(variant: name)
        try? ModelStore.shared.delete(variant: name)
        refreshModelList()
    }
}
