import Testing
@testable import Parola
import ParolaCore

@Suite("Introduction engine card")
struct EngineCardRecommendationTests {
    @Test("the chip marks the recommended Whisper, not Apple Speech")
    func recommendation() throws {
        let turbo = try #require(ModelCatalog.variant(id: "openai_whisper-large-v3_turbo"))
        #expect(EngineScene.isRecommended(turbo))

        let apple = try #require(ModelCatalog.all.first { $0.engineID == .appleSpeech })
        #expect(apple.category == .recommended)
        #expect(!EngineScene.isRecommended(apple))
    }

    @Test("a variant the catalog files elsewhere gets no chip")
    func otherCategories() throws {
        let parakeet = try #require(ModelCatalog.variant(id: "nvidia_parakeet-tdt-0.6b-v2"))
        #expect(!EngineScene.isRecommended(parakeet))
    }
}
