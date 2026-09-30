import Foundation
import FluidAudio
import Testing
@testable import ParolaCore
import ParolaTestSupport

private final class NameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func record(_ name: String) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return names
    }
}

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

    @Test("catalog reports isMultilingual by language scope, not by whether one is set")
    func catalogIsMultilingualByScope() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let entries = store.catalog()
        #expect(entries.first { $0.name == "nvidia_parakeet-tdt-0.6b-v3" }?.isMultilingual == true)
        #expect(entries.first { $0.name == "nvidia_parakeet-tdt-0.6b-v2" }?.isMultilingual == false)
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

    @Test("the Parakeet copy from before installDirectory is an earlier download, and clearing it spares the live one")
    func preInstallDirectoryParakeetCopyIsAnEarlierDownload() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let stale = tmp.appendingPathComponent(
            "models/FluidInference/parakeet-tdt-0.6b-v2-coreml", isDirectory: true
        )
        let live = store.installedURL(for: "nvidia_parakeet-tdt-0.6b-v2")
        for folder in [stale, live] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("Encoder.mlmodelc"))
        }

        #expect(try !store.installedModels().contains { $0.name == "parakeet-tdt-0.6b-v2-coreml" })
        let leftovers = store.supersededInstalls()
        #expect(leftovers.map(\.variantID) == ["nvidia_parakeet-tdt-0.6b-v2"])
        #expect(leftovers.first?.displayName == "Parakeet TDT 0.6B v2")
        #expect(leftovers.first?.url.standardizedFileURL == stale.standardizedFileURL)

        try store.deleteLeftovers(variant: "nvidia_parakeet-tdt-0.6b-v2")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))
        #expect(store.supersededInstalls().isEmpty)
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

    @Test("a managed allowlist change invalidates a scan the stamps say is current")
    func cachedScanFollowsManagedAllowlist() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storage = temporaryDefaults("parola-scan-cache-")
        let warm = ModelStore(modelsDirectory: tmp, managedConfiguration: ManagedConfiguration(storage: storage))
        let unrestricted = warm.catalog()
        #expect(unrestricted.contains { $0.name == "openai_whisper-tiny" })
        #expect(warm.cachedScan() != nil)

        storage.set(["allowedEngines": ["parakeet"]], forKey: "com.apple.configuration.managed")
        #expect(warm.cachedScan() == nil)
        let restricted = warm.catalog()
        #expect(restricted.contains { $0.name == "openai_whisper-tiny" } == false)
        #expect(restricted.count < unrestricted.count)
        #expect(warm.catalog() == restricted)
    }

    @Test("weights left in the folder the turbo entry used to install into never read as installed")
    func supersededTurboFolderIsNotInstalled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let old = tmp.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo", isDirectory: true
        )
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: old.appendingPathComponent("TextDecoder.mlmodelc"))

        #expect(store.isInstalled("openai_whisper-large-v3_turbo") == false)
        #expect(store.catalog().first { $0.name == "openai_whisper-large-v3_turbo" }?.isInstalled == false)
        #expect(try !store.installedModels().contains { $0.name == "openai_whisper-large-v3_turbo" })

        let leftovers = store.supersededInstalls()
        #expect(leftovers.count == 1)
        #expect(leftovers.first?.variantID == "openai_whisper-large-v3_turbo")
        #expect(leftovers.first?.displayName == "Whisper Large v3 Turbo")
        #expect(leftovers.first?.url.standardizedFileURL == old.standardizedFileURL)
    }

    @Test("deleting the turbo entry leaves the folder an earlier release installed it into")
    func deleteKeepsSupersededCopy() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let old = tmp.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo", isDirectory: true
        )
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: old.appendingPathComponent("TextDecoder.mlmodelc"))
        let current = store.installedURL(for: "openai_whisper-large-v3_turbo")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: current.appendingPathComponent("TextDecoder.mlmodelc"))

        try store.deleteAny(idOrPath: "openai_whisper-large-v3_turbo")
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(store.supersededInstalls().count == 1)
    }

    @Test("deleteLeftovers clears the old copy and leaves the current install alone")
    func deleteLeftoversSparesTheCurrentInstall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let old = tmp.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo", isDirectory: true
        )
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: old.appendingPathComponent("TextDecoder.mlmodelc"))
        let current = store.installedURL(for: "openai_whisper-large-v3_turbo")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: current.appendingPathComponent("TextDecoder.mlmodelc"))

        try store.deleteLeftovers(variant: "openai_whisper-large-v3_turbo")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(store.isInstalled("openai_whisper-large-v3_turbo"))
        #expect(store.supersededInstalls().isEmpty)
    }

    @Test("the old copy alone is not enough for delete to succeed")
    func deleteNeedsTheCurrentInstall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let old = tmp.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo", isDirectory: true
        )
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: old.appendingPathComponent("TextDecoder.mlmodelc"))

        #expect(throws: ParolaError.self) { try store.delete(variant: "openai_whisper-large-v3_turbo") }
        #expect(FileManager.default.fileExists(atPath: old.path))

        try store.deleteLeftovers(variant: "openai_whisper-large-v3_turbo")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(throws: ParolaError.self) { try store.deleteLeftovers(variant: "openai_whisper-large-v3_turbo") }
    }

    @Test("deleteLeftovers on a variant that never moved folders throws instead of touching it")
    func deleteLeftoversThrowsForAVariantThatNeverMoved() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let current = store.installedURL(for: "openai_whisper-tiny")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: current.appendingPathComponent("TextDecoder.mlmodelc"))

        #expect(throws: ParolaError.self) { try store.deleteLeftovers(variant: "openai_whisper-tiny") }
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    @Test("every earlier-download folder the catalog names is offered, and none of them is a live install")
    func supersededFoldersAreDisjointFromLiveInstalls() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let models = tmp.appendingPathComponent("models", isDirectory: true)
        let supersededDirectories = ModelCatalog.all.flatMap(\.downloadSource.supersededInstallDirectories)
        let liveURLs = ModelCatalog.all.map { store.installedURL(for: $0.id) }
        for folder in supersededDirectories.map({ models.appendingPathComponent($0, isDirectory: true) }) + liveURLs {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("w".utf8).write(to: folder.appendingPathComponent("weights.bin"))
        }

        let offered = Set(store.supersededInstalls().map(\.url.standardizedFileURL.path))
        #expect(!supersededDirectories.isEmpty)
        #expect(offered.count == supersededDirectories.count)
        #expect(offered.isDisjoint(with: liveURLs.map(\.standardizedFileURL.path)))
    }

    @Test(
        "a folder that is, holds or sits inside a live install is never offered as an earlier download",
        arguments: [
            ("FluidInference/synthetic-coreml", false),
            ("fluidinference/Synthetic-CoreML", false),
            ("FluidInference", false),
            ("FluidInference/synthetic-coreml/Encoder.mlmodelc", false),
            ("FluidInference/synthetic-old", true),
        ]
    )
    func supersededFolderOverlappingTheLiveOneIsNotOffered(superseded: String, liveLinksToIt: Bool) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let synthetic = ModelVariant(
            id: "synthetic-parakeet",
            displayName: "Synthetic Parakeet",
            tagline: "",
            engineID: .parakeet,
            sizeBytes: 1,
            downloadSource: ModelDownloadSource(
                huggingFaceRepo: "FluidInference/synthetic-coreml",
                subpath: "",
                installDirectory: "FluidInference/synthetic-coreml",
                supersededInstallDirectories: [superseded]
            ),
            category: .fastest,
            speedTier: .fastest,
            qualityTier: .good
        )
        let store = ModelStore(modelsDirectory: tmp)
        let live = store.installedURL(for: synthetic.downloadSource)
        if liveLinksToIt {
            let target = tmp.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(superseded, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: live, withDestinationURL: target)
        }
        let encoder = live.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: encoder.appendingPathComponent("weights.bin"))

        #expect(store.supersededInstalls(among: [synthetic]).isEmpty)
        #expect(throws: ParolaError.self) {
            try store.deleteLeftovers(variant: synthetic.id, among: [synthetic])
        }
        #expect(FileManager.default.fileExists(atPath: encoder.appendingPathComponent("weights.bin").path))
    }

    @Test("a checkpoint whose config disagrees with the catalog reads as needing a download")
    func mismatchedCheckpointIsNotInstalled() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let url = store.installedURL(for: "openai_whisper-large-v3_turbo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: url.appendingPathComponent("TextDecoder.mlmodelc"))
        let config = url.appendingPathComponent("config.json")

        try Data(#"{"decoder_layers": 32}"#.utf8).write(to: config)
        #expect(store.isInstalled("openai_whisper-large-v3_turbo") == false)

        try Data(#"{"decoder_layers": 4}"#.utf8).write(to: config)
        #expect(store.isInstalled("openai_whisper-large-v3_turbo"))

        try Data("not json".utf8).write(to: config)
        #expect(store.isInstalled("openai_whisper-large-v3_turbo"))

        try FileManager.default.removeItem(at: config)
        #expect(store.isInstalled("openai_whisper-large-v3_turbo"))
    }

    @Test("the engine downloader is handed the repo folder, and the download lands where the catalog says")
    func downloaderReceivesTheRepoFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let probe = NameProbe()
        let registry = EngineRegistry()
        let destination = store.installedURL(for: "openai_whisper-large-v3_turbo")
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { _ in fatalError("factory unused") },
            downloader: { name, _, _ in
                probe.record(name)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("w".utf8).write(to: destination.appendingPathComponent("TextDecoder.mlmodelc"))
                return destination
            }
        )

        let url = try await store.download(variant: "openai_whisper-large-v3_turbo", registry: registry)
        #expect(probe.recorded == ["openai_whisper-large-v3-v20240930"])
        #expect(url.standardizedFileURL == destination.standardizedFileURL)
        #expect(destination.lastPathComponent == "openai_whisper-large-v3-v20240930")
        #expect(store.isInstalled("openai_whisper-large-v3_turbo"))
    }

    @Test("an engine that resolves its own directory still gets the catalog id")
    func downloaderWithoutASubpathGetsTheCatalogID() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let probe = NameProbe()
        let registry = EngineRegistry()
        await registry.register(
            engineID: .parakeet,
            capabilities: .parakeetDefaults,
            factory: { _ in fatalError("factory unused") },
            downloader: { name, store, _ in
                probe.record(name)
                let destination = store.installedURL(for: name)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("w".utf8).write(to: destination.appendingPathComponent("Encoder.mlmodelc"))
                return destination
            }
        )

        _ = try await store.download(variant: "nvidia_parakeet-tdt-0.6b-v2", registry: registry)
        #expect(probe.recorded == ["nvidia_parakeet-tdt-0.6b-v2"])
        #expect(store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))
    }

    @Test("plain Whisper Large v3 stays a separate entry the turbo move doesn't touch")
    func largeV3IsUnaffectedByTheTurboMove() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ModelStore(modelsDirectory: tmp)
        let url = store.installedURL(for: "openai_whisper-large-v3")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: url.appendingPathComponent("TextDecoder.mlmodelc"))
        try Data(#"{"decoder_layers": 32}"#.utf8).write(to: url.appendingPathComponent("config.json"))

        #expect(store.isInstalled("openai_whisper-large-v3"))
        #expect(store.isInstalled("openai_whisper-large-v3_turbo") == false)
        #expect(store.supersededInstalls().isEmpty)
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
