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
