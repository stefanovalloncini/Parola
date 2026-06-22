import Foundation
import Testing
@testable import ParolaCore

@Suite("Bundled term packs")
struct BundledTermPacksTests {
    @Test("ships English and Italian tech-terms packs")
    func loadsBundled() throws {
        let en = try #require(BundledTermPacks.load("tech-terms-en"))
        #expect(en.locale == "en")
        #expect(en.rules.isEmpty == false)

        let it = try #require(BundledTermPacks.load("tech-terms-it"))
        #expect(it.locale == "it")
        #expect(it.rules.isEmpty == false)
    }

    @Test("all() returns every advertised identifier")
    func allMatchesIdentifiers() {
        let packs = BundledTermPacks.all()
        #expect(packs.count == BundledTermPacks.identifiers.count)
    }

    @Test("matching(locale:) filters by language code")
    func filtersByLocale() {
        let it = BundledTermPacks.matching(locale: Locale(identifier: "it_IT"))
        #expect(it.count == 1)
        #expect(it.first?.locale == "it")

        let de = BundledTermPacks.matching(locale: Locale(identifier: "de_DE"))
        #expect(de.isEmpty)
    }

    @Test("unknown identifier returns nil")
    func unknownIsNil() {
        #expect(BundledTermPacks.load("does-not-exist") == nil)
    }

    @Test("Italian pack fixes standalone terms without corrupting substrings")
    func italianMatchesWholeTermsOnly() throws {
        let pack = try #require(BundledTermPacks.load("tech-terms-it"))
        let rules = TermPackIO.merge(pack: pack, into: [])
        let seg = TranscriptSegment(
            id: 0, start: 0, end: 1,
            text: "Il sistema è rapido, devo capire e non urlare; uso la api e la url"
        )
        let out = GlobalFindReplace.apply(rules: rules, to: [seg])
        #expect(out.first?.text == "Il sistema è rapido, devo capire e non urlare; uso la API e la URL")
    }

    @Test("English pack fixes standalone terms without corrupting substrings")
    func englishMatchesWholeTermsOnly() throws {
        let pack = try #require(BundledTermPacks.load("tech-terms-en"))
        let rules = TermPackIO.merge(pack: pack, into: [])
        let seg = TranscriptSegment(
            id: 0, start: 0, end: 1,
            text: "the therapist visits studios to test the api on ios"
        )
        let out = GlobalFindReplace.apply(rules: rules, to: [seg])
        #expect(out.first?.text == "the therapist visits studios to test the API on iOS")
    }
}
