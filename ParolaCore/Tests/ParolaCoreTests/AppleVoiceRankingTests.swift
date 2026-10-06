import Foundation
import Testing
@testable import ParolaCore

@Suite("Apple voice ranking")
struct AppleVoiceRankingTests {
    private func voice(
        _ identifier: String,
        name: String,
        language: String,
        quality: VoiceDescriptor.Quality = .default,
        isNovelty: Bool = false,
        isPersonal: Bool = false,
        family: VoiceDescriptor.Family = .standard
    ) -> VoiceDescriptor {
        VoiceDescriptor(
            identifier: identifier,
            name: name,
            language: language,
            quality: quality,
            isNovelty: isNovelty,
            isPersonal: isPersonal,
            family: family
        )
    }

    private var federica: VoiceDescriptor {
        voice("com.apple.voice.premium.it-IT.Federica", name: "Federica", language: "it-IT", quality: .premium)
    }

    private var alice: VoiceDescriptor {
        voice("com.apple.voice.compact.it-IT.Alice", name: "Alice", language: "it-IT", quality: .default)
    }

    private var eddy: VoiceDescriptor {
        voice("com.apple.eloquence.it-IT.Eddy", name: "Eddy", language: "it-IT", quality: .default, family: .eloquence)
    }

    private var flo: VoiceDescriptor {
        voice("com.apple.eloquence.it-IT.Flo", name: "Flo", language: "it-IT", quality: .default, family: .eloquence)
    }

    private var noveltyBells: VoiceDescriptor {
        voice("com.apple.speech.synthesis.voice.Bells", name: "Bells", language: "it-IT", isNovelty: true)
    }

    private var italianFixture: [VoiceDescriptor] { [alice, eddy, flo, federica, noveltyBells] }

    @Test("premium ranks first, then standard before Eloquence")
    func italianOrdering() {
        let ranked = AppleVoiceRanking.rank(italianFixture, forLanguage: "it", preferredRegions: [])
        #expect(ranked.map(\.name) == ["Federica", "Alice", "Eddy", "Flo"])
    }

    @Test("novelty voices are excluded")
    func noveltyExcluded() {
        let ranked = AppleVoiceRanking.rank(italianFixture, forLanguage: "it", preferredRegions: [])
        #expect(!ranked.contains { $0.name == "Bells" })
    }

    @Test("unusable identifiers are excluded")
    func unusableExcluded() {
        let ranked = AppleVoiceRanking.rank(
            italianFixture,
            forLanguage: "it",
            preferredRegions: [],
            unusable: [federica.identifier]
        )
        #expect(!ranked.contains { $0.name == "Federica" })
        #expect(ranked.first?.name == "Alice")
    }

    @Test("a preferred region ranks ahead of others at the same tier")
    func regionPreference() {
        let british = voice("com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB")
        let american = voice("com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US")
        let ranked = AppleVoiceRanking.rank([american, british], forLanguage: "en", preferredRegions: ["GB"])
        #expect(ranked.map(\.name) == ["Daniel", "Samantha"])
    }

    @Test("a multi-entry region preference is honoured in order")
    func multiEntryRegionPreferenceOrder() {
        let swiss = voice("com.apple.voice.compact.it-CH.Viola", name: "Viola", language: "it-CH")
        let italian = voice("com.apple.voice.compact.it-IT.Alice", name: "Alice", language: "it-IT")
        let chFirst = AppleVoiceRanking.rank([italian, swiss], forLanguage: "it", preferredRegions: ["CH", "IT"])
        #expect(chFirst.map(\.name) == ["Viola", "Alice"])
        let itFirst = AppleVoiceRanking.rank([swiss, italian], forLanguage: "it", preferredRegions: ["IT", "CH"])
        #expect(itFirst.map(\.name) == ["Alice", "Viola"])
    }

    @Test("best returns nil when the only match is a Personal voice")
    func bestIsNilWhenOnlyPersonalMatches() {
        let personal = voice("com.apple.voice.personal.it-IT.Aaron", name: "Aaron", language: "it-IT", isPersonal: true)
        #expect(AppleVoiceRanking.best([personal], forLanguage: "it", preferredRegions: []) == nil)
    }

    @Test("yue matches a zh-HK voice")
    func cantoneseMatchesZhHK() {
        let sinji = voice("com.apple.voice.compact.zh-HK.Sinji", name: "Sin-ji", language: "zh-HK")
        let ranked = AppleVoiceRanking.rank([sinji], forLanguage: "yue", preferredRegions: [])
        #expect(ranked.map(\.name) == ["Sin-ji"])
    }

    @Test("no match for the language gives an empty result")
    func noMatchIsEmpty() {
        let ranked = AppleVoiceRanking.rank(italianFixture, forLanguage: "de", preferredRegions: [])
        #expect(ranked.isEmpty)
    }

    @Test("best never returns a Personal voice")
    func bestSkipsPersonal() {
        let personal = voice("com.apple.voice.personal.it-IT.Aaron", name: "Aaron", language: "it-IT", isPersonal: true)
        let fixture = [personal, federica, alice]
        #expect(AppleVoiceRanking.best(fixture, forLanguage: "it", preferredRegions: [])?.name == "Federica")
    }

    @Test("rank keeps a Personal voice and ranks it with premium")
    func personalRankedWithPremium() {
        let personal = voice("com.apple.voice.personal.it-IT.Aaron", name: "Aaron", language: "it-IT", isPersonal: true)
        let ranked = AppleVoiceRanking.rank([alice, personal, federica], forLanguage: "it", preferredRegions: [])
        #expect(ranked.map(\.name) == ["Aaron", "Federica", "Alice"])
    }
}
