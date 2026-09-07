import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("Managed configuration (MDM)")
struct ManagedConfigurationTests {
    private func makeStorage(_ managed: [String: Any]) -> UserDefaults {
        let storage = temporaryDefaults("parola-mdm-test-")
        storage.set(managed, forKey: "com.apple.configuration.managed")
        return storage
    }

    @Test("no managed dict means everything is unset and isActive is false")
    func emptyManaged() {
        let storage = temporaryDefaults("parola-mdm-empty-")
        let config = ManagedConfiguration(storage: storage)
        #expect(config.isActive == false)
        #expect(config.defaultModel == nil)
        #expect(config.allowedEngines == nil)
        #expect(config.disableYouTubeIngestion == false)
        #expect(config.disableDictation == false)
        #expect(config.disableCloudLLM == false)
        #expect(config.disableModelDownloads == false)
        #expect(config.requireEnglishOnly == false)
    }

    @Test("defaultModel is read from managed dict")
    func defaultModelRead() {
        let storage = makeStorage(["defaultModel": "openai_whisper-large-v3"])
        let config = ManagedConfiguration(storage: storage)
        #expect(config.defaultModel == "openai_whisper-large-v3")
        #expect(config.isManaged(.defaultModel))
        #expect(config.isManaged(.disableYouTubeIngestion) == false)
    }

    @Test("allowedEngines parses array of strings into EngineIDs")
    func allowedEngines() {
        let storage = makeStorage(["allowedEngines": ["whisperkit", "parakeet"]])
        let config = ManagedConfiguration(storage: storage)
        let engines = config.allowedEngines
        #expect(engines?.count == 2)
        #expect(engines?.contains(.whisperKit) == true)
        #expect(engines?.contains(.parakeet) == true)
    }

    @Test("allowedEngines empty array means all engines blocked")
    func allowedEnginesEmpty() {
        let storage = makeStorage(["allowedEngines": [String]()])
        let config = ManagedConfiguration(storage: storage)
        #expect(config.allowedEngines == [])
        let filtered = config.filterAllowed(ModelCatalog.all)
        #expect(filtered.isEmpty)
    }

    @Test("boolean keys distinguish missing from false")
    func boolKeys() {
        let storage = makeStorage([
            "disableYouTubeIngestion": true,
            "disableDictation": false
        ])
        let config = ManagedConfiguration(storage: storage)
        #expect(config.disableYouTubeIngestion == true)
        #expect(config.disableDictation == false)
        #expect(config.isManaged(.disableDictation))
        #expect(config.disableModelDownloads == false)
        #expect(config.isManaged(.disableModelDownloads) == false)
    }

    @Test("disableCloudLLM reads user privacy mode through the injected storage")
    func privacyModeFromStorage() {
        let storage = temporaryDefaults("parola-mdm-privacy-")
        storage.set(true, forKey: ManagedConfiguration.userPrivacyModeKey)
        let config = ManagedConfiguration(storage: storage)
        #expect(config.disableCloudLLM == true)
    }

    @Test("filterAllowed restricts catalog by engine allowlist")
    func filterAllowed() {
        let storage = makeStorage(["allowedEngines": ["whisperkit"]])
        let config = ManagedConfiguration(storage: storage)
        let filtered = config.filterAllowed(ModelCatalog.all)
        #expect(filtered.allSatisfy { $0.engineID == .whisperKit })
        #expect(filtered.contains { $0.engineID == .whisperKit })
        #expect(filtered.contains { $0.engineID == .parakeet } == false)
    }

    @Test("filterAllowed is a no-op when no allowlist")
    func filterAllowedNoop() {
        let storage = temporaryDefaults("parola-mdm-noop-")
        let config = ManagedConfiguration(storage: storage)
        let filtered = config.filterAllowed(ModelCatalog.all)
        #expect(filtered.count == ModelCatalog.all.count)
    }

    @Test("isActive becomes true once any policy is pushed")
    func activeFlag() {
        let storage = makeStorage(["requireEnglishOnly": true])
        let config = ManagedConfiguration(storage: storage)
        #expect(config.isActive)
    }
}
