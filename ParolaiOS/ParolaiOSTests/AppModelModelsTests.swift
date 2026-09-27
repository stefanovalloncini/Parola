import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("AppModel model list")
@MainActor
struct AppModelModelsTests {
    private func makeModel() throws -> AppModel {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-appmodel-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AppModel(libraryURL: tmp, defaults: defaults)
    }

    @Test("refreshModelList mirrors the catalog as every picker lists it")
    func mirrorsListedCatalog() throws {
        let model = try makeModel()
        model.refreshModelList()
        #expect(model.availableModels.isEmpty == false)
        #expect(model.availableModels == ModelStore.shared.listedCatalog())
        #expect(
            !model.availableModels.contains { $0.name == "nvidia_parakeet-tdt-0.6b-v2" && !$0.isInstalled },
            "the earlier Parakeet is offered only once installed"
        )
    }

    @Test("an unknown selected model falls back to the default")
    func coercesUnknownSelection() throws {
        let model = try makeModel()
        model.settings.modelName = "not-a-real-model"
        model.refreshModelList()
        #expect(model.availableModels.contains { $0.name == model.settings.modelName })
        #expect(model.settings.modelName == UserSettings.defaultModelID())
    }

    @Test("a selected model that exists in the catalog is left unchanged")
    func keepsKnownSelection() throws {
        let model = try makeModel()
        let known = try #require(ModelStore.shared.catalog().first?.name)
        model.settings.modelName = known
        model.refreshModelList()
        #expect(model.settings.modelName == known)
    }
}
