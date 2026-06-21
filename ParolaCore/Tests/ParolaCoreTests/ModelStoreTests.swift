import Foundation
import Testing
@testable import ParolaCore

@Suite("ModelStore")
struct ModelStoreTests {
    @Test("catalog returns curated entries with isInstalled reflecting disk state")
    func catalogReflectsDisk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let entries = store.catalog()
        #expect(entries.contains { $0.name == "openai_whisper-tiny" })
        #expect(entries.allSatisfy { !$0.isInstalled })

        let installedURL = store.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: installedURL, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: installedURL.appendingPathComponent("marker"))

        let entries2 = store.catalog()
        let tiny = entries2.first { $0.name == "openai_whisper-tiny" }
        #expect(tiny?.isInstalled == true)
        #expect(tiny?.installedURL?.path == installedURL.path)
    }

    @Test("installedModels picks up directories not in the curated catalog")
    func installedModelsCustom() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let custom = store.installedURL(for: "custom-model-v9")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: custom.appendingPathComponent("weights.bin"))

        let installed = try store.installedModels()
        #expect(installed.contains { $0.name == "custom-model-v9" })
    }

    @Test("the de-suffixed FluidAudio twin of the catalog Parakeet is not reported as an orphan")
    func suppressesFluidInferenceTwin() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let twin = tmp.appendingPathComponent("models/FluidInference/parakeet-tdt-0.6b-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: twin, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: twin.appendingPathComponent("model.bin"))

        let installed = try store.installedModels()
        #expect(!installed.contains { $0.name == "parakeet-tdt-0.6b-v2" })
    }

    @Test("an unrelated FluidInference directory is still reported as installed")
    func keepsUnrelatedFluidInferenceDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let other = tmp.appendingPathComponent("models/FluidInference/some-other-model", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("model.bin"))

        let installed = try store.installedModels()
        #expect(installed.contains { $0.name == "some-other-model" })
    }
}
