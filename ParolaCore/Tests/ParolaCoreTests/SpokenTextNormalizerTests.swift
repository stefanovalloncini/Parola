import Foundation
import Testing
@testable import ParolaCore

/// `NumberFormatter.spellOut` inserts U+00AD (soft hyphen) between the components of a composite
/// Italian number ("mille\u{AD}due\u{AD}cento\u{AD}cinquanta") and spells a decimal's fraction digit
/// by digit ("uno virgola due cinque", not "uno virgola venticinque"); both are pinned here as
/// produced by macOS 27.2 / Swift 6.4, not hand-written.
@Suite("Spoken text normalizer")
struct SpokenTextNormalizerTests {
    // MARK: - Integers and decimals

    @Test("EN integer with a thousands separator spells out the value")
    func englishInteger() {
        #expect(SpokenTextNormalizer.normalize("1,250", language: "en") == "one thousand two hundred fifty")
    }

    @Test("EN decimal spells the fraction digit by digit")
    func englishDecimal() {
        #expect(SpokenTextNormalizer.normalize("3.5", language: "en") == "three point five")
    }

    @Test("IT integer with a thousands separator spells out the value, soft-hyphenated")
    func italianInteger() {
        #expect(SpokenTextNormalizer.normalize("1.250", language: "it") == "mille\u{AD}due\u{AD}cento\u{AD}cinquanta")
    }

    @Test("IT decimal spells the fraction digit by digit")
    func italianDecimal() {
        #expect(SpokenTextNormalizer.normalize("3,5", language: "it") == "tre virgola cinque")
    }

    @Test("EN decimal with a trailing zero drops it, digit by digit")
    func englishDecimalTrailingZero() {
        #expect(SpokenTextNormalizer.normalize("1.250", language: "en") == "one point two five")
    }

    @Test("IT decimal reads each fraction digit on its own, not the combined value")
    func italianDecimalDigitByDigit() {
        #expect(SpokenTextNormalizer.normalize("1,250", language: "it") == "uno virgola due cinque")
    }

    // MARK: - Years

    @Test("EN year splits into two two-digit groups")
    func englishYear() {
        #expect(SpokenTextNormalizer.normalize("2026", language: "en") == "twenty twenty-six")
    }

    @Test("IT year reads as the plain spelled-out number")
    func italianYear() {
        #expect(SpokenTextNormalizer.normalize("2026", language: "it") == "due\u{AD}mila\u{AD}venti\u{AD}sei")
    }

    // MARK: - Times

    @Test("EN half past the hour reads as hour then minute")
    func englishTimeHalfPast() {
        #expect(SpokenTextNormalizer.normalize("10:30", language: "en") == "ten thirty")
    }

    @Test("EN single-digit minute reads with oh")
    func englishTimeOhFive() {
        #expect(SpokenTextNormalizer.normalize("9:05", language: "en") == "nine oh five")
    }

    @Test("EN on-the-hour reads as hour hundred")
    func englishTimeOnTheHour() {
        #expect(SpokenTextNormalizer.normalize("14:00", language: "en") == "fourteen hundred")
    }

    @Test("IT half past the hour reads as hour e minute")
    func italianTimeHalfPast() {
        #expect(SpokenTextNormalizer.normalize("10:30", language: "it") == "dieci e trenta")
    }

    @Test("IT single-digit minute reads with e")
    func italianTimeOhFive() {
        #expect(SpokenTextNormalizer.normalize("9:05", language: "it") == "nove e cinque")
    }

    @Test("IT on-the-hour reads as just the hour")
    func italianTimeOnTheHour() {
        #expect(SpokenTextNormalizer.normalize("14:00", language: "it") == "quattordici")
    }

    // MARK: - Dates

    @Test("EN month then day reads the day as an ordinal")
    func englishDateMonthDay() {
        #expect(SpokenTextNormalizer.normalize("March 15", language: "en") == "March fifteenth")
    }

    @Test("EN day then month reorders to month then ordinal day")
    func englishDateDayMonth() {
        #expect(SpokenTextNormalizer.normalize("15 March", language: "en") == "March fifteenth")
    }

    @Test("IT day then month reads the day as a cardinal")
    func italianDateDayMonth() {
        #expect(SpokenTextNormalizer.normalize("15 marzo", language: "it") == "quindici marzo")
    }

    // MARK: - Percent

    @Test("EN percent spells the number and says percent")
    func englishPercent() {
        #expect(SpokenTextNormalizer.normalize("25%", language: "en") == "twenty-five percent")
    }

