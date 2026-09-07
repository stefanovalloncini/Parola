import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("ModelStore storage override")
struct ModelStorageLocationTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: temporarySuiteName("test-")))
    }

    private func missingFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-shared-missing-\(UUID().uuidString).txt")
    }

    @Test("uses default directory when no override is set")
    func usesDefault() throws {
        let defaults = try makeDefaults()
        let store = ModelStore(defaults: defaults, sharedOverrideFile: missingFile())
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
        let store = ModelStore(defaults: defaults, sharedOverrideFile: missingFile())
        #expect(store.directory.path == ModelStore.defaultDirectory.path)
    }

    @Test("shared override file applies when defaults have no override")
    func sharedFileApplies() throws {
        let defaults = try makeDefaults()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-shared-target-\(UUID().uuidString)", isDirectory: true)
        let file = missingFile()
        ModelStore.writeSharedOverride(target.path, to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: target)
        }
        let store = ModelStore(defaults: defaults, sharedOverrideFile: file)
        #expect(store.directory.path == target.path)
    }

    @Test("defaults override wins over the shared file")
    func defaultsBeatSharedFile() throws {
        let defaults = try makeDefaults()
        let fromDefaults = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-defaults-dir-\(UUID().uuidString)", isDirectory: true)
        let fromFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-file-dir-\(UUID().uuidString)", isDirectory: true)
        defaults.set(fromDefaults.path, forKey: ModelStore.storageOverrideKey)
        let file = missingFile()
        ModelStore.writeSharedOverride(fromFile.path, to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: fromDefaults)
            try? FileManager.default.removeItem(at: fromFile)
        }
        let store = ModelStore(defaults: defaults, sharedOverrideFile: file)
        #expect(store.directory.path == fromDefaults.path)
    }

    @Test("writeSharedOverride with nil removes the file")
    func nilOverrideRemovesFile() throws {
        let file = missingFile()
        ModelStore.writeSharedOverride("/tmp/somewhere", to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        ModelStore.writeSharedOverride(nil, to: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
