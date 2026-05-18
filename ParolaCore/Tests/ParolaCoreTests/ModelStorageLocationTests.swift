import Foundation
import Testing
@testable import ParolaCore

@Suite("ModelStore storage override", .serialized)
struct ModelStorageLocationTests {
    @Test("uses default directory when no override is set")
    func usesDefault() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ModelStore.storageOverrideKey)
        let store = ModelStore()
        #expect(store.directory.path == ModelStore.defaultDirectory.path)
    }

    @Test("reads override from UserDefaults")
    func readsOverride() throws {
        let defaults = UserDefaults.standard
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-models-override-\(UUID().uuidString)", isDirectory: true)
        defaults.set(temp.path, forKey: ModelStore.storageOverrideKey)
        defer {
            defaults.removeObject(forKey: ModelStore.storageOverrideKey)
            try? FileManager.default.removeItem(at: temp)
        }
        let store = ModelStore()
        #expect(store.directory.path == temp.path)
    }

    @Test("explicit init argument wins over override")
    func explicitWins() throws {
        let defaults = UserDefaults.standard
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-override-\(UUID().uuidString)", isDirectory: true)
        defaults.set(override.path, forKey: ModelStore.storageOverrideKey)
        defer {
            defaults.removeObject(forKey: ModelStore.storageOverrideKey)
            try? FileManager.default.removeItem(at: override)
        }
        let explicit = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-explicit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: explicit) }
        let store = ModelStore(modelsDirectory: explicit)
        #expect(store.directory.path == explicit.path)
    }

    @Test("blank override falls back to default")
    func blankOverride() {
        let defaults = UserDefaults.standard
        defaults.set("   ", forKey: ModelStore.storageOverrideKey)
        defer { defaults.removeObject(forKey: ModelStore.storageOverrideKey) }
        let store = ModelStore()
        #expect(store.directory.path == ModelStore.defaultDirectory.path)
    }
}
