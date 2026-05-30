import Foundation
import SwiftUI
import Testing
@testable import Parola

@Suite("LanguageCatalog")
struct LanguageCatalogTests {
    @Test("label maps a known code to its localized key")
    func labelForKnownCode() {
        #expect(LanguageCatalog.label(for: "en") == LocalizedStringKey("language.en"))
        #expect(LanguageCatalog.label(for: "it") == LocalizedStringKey("language.it"))
        #expect(LanguageCatalog.label(for: "zh") == LocalizedStringKey("language.zh"))
        #expect(LanguageCatalog.label(for: "ko") == LocalizedStringKey("language.ko"))
    }

    @Test("label for nil is the auto key")
    func labelForNil() {
        #expect(LanguageCatalog.label(for: nil) == LanguageCatalog.auto.label)
    }

    @Test("label for an unrecognized code falls back to the unknown key")
    func labelForUnknownCode() {
        #expect(LanguageCatalog.label(for: "xx") == LocalizedStringKey("language.unknown"))
    }

    @Test("an empty query matches every option")
    func emptyQueryMatchesAll() {
        for option in LanguageCatalog.extended {
            #expect(LanguageCatalog.matches(option, query: ""))
        }
        #expect(LanguageCatalog.matches(LanguageCatalog.auto, query: ""))
    }

    @Test("a whitespace-only query is treated as empty and matches")
    func whitespaceQueryMatchesAll() throws {
        let english = try requireOption(code: "en")
        #expect(LanguageCatalog.matches(english, query: "   \n\t "))
    }

    @Test("matches by code is case-insensitive and trims surrounding whitespace")
    func matchesByCode() throws {
        let english = try requireOption(code: "en")
        #expect(LanguageCatalog.matches(english, query: "en"))
        #expect(LanguageCatalog.matches(english, query: "EN"))
        #expect(LanguageCatalog.matches(english, query: "  En  "))
    }

    @Test("a code query does not match a different option")
    func codeQueryIsSpecific() throws {
        let italian = try requireOption(code: "it")
        #expect(!LanguageCatalog.matches(italian, query: "en"))
    }

    @Test("matches by display name is case-insensitive")
    func matchesByName() throws {
        let german = try requireOption(code: "de")
        let name = LanguageCatalog.displayName(for: german)
        #expect(LanguageCatalog.matches(german, query: name))
        #expect(LanguageCatalog.matches(german, query: name.lowercased()))
        #expect(LanguageCatalog.matches(german, query: name.uppercased()))
    }

    @Test("the auto option has no code and matches only by its display name")
    func autoMatchesByName() {
        #expect(LanguageCatalog.auto.code == nil)
        let name = LanguageCatalog.displayName(for: LanguageCatalog.auto)
        #expect(LanguageCatalog.matches(LanguageCatalog.auto, query: name))
        #expect(!LanguageCatalog.matches(LanguageCatalog.auto, query: "zzzzz"))
    }

    private func requireOption(code: String) throws -> LanguageOption {
        try #require(LanguageCatalog.extended.first { $0.code == code })
    }
}
