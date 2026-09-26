import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("catalog includes Whisper Large v3 Turbo as a Recommended entry")
    func recommendedIsTurbo() {
        let recommended = ModelCatalog.all.filter { $0.category == .recommended }
        #expect(recommended.contains { $0.id == "openai_whisper-large-v3_turbo" })
    }

    @Test("the turbo entry points at the four-layer turbo checkpoint, not plain large-v3")
    func turboPointsAtTheRealTurboCheckpoint() throws {
        let turbo = try #require(ModelCatalog.variant(id: "openai_whisper-large-v3_turbo"))
        let largeV3 = try #require(ModelCatalog.variant(id: "openai_whisper-large-v3"))
        #expect(turbo.downloadSource.subpath == "openai_whisper-large-v3-v20240930")
        #expect(turbo.expectedDecoderLayers == 4)
        #expect(turbo.downloadSource.installDirectory != largeV3.downloadSource.installDirectory)
        #expect(largeV3.downloadSource.subpath == "openai_whisper-large-v3")
        #expect(largeV3.expectedDecoderLayers == nil)
    }

    @Test("the turbo id a stored selection holds still resolves after the folder move")
    func storedTurboSelectionStillResolves() {
        #expect(ModelCatalog.variant(id: "openai_whisper-large-v3_turbo")?.displayName == "Whisper Large v3 Turbo")
        #expect(ModelCatalog.variant(id: "openai_whisper-large-v3_turbo")?.downloadSource
            .supersededInstallDirectories == ["argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo"])
    }

    @Test("downloadName is the repo folder for Whisper and the catalog id for the rest")
    func downloadNameFollowsTheSource() throws {
        let turbo = try #require(ModelCatalog.variant(id: "openai_whisper-large-v3_turbo"))
        #expect(turbo.downloadSource.downloadName(defaultingTo: turbo.id) == "openai_whisper-large-v3-v20240930")
        let parakeet = try #require(ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v2"))
        #expect(parakeet.downloadSource.downloadName(defaultingTo: parakeet.id) == parakeet.id)
    }

    @Test("Parakeet TDT 0.6B v2 is in the Fastest category and English-only")
    func parakeetIsFastestEnglishOnly() {
        guard let parakeet = ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v2") else {
            Issue.record("Parakeet variant missing")
            return
        }
        #expect(parakeet.category == .fastest)
        #expect(parakeet.engineID == .parakeet)
        #expect(parakeet.languageScope == .only(["en"]))
        #expect(parakeet.speedTier == .fastest)
    }

    @Test("every variant ships either a recognized engine or a non-empty download source")
    func everyVariantWellFormed() {
        let known: Set<EngineID> = [.whisperKit, .parakeet, .appleSpeech]
        for variant in ModelCatalog.all {
            #expect(variant.displayName.isEmpty == false, "variant \(variant.id) has empty displayName")
            #expect(known.contains(variant.engineID), "variant \(variant.id) uses unknown engine \(variant.engineID)")
            if variant.engineID != .appleSpeech {
                #expect(variant.downloadSource.huggingFaceRepo.isEmpty == false, "variant \(variant.id) has empty repo")
            }
        }
    }

    @Test("variant ids are unique")
    func idsUnique() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("groupedForPicker pins Recommended first, then Fastest, then accuracy etc.")
    func groupingOrder() {
        let groups = ModelCatalog.groupedForPicker(isInstalled: { _ in false })
        #expect(groups.first?.0 == .recommended)
        let categoriesInOrder = groups.map(\.0)
        #expect(categoriesInOrder == categoriesInOrder.sorted { $0.sortOrder < $1.sortOrder })
    }

    @Test("groupedForPicker's Recommended group lists Turbo before Apple Speech, matching defaultModelID's catalogue order")
    func recommendedGroupOrderMatchesDefault() throws {
        let groups = ModelCatalog.groupedForPicker(isInstalled: { _ in false })
        let recommended = try #require(groups.first(where: { $0.0 == .recommended })?.1)
        #expect(recommended.map(\.id) == ["openai_whisper-large-v3_turbo", "apple-speech-analyzer"])
    }

    @Test("variants(for:) returns only matching engine")
    func variantsForEngine() {
        let parakeet = ModelCatalog.variants(for: .parakeet)
        #expect(parakeet.allSatisfy { $0.engineID == .parakeet })
        #expect(parakeet.count >= 1)

        let whisper = ModelCatalog.variants(for: .whisperKit)
        #expect(whisper.allSatisfy { $0.engineID == .whisperKit })
        #expect(whisper.count >= 5)
    }

    @Test("effectiveCapabilities tightens engine defaults with variant language scope")
    func effectiveCapsTightens() async {
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in
            fatalError("unused — this test only resolves capabilities")
        }
        guard let tinyEN = ModelCatalog.variant(id: "openai_whisper-tiny.en") else {
            Issue.record("variant missing"); return
        }
        let caps = await ModelCatalog.effectiveCapabilities(for: tinyEN, registry: registry)
        #expect(caps?.supportedLanguages.isEnglishOnly == true)
        #expect(caps?.supportsTranslate == false)
    }

    @Test("staticCapabilities returns nil for an unknown engine")
    func staticCapsUnknownEngineNil() {
        let phantom = ModelVariant(
            id: "phantom",
            displayName: "Phantom",
            tagline: "n/a",
            engineID: EngineID("unknown-future-engine"),
            sizeBytes: 0,
            downloadSource: ModelDownloadSource(huggingFaceRepo: "x/y", subpath: ""),
            category: .compact,
            speedTier: .balanced,
            qualityTier: .good
        )
        #expect(ModelCatalog.staticCapabilities(for: phantom) == nil)
    }

    @Test("staticCapabilities returns tightened defaults for known engines")
    func staticCapsKnown() {
        guard let parakeet = ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v2") else {
            Issue.record("variant missing"); return
        }
        let caps = ModelCatalog.staticCapabilities(for: parakeet)
        #expect(caps?.supportedLanguages.isEnglishOnly == true)
    }

    @Test("Parakeet v3 is the listed Fastest entry and speaks 25 languages including Italian")
    func parakeetV3IsFastestMultilingual() throws {
        let v3 = try #require(ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v3"))
        #expect(v3.category == .fastest)
        #expect(v3.engineID == .parakeet)
        #expect(v3.languageScope == .only(ParakeetLanguages.v3))
        #expect(ParakeetLanguages.v3.count == 25)
        #expect(ParakeetLanguages.v3.contains("it"))
        #expect(ParakeetLanguages.v3.contains("en"))
        #expect(v3.downloadSource.huggingFaceRepo == "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        #expect(v3.downloadSource.installDirectory == "FluidInference/parakeet-tdt-0.6b-v3")
        #expect(v3.badges.contains("Multilingual"))
    }

    @Test("Parakeet v2 stays resolvable but is listed only when installed")
    func parakeetV2HiddenUnlessInstalled() throws {
        #expect(ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v2") != nil)
        let notInstalled = ModelCatalog.listedVariants(isInstalled: { _ in false }).map(\.id)
        #expect(!notInstalled.contains("nvidia_parakeet-tdt-0.6b-v2"))
        #expect(notInstalled.contains("nvidia_parakeet-tdt-0.6b-v3"))
        let installed = ModelCatalog.listedVariants(isInstalled: { $0 == "nvidia_parakeet-tdt-0.6b-v2" }).map(\.id)
        #expect(installed.contains("nvidia_parakeet-tdt-0.6b-v2"))
    }
}

