import Foundation
import Testing
@testable import ParolaCore

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("catalog includes Whisper Large v3 Turbo as the Recommended entry")
    func recommendedIsTurbo() {
        let recommended = ModelCatalog.all.filter { $0.category == .recommended }
        #expect(recommended.contains { $0.id == "openai_whisper-large-v3_turbo" })
        #expect(recommended.count == 1)
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
        for variant in ModelCatalog.all {
            #expect(!variant.downloadSource.huggingFaceRepo.isEmpty, "variant \(variant.id) has empty repo")
            #expect(!variant.displayName.isEmpty, "variant \(variant.id) has empty displayName")
            #expect([EngineID.whisperKit, .parakeet].contains(variant.engineID), "variant \(variant.id) uses unknown engine \(variant.engineID)")
        }
    }

    @Test("variant ids are unique")
    func idsUnique() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("groupedForPicker pins Recommended first, then Fastest, then accuracy etc.")
    func groupingOrder() {
        let groups = ModelCatalog.groupedForPicker()
        #expect(groups.first?.0 == .recommended)
        let categoriesInOrder = groups.map(\.0)
        #expect(categoriesInOrder == categoriesInOrder.sorted { $0.sortOrder < $1.sortOrder })
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
            // Stub: we don't actually instantiate WhisperKit here; this test only resolves capabilities.
            fatalError("not called")
        }
        guard let tinyEN = ModelCatalog.variant(id: "openai_whisper-tiny.en") else {
            Issue.record("variant missing"); return
        }
        let caps = await ModelCatalog.effectiveCapabilities(for: tinyEN, registry: registry)
        #expect(caps?.supportedLanguages.isEnglishOnly == true)
        #expect(caps?.supportsTranslate == false)
    }
}
