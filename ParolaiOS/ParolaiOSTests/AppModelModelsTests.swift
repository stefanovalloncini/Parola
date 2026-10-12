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
    func mirrorsListedCatalog() async throws {
        let model = try makeModel()
        model.refreshModelList()
        await model.modelListTask?.value
        #expect(model.availableModels.isEmpty == false)
        #expect(model.availableModels == ModelStore.shared.listedCatalog())
        #expect(
            !model.availableModels.contains { $0.name == "nvidia_parakeet-tdt-0.6b-v2" && !$0.isInstalled },
            "the earlier Parakeet is offered only once installed"
        )
    }

    @Test("an unknown selected model falls back to the default")
    func coercesUnknownSelection() async throws {
        let model = try makeModel()
        model.settings.modelName = "not-a-real-model"
        model.refreshModelList()
        await model.modelListTask?.value
        #expect(model.availableModels.contains { $0.name == model.settings.modelName })
        #expect(model.settings.modelName == UserSettings.defaultModelID())
    }

    @Test("a selected model that exists in the catalog is left unchanged")
    func keepsKnownSelection() async throws {
        let model = try makeModel()
        let known = try #require(ModelStore.shared.catalog().first?.name)
        model.settings.modelName = known
        model.refreshModelList()
        await model.modelListTask?.value
        #expect(model.settings.modelName == known)
    }

    @Test("a refresh superseded by a newer one never installs its list")
    func supersededRefreshDropped() async throws {
        let model = try makeModel()
        let full = ModelStore.shared.listedCatalog()
        let stale = Array(full.prefix(1))
        try #require(stale != full)
        model.refreshModelList {
            Thread.sleep(forTimeInterval: 0.1)
            return stale
        }
        model.refreshModelList { full }
        await model.modelListTask?.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.availableModels == full)
    }
}
