import Foundation
import Testing
@testable import Parola

@Suite("LanguageDisplay name")
struct LanguageDisplayTests {
    @Test("localizes a real language code")
    func localizesRealCode() {
        #expect(LanguageDisplay.name(for: "en") == "English")
        #expect(LanguageDisplay.name(for: "it") == "Italian")
    }

    @Test("is case-insensitive for the code")
    func caseInsensitiveCode() {
        #expect(LanguageDisplay.name(for: "IT") == "Italian")
    }

    @Test("treats the unknown sentinel as no language")
    func unknownIsNoLanguage() {
        #expect(LanguageDisplay.name(for: "unknown") == nil)
        #expect(LanguageDisplay.name(for: "UNKNOWN") == nil)
        #expect(LanguageDisplay.name(for: "  unknown  ") == nil)
    }

    @Test("treats empty, whitespace, and nil as no language")
    func blankIsNoLanguage() {
        #expect(LanguageDisplay.name(for: "") == nil)
        #expect(LanguageDisplay.name(for: "   ") == nil)
        #expect(LanguageDisplay.name(for: nil) == nil)
    }

    @Test("falls back to the uppercased code when unrecognized")
    func unrecognizedFallsBackToCode() {
        #expect(LanguageDisplay.name(for: "xx") == "XX")
    }
}

@Suite("LanguageDisplay code")
struct LanguageDisplayCodeTests {
    @Test("uppercases a real language code")
    func uppercasesRealCode() {
        #expect(LanguageDisplay.code(for: "it") == "IT")
        #expect(LanguageDisplay.code(for: "en") == "EN")
    }

    @Test("keeps a regioned code uppercased")
    func regionedCode() {
        #expect(LanguageDisplay.code(for: "en-US") == "EN-US")
    }

    @Test("is case-insensitive for the code")
    func caseInsensitiveCode() {
        #expect(LanguageDisplay.code(for: "It") == "IT")
        #expect(LanguageDisplay.code(for: " it ") == "IT")
    }

    @Test("treats the unknown sentinel as no badge")
    func unknownIsNoBadge() {
        #expect(LanguageDisplay.code(for: "unknown") == nil)
        #expect(LanguageDisplay.code(for: "UNKNOWN") == nil)
        #expect(LanguageDisplay.code(for: "  unknown  ") == nil)
    }

    @Test("treats empty, whitespace, and nil as no badge")
    func blankIsNoBadge() {
        #expect(LanguageDisplay.code(for: "") == nil)
        #expect(LanguageDisplay.code(for: "   ") == nil)
        #expect(LanguageDisplay.code(for: nil) == nil)
    }
}
