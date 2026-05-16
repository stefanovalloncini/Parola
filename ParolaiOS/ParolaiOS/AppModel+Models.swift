import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func refreshModelList() {
        availableModels = ModelStore.shared.catalog()
        if !availableModels.contains(where: { $0.name == settings.modelName }) {
            settings.modelName = availableModels.first?.name ?? "openai_whisper-tiny"
        }
    }

    func deleteModel(_ name: String) {
        try? ModelStore.shared.delete(variant: name)
        refreshModelList()
    }
}