@Suite("Model catalog lookup")
struct ModelCatalogLookupTests {
    private func makeConfig(_ managed: [String: Any]) -> ManagedConfiguration {
        let storage = temporaryDefaults("parola-catalog-test-")
        storage.set(managed, forKey: "com.apple.configuration.managed")
        return ManagedConfiguration(storage: storage)
    }

    @Test("closestMatch resolves the bare Parakeet alias")
    func closestMatchParakeetAlias() {
        #expect(ModelCatalog.closestMatch(for: "parakeet-tdt-0.6b-v2")?.id == "nvidia_parakeet-tdt-0.6b-v2")
    }

    @Test("closestMatch resolves a missing openai_ prefix")
    func closestMatchMissingPrefix() {
        #expect(ModelCatalog.closestMatch(for: "whisper-tiny")?.id == "openai_whisper-tiny")
    }

    @Test("closestMatch prefers the suffix match over a containing id")
    func closestMatchPrefersSuffix() {
        #expect(ModelCatalog.closestMatch(for: "whisper-large-v3")?.id == "openai_whisper-large-v3")
    }

    @Test("closestMatch stays quiet for plausible out-of-catalog variants")
    func closestMatchOutOfCatalog() {
        #expect(ModelCatalog.closestMatch(for: "openai_whisper-medium") == nil)
        #expect(ModelCatalog.closestMatch(for: "xyz") == nil)
    }