    @Test("IT percent spells the number and says per cento")
    func italianPercent() {
        #expect(SpokenTextNormalizer.normalize("25%", language: "it") == "venti\u{AD}cinque per cento")
    }

    // MARK: - Currency

    @Test("EN dollar sign spells the amount and says dollars")
    func englishCurrencySymbol() {
        #expect(SpokenTextNormalizer.normalize("$1,250", language: "en") == "one thousand two hundred fifty dollars")
    }

    @Test("EN number followed by the word dollars spells the amount")
    func englishCurrencyWord() {
        #expect(SpokenTextNormalizer.normalize("1,250 dollars", language: "en") == "one thousand two hundred fifty dollars")
    }

    @Test("IT euro sign spells the amount and says euro")
    func italianCurrencySymbol() {
        #expect(SpokenTextNormalizer.normalize("€1.250", language: "it") == "mille\u{AD}due\u{AD}cento\u{AD}cinquanta euro")
    }

    @Test("IT number followed by the word euro spells the amount")
    func italianCurrencyWord() {
        #expect(SpokenTextNormalizer.normalize("1.250 euro", language: "it") == "mille\u{AD}due\u{AD}cento\u{AD}cinquanta euro")
    }

    // MARK: - Abbreviations

    @Test("EN Dr. expands to Doctor")
    func englishAbbreviationDoctor() {
        #expect(SpokenTextNormalizer.normalize("Dr. Smith is here.", language: "en") == "Doctor Smith is here.")
    }

    @Test("EN e.g. expands to for example")
    func englishAbbreviationEg() {
        #expect(SpokenTextNormalizer.normalize("fruit, e.g. apples", language: "en") == "fruit, for example apples")
    }

    @Test("IT Sig. expands to Signor")
    func italianAbbreviationSignor() {
        #expect(SpokenTextNormalizer.normalize("Il Sig. Rossi è arrivato.", language: "it") == "Il Signor Rossi è arrivato.")
    }

    @Test("IT Sig.ra is not truncated by the Sig. rule")
    func italianAbbreviationSignora() {
        #expect(SpokenTextNormalizer.normalize("La Sig.ra Bianchi", language: "it") == "La Signora Bianchi")
    }

    // MARK: - Stripping

    @Test("text with no numbers is returned unchanged")
    func noNumbersUnchanged() {
        #expect(SpokenTextNormalizer.normalize("Hello there, how are you?", language: "en") == "Hello there, how are you?")
    }

    @Test("a URL-only string becomes empty")
    func urlOnlyBecomesEmpty() {
        #expect(SpokenTextNormalizer.normalize("https://example.com/path", language: "en") == "")
    }

    @Test("a bracketed non-speech marker alone becomes empty")
    func bracketedAloneBecomesEmpty() {
        #expect(SpokenTextNormalizer.normalize("[Music]", language: "en") == "")
    }

    @Test("an emoji is stripped and whitespace collapses")
    func emojiIsStripped() {
        #expect(SpokenTextNormalizer.normalize("Great news! 🎉 Let's go.", language: "en") == "Great news! Let's go.")
    }

    @Test("a parenthetical non-speech marker is stripped")
    func parentheticalKnownMarkerStripped() {
        #expect(SpokenTextNormalizer.normalize("He said hello (laughs) to everyone.", language: "en") == "He said hello to everyone.")
    }

    @Test("a parenthetical that isn't a known marker is kept")
    func parentheticalUnknownKept() {
        #expect(SpokenTextNormalizer.normalize("The result (final) was good.", language: "en") == "The result (final) was good.")
    }

    // MARK: - Mixed

    @Test("a mixed IT sentence normalizes times, currency and percent, keeping unlisted parentheses")
    func mixedItalianSentence() {
        let input = "Alle 10:30 ho pagato 1.250 euro (25%)."
        let expected = "Alle dieci e trenta ho pagato mille\u{AD}due\u{AD}cento\u{AD}cinquanta euro (venti\u{AD}cinque per cento)."
        #expect(SpokenTextNormalizer.normalize(input, language: "it") == expected)
    }

    // MARK: - Other languages

    @Test("a language other than EN/IT only strips and spells out plain integers")
    func otherLanguagePlainIntegerOnly() {
        #expect(SpokenTextNormalizer.normalize("J'ai 25 ans.", language: "fr") == "J'ai vingt-cinq ans.")
    }

    @Test("a language other than EN/IT leaves a decimal untouched")
    func otherLanguageLeavesDecimalAlone() {
        #expect(SpokenTextNormalizer.normalize("Le prix est 3,5 euros.", language: "fr") == "Le prix est 3,5 euros.")
    }
}
