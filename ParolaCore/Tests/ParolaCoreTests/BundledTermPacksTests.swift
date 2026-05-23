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
}