    @Test("defaultModelID honors a valid managed default")
    func defaultHonorsManaged() {
        let config = makeConfig(["defaultModel": "openai_whisper-large-v3"])
        #expect(ModelCatalog.defaultModelID(configuration: config) == "openai_whisper-large-v3")
    }

    @Test("defaultModelID ignores an unknown managed default")
    func defaultIgnoresUnknownManaged() {
        let config = makeConfig(["defaultModel": "not-a-model"])
        let id = ModelCatalog.defaultModelID(configuration: config, isInstalled: { _ in false })
        #expect(ModelCatalog.variant(id: id)?.category == .recommended)
    }

    @Test("defaultModelID prefers Turbo over Apple Speech when both are installed")
    func defaultPrefersInstalledTurbo() {
        let id = ModelCatalog.defaultModelID(isInstalled: { _ in true })
        #expect(id == "openai_whisper-large-v3_turbo")
    }

    @Test("defaultModelID falls back to Apple Speech when nothing recommended is installed")
    func defaultFallsBackToAppleSpeechWhenNothingInstalled() {
        let id = ModelCatalog.defaultModelID(isInstalled: { _ in false })
        #expect(id == "apple-speech-analyzer")
    }

    @Test("defaultModelID skips an installed model the allowlist excludes")
    func defaultSkipsDisallowedInstalledModel() {
        let config = makeConfig(["allowedEngines": ["apple-speech"]])
        let id = ModelCatalog.defaultModelID(configuration: config, isInstalled: { _ in true })
        #expect(id == "apple-speech-analyzer")
    }

    @Test("defaultModelID respects the engine allowlist")
    func defaultRespectsAllowlist() {
        let config = makeConfig(["allowedEngines": ["whisperkit"]])
        let id = ModelCatalog.defaultModelID(configuration: config, isInstalled: { _ in false })
        #expect(id == "openai_whisper-large-v3_turbo")
    }

    @Test("defaultModelID(for:) falls back to Whisper when the default can't honor the request")
    func optionsAwareDefaultFallsBack() {
        guard ModelCatalog.variant(id: "apple-speech-analyzer") != nil else { return }
        let config = makeConfig(["defaultModel": "apple-speech-analyzer"])
        #expect(ModelCatalog.defaultModelID(
            for: TranscriptionOptions(task: .translate), configuration: config
        ) == ModelCatalog.fallbackModelID)
        #expect(ModelCatalog.defaultModelID(
            for: TranscriptionOptions(diarize: true), configuration: config
        ) == ModelCatalog.fallbackModelID)
        #expect(ModelCatalog.defaultModelID(
            for: TranscriptionOptions(), configuration: config
        ) == "apple-speech-analyzer")
    }

    @Test("groupedForPicker filters by the engine allowlist")
    func groupedForPickerFilters() {
        let config = makeConfig(["allowedEngines": ["parakeet"]])
        let groups = ModelCatalog.groupedForPicker(configuration: config, isInstalled: { _ in false })
        let ids = groups.flatMap { $0.1.map(\.id) }
        #expect(ids == ["nvidia_parakeet-tdt-0.6b-v3"])
    }

    @Test("only Whisper streams, and an id outside the catalog is a legacy Whisper directory that does")
    func canStreamFollowsTheEngine() throws {
        let apple = try #require(ModelCatalog.all.first { $0.engineID == .appleSpeech })
        #expect(ModelCatalog.canStream(id: "openai_whisper-tiny"))
        #expect(ModelCatalog.canStream(id: "openai_whisper-large-v3_turbo"))
        #expect(!ModelCatalog.canStream(id: apple.id))
        #expect(!ModelCatalog.canStream(id: "nvidia_parakeet-tdt-0.6b-v3"))
        #expect(ModelCatalog.canStream(id: "openai_whisper-custom-finetune"))
    }
}
