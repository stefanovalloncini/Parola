import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func refreshModelList() {
        availableModels = ModelStore.shared.listedCatalog()
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
