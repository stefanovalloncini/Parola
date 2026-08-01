import Foundation
import FluidAudio
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
        // Apple Speech is built into macOS and always reports installed.
        let appleSpeechIDs = Set(ModelCatalog.all.filter { $0.engineID == .appleSpeech }.map(\.id))
        #expect(entries.filter { !appleSpeechIDs.contains($0.name) }.allSatisfy { !$0.isInstalled })
        #expect(entries.filter { appleSpeechIDs.contains($0.name) }.allSatisfy { $0.isInstalled })

        let installedURL = store.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: installedURL, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: installedURL.appendingPathComponent("marker"))

        let entries2 = store.catalog()
        let tiny = entries2.first { $0.name == "openai_whisper-tiny" }
        #expect(tiny?.isInstalled == true)
        #expect(tiny?.installedURL?.path == installedURL.path)
    }

    @Test("a partial download (leftover sidecar) is reported not-installed by catalog, isInstalled, and installedModels")
    func partialDownloadNotReportedInstalled() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let url = store.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: url.appendingPathComponent("weights.bin"))
        try Data("{}".utf8).write(to: url.appendingPathComponent(HuggingFaceDownloader.sidecarFilename))

        let tiny = store.catalog().first { $0.name == "openai_whisper-tiny" }
        #expect(tiny?.isInstalled == false)
        #expect(tiny?.installedURL == nil)
        #expect(store.isInstalled("openai_whisper-tiny") == false)
        let installed = try store.installedModels()
        #expect(!installed.contains { $0.name == "openai_whisper-tiny" })
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

    @Test("Parakeet's install path is the directory FluidAudio writes, so install and delete agree")
    func parakeetInstallPathMatchesFluidAudio() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let installed = store.installedURL(for: "nvidia_parakeet-tdt-0.6b-v2")
        // AsrModels.download(to:) writes to parent-of-the-passed-directory + Repo.folderName.
        let fluidAudioTarget = installed
            .deletingLastPathComponent()
            .appendingPathComponent(Repo.parakeetV2.folderName, isDirectory: true)
        #expect(installed.standardizedFileURL == fluidAudioTarget.standardizedFileURL)

        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: installed.appendingPathComponent("Encoder.mlmodelc"))
        #expect(store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))

        try store.delete(variant: "nvidia_parakeet-tdt-0.6b-v2")
        #expect(!store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    @Test("a directory an engine downloader created but never filled is not reported as installed")
    func emptyInstallDirectoryIsNotInstalled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let url = store.installedURL(for: "openai_whisper-large-v3")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(store.isInstalled("openai_whisper-large-v3") == false)
        #expect(store.catalog().first { $0.name == "openai_whisper-large-v3" }?.isInstalled == false)
    }

    @Test("a model whose CoreML weights never landed is not reported as installed")
    func truncatedCompiledBundleIsNotInstalled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let url = store.installedURL(for: "openai_whisper-tiny")
        let bundle = url.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true)
        let weights = bundle.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("meta".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))

        #expect(store.isInstalled("openai_whisper-tiny") == false)

        try Data("w".utf8).write(to: weights.appendingPathComponent("weight.bin"))
        #expect(store.isInstalled("openai_whisper-tiny"))
    }

    @Test("a stale directory from an older layout is listed as an orphan the user can delete")
    func staleLayoutDirectoryIsListedAsOrphan() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let stale = tmp.appendingPathComponent(
            "models/FluidInference/parakeet-tdt-0.6b-v2-coreml", isDirectory: true
        )
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale.appendingPathComponent("Encoder.mlmodelc"))

        #expect(try store.installedModels().contains { $0.name == "parakeet-tdt-0.6b-v2-coreml" })
        try store.deleteAny(idOrPath: "parakeet-tdt-0.6b-v2-coreml")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("the diarizer models a service owns are never offered as deletable leftovers")
    func diarizerDirectoryIsNotAnOrphan() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let diarizer = IncrementalSpeakerLabeler.modelsDirectory(store: store)
        try FileManager.default.createDirectory(at: diarizer, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: diarizer.appendingPathComponent(ModelNames.Diarizer.segmentationFile))

        #expect(try store.installedModels().allSatisfy { $0.installedURL?.path != diarizer.path })
        #expect(throws: ParolaError.self) {
            try store.deleteAny(idOrPath: diarizer.lastPathComponent)
        }
        #expect(FileManager.default.fileExists(atPath: diarizer.path))
    }

    @Test("deleteAny refuses a name that would climb out of the model store")
    func deleteAnyRejectsPathTraversal() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let outside = tmp.appendingPathComponent("models/FluidInference", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        #expect(throws: ParolaError.self) { try store.deleteAny(idOrPath: "..") }
        #expect(throws: ParolaError.self) { try store.deleteAny(idOrPath: "../whisperkit-coreml") }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("a tokenizer-only directory (no model weights) is not reported as an installed model")
    func excludesTokenizerOnlyOrphan() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let tok = tmp.appendingPathComponent("models/openai/whisper-tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: tok, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            try Data("{}".utf8).write(to: tok.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: tok.appendingPathComponent(".cache"), withIntermediateDirectories: true)

        let installed = try store.installedModels()
        #expect(!installed.contains { $0.name == "whisper-tiny" })
    }

    @Test("a scan replayed from cache still matches a store that has never looked at the tree")
    func cachedScanMatchesFreshStore() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let warm = ModelStore(modelsDirectory: tmp)
        func fresh() -> ModelStore { ModelStore(modelsDirectory: tmp) }
        func expectAgreement() throws {
            let reference = fresh()
            #expect(warm.catalog() == reference.catalog())
            #expect(try warm.installedModels() == reference.installedModels())
        }

        #expect(warm.cachedScan() == nil)
        try expectAgreement()
        #expect(warm.cachedScan() != nil)

        let complete = warm.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: complete.appendingPathComponent("weights.bin"))
        try expectAgreement()

        let partial = warm.installedURL(for: "openai_whisper-base")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: partial.appendingPathComponent("weights.bin"))
        try Data("{}".utf8).write(to: partial.appendingPathComponent(HuggingFaceDownloader.sidecarFilename))
        try expectAgreement()

        let orphan = tmp.appendingPathComponent("models/FluidInference/leftover-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: orphan.appendingPathComponent("model.bin"))
        try expectAgreement()

        let tokenizerOnly = tmp.appendingPathComponent("models/openai/whisper-tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerOnly, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizerOnly.appendingPathComponent("config.json"))
        try expectAgreement()

        try FileManager.default.removeItem(at: partial.appendingPathComponent(HuggingFaceDownloader.sidecarFilename))
        try expectAgreement()
        #expect(warm.catalog().first { $0.name == "openai_whisper-base" }?.isInstalled == true)

        try FileManager.default.removeItem(at: complete)
        try expectAgreement()
        #expect(warm.catalog().first { $0.name == "openai_whisper-tiny" }?.isInstalled == false)
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
