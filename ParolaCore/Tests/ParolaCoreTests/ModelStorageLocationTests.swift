import Foundation
import Testing
@testable import ParolaCore

@Suite("ModelStore storage override")
struct ModelStorageLocationTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("uses default directory when no override is set")
    func usesDefault() throws {
        let defaults = try makeDefaults()
        let store = ModelStore(defaults: defaults)
        #expect(store.directory.path == ModelStore.defaultDirectory.path)
    }

    @Test("reads override from UserDefaults")
    func readsOverride() throws {
        let defaults = try makeDefaults()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-models-override-\(UUID().uuidString)", isDirectory: true)
        defaults.set(temp.path, forKey: ModelStore.storageOverrideKey)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = ModelStore(defaults: defaults)
        #expect(store.directory.path == temp.path)
    }

    @Test("explicit init argument wins over override")
    func explicitWins() throws {
        let defaults = try makeDefaults()
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-override-\(UUID().uuidString)", isDirectory: true)
        defaults.set(override.path, forKey: ModelStore.storageOverrideKey)
        defer { try? FileManager.default.removeItem(at: override) }
        let explicit = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-explicit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: explicit) }
        let store = ModelStore(modelsDirectory: explicit, defaults: defaults)
        #expect(store.directory.path == explicit.path)
    }

    @Test("blank override falls back to default")
    func blankOverride() throws {
        let defaults = try makeDefaults()
        defaults.set("   ", forKey: ModelStore.storageOverrideKey)
        let store = ModelStore(defaults: defaults)
        #expect(store.directory.path == ModelStore.defaultDirectory.path)
    }
}
