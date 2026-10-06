import Foundation
import Testing
@testable import ParolaCore

/// `NumberFormatter.spellOut` spells a decimal's fraction digit by digit ("uno virgola due cinque",
/// not "uno virgola venticinque"); pinned here as produced by macOS 27.2 / Swift 6.4, not hand-written.
/// It also inserts U+00AD (soft hyphen) between the components of a composite Italian number, which
/// the normalizer strips (see the "no Cf character" tests below), so the pinned strings here never
/// contain one.
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

    @Test("IT integer with a thousands separator spells out the value")
    func italianInteger() {
        #expect(SpokenTextNormalizer.normalize("1.250", language: "it") == "milleduecentocinquanta")
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
        #expect(SpokenTextNormalizer.normalize("2026", language: "it") == "duemilaventisei")
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
        #expect(SpokenTextNormalizer.normalize("25%", language: "it") == "venticinque per cento")
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
        #expect(SpokenTextNormalizer.normalize("€1.250", language: "it") == "milleduecentocinquanta euro")
    }

    @Test("IT number followed by the word euro spells the amount")
    func italianCurrencyWord() {
        #expect(SpokenTextNormalizer.normalize("1.250 euro", language: "it") == "milleduecentocinquanta euro")
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
        let expected = "Alle dieci e trenta ho pagato milleduecentocinquanta euro (venticinque per cento)."
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

    // MARK: - C1: no leaked format characters (adversarial — failed on the original code)

    @Test("IT year spelling leaks no soft hyphen")
    func italianYearHasNoSoftHyphen() {
        let result = SpokenTextNormalizer.normalize("2026", language: "it")
        #expect(!result.unicodeScalars.contains(Unicode.Scalar(0x00AD)!))
        #expect(result == "duemilaventisei")
    }

    @Test("no normalized output contains a Unicode format (Cf) character")
    func noOutputContainsFormatCharacters() {
        let samples: [(String, String)] = [
            ("1.250 euro", "it"), ("2026", "it"), ("25%", "it"), ("€1.250", "it"),
            ("10:30", "it"), ("21 euro", "it"), ("42", "de"), ("1,250", "en"),
            ("2026", "en"), ("Alle 10:30 ho pagato 1.250 euro (25%).", "it"),
        ]
        for (input, language) in samples {
            let result = SpokenTextNormalizer.normalize(input, language: language)
            let hasFormatCharacter = result.unicodeScalars.contains { $0.properties.generalCategory == .format }
            #expect(!hasFormatCharacter, "leaked a format character for \"\(input)\" (\(language)): \(Array(result.unicodeScalars))")
        }
    }

    // MARK: - C2: phone numbers and IDs read digit by digit (adversarial)

    @Test("an IT phone number with a country code reads digit by digit, grouped with pauses")
    func italianPhoneNumberDigitByDigit() {
        let expected = "tre nove, tre tre tre, uno due tre quattro cinque sei sette"
        #expect(SpokenTextNormalizer.normalize("+39 333 1234567", language: "it") == expected)
    }

    @Test("an EN phone number with a country code reads digit by digit, grouped with pauses")
    func englishPhoneNumberDigitByDigit() {
        let expected = "one, five five five, one two three four five six seven"
        #expect(SpokenTextNormalizer.normalize("+1 555 1234567", language: "en") == expected)
    }

    @Test("a space-separated digit run with no plus sign still reads digit by digit past the threshold")
    func digitGroupsWithoutPlusStillDigitByDigit() {
        let expected = "three three three, one two three four five six seven"
        #expect(SpokenTextNormalizer.normalize("333 1234567", language: "en") == expected)
    }

    @Test("a glued 7+ digit run with NO separator is a quantity and reads as a cardinal, never digit by digit")
    func gluedLongIntegerReadsAsCardinal() {
        let expected = "one million two hundred thirty-four thousand five hundred sixty-seven"
        #expect(SpokenTextNormalizer.normalize("1234567", language: "en") == expected)
    }

    // MARK: - I1: negative numbers (adversarial)

    @Test("EN a leading minus sign on a bare number reads minus")
    func englishNegativeNumber() {
        #expect(SpokenTextNormalizer.normalize("It is -5 degrees.", language: "en") == "It is minus five degrees.")
    }

    @Test("IT a leading minus sign on a bare number reads meno")
    func italianNegativeNumber() {
        #expect(SpokenTextNormalizer.normalize("-5", language: "it") == "meno cinque")
    }

    // MARK: - I2: version strings (adversarial)

    @Test("EN a version string with two dots spells every segment, losing none")
    func englishVersionString() {
        #expect(SpokenTextNormalizer.normalize("2.0.1", language: "en") == "two point zero point one")
    }

    @Test("IT a version string with two dots spells every segment with punto")
    func italianVersionString() {
        #expect(SpokenTextNormalizer.normalize("2.0.1", language: "it") == "due punto zero punto uno")
    }

    // MARK: - I3: times outside hh:mm (adversarial)

    @Test("EN 24:00 is a valid time and reads as hour hundred")
    func englishTimeTwentyFourHundred() {
        #expect(SpokenTextNormalizer.normalize("24:00", language: "en") == "twenty-four hundred")
    }

    @Test("IT 24:00 is a valid time and reads as just the hour")
    func italianTimeTwentyFourHundred() {
        #expect(SpokenTextNormalizer.normalize("24:00", language: "it") == "ventiquattro")
    }

    @Test("EN an invalid time shape spells both numbers with a space, never a literal colon")
    func englishInvalidTimeDeclinesCleanly() {
        let result = SpokenTextNormalizer.normalize("7:5", language: "en")
        #expect(result == "seven five")
        #expect(!result.contains(":"))
    }

    // MARK: - I4: Italian "un" elision (adversarial)

    @Test("IT one euro by symbol elides to un euro")
    func italianOneEuroSymbolElides() {
        #expect(SpokenTextNormalizer.normalize("€1", language: "it") == "un euro")
    }

    @Test("IT one euro by word elides to un euro")
    func italianOneEuroWordElides() {
        #expect(SpokenTextNormalizer.normalize("1 euro", language: "it") == "un euro")
    }

    @Test("IT twenty-one euro keeps NumberFormatter's own ventuno, not vent'un")
    func italianTwentyOneEuroKeepsCardinalForm() {
        #expect(SpokenTextNormalizer.normalize("21 euro", language: "it") == "ventuno euro")
    }

    @Test("IT one minuto elides to un minuto")
    func italianOneMinuteElides() {
        #expect(SpokenTextNormalizer.normalize("1 minuto", language: "it") == "un minuto")
    }

    // MARK: - I5: Italian day-of-month = 1 (adversarial)

    @Test("IT the first of the month reads as primo, not uno")
    func italianFirstOfMonth() {
        #expect(SpokenTextNormalizer.normalize("1 marzo", language: "it") == "primo marzo")
    }

    @Test("IT the first of the month with a degree sign also reads as primo")
    func italianFirstOfMonthWithDegreeSign() {
        #expect(SpokenTextNormalizer.normalize("1° marzo", language: "it") == "primo marzo")
    }

    // MARK: - I6: URL wrapper punctuation (adversarial)

    @Test("a URL wrapped in parentheses is removed with its wrapper, leaving no stray punctuation")
    func urlWrappedInParenthesesRemovedWithWrapper() {
        #expect(SpokenTextNormalizer.normalize("(https://example.com/foo)", language: "en") == "")
    }

    @Test("a URL's trailing sentence punctuation survives stripping")
    func urlTrailingPunctuationSurvives() {
        let result = SpokenTextNormalizer.normalize("Check this out https://example.com/foo.", language: "en")
        #expect(result.hasSuffix("."))
        #expect(!result.contains("example.com"))
    }

    // MARK: - M1: glued tokens stay unchanged (regression)

    @Test("a glued hyphenated token like COVID-19 is left untouched")
    func gluedHyphenatedTokenUnchanged() {
        #expect(SpokenTextNormalizer.normalize("COVID-19", language: "en") == "COVID-19")
    }

    @Test("an ordinal glued to its number like 3rd is left untouched")
    func gluedOrdinalUnchanged() {
        #expect(SpokenTextNormalizer.normalize("3rd place", language: "en") == "3rd place")
    }

    // MARK: - M2: number ranges (adversarial)

    @Test("EN a short dash range reads as number to number")
    func englishRange() {
        #expect(SpokenTextNormalizer.normalize("10-12", language: "en") == "ten to twelve")
    }

    @Test("IT a short dash range reads as number a number")
    func italianRange() {
        #expect(SpokenTextNormalizer.normalize("10-12", language: "it") == "dieci a dodici")
    }

    // MARK: - M3: keycap emoji (adversarial)

    @Test("a digit keycap emoji is stripped, not left as a stray symbol")
    func keycapEmojiStripped() {
        let keycap = "\u{31}\u{FE0F}\u{20E3}"
        #expect(SpokenTextNormalizer.normalize("Press \(keycap) to confirm.", language: "en") == "Press to confirm.")
    }

    // MARK: - A: a time range never leaks a literal colon (fix round 2, adversarial)

    @Test("EN a dash-joined time range reads as a time range, dropping hundred on the bare-hour end")
    func englishTimeRange() {
        #expect(SpokenTextNormalizer.normalize("10:30-11:00", language: "en") == "ten thirty to eleven")
    }

    @Test("IT a dash-joined time range reads as a time range")
    func italianTimeRange() {
        #expect(SpokenTextNormalizer.normalize("10:30-11:00", language: "it") == "dieci e trenta a undici")
    }

    @Test("EN a time range inside a sentence never leaves a literal colon behind")
    func englishTimeRangeInSentence() {
        let result = SpokenTextNormalizer.normalize("Meeting from 10:30-11:00 tomorrow.", language: "en")
        #expect(result == "Meeting from ten thirty to eleven tomorrow.")
        #expect(!result.contains(":"))
    }

    // MARK: - B: a plain quantity with no separator is a cardinal, never digit by digit (fix round 2, adversarial)

    @Test("IT a 7-digit quantity with no thousands separator reads as a cardinal, not digit by digit")
    func italianLargeQuantityReadsAsCardinal() {
        let expected = "nel duemilaventisei erano un milione cinquecentomila persone"
        #expect(SpokenTextNormalizer.normalize("nel 2026 erano 1500000 persone", language: "it") == expected)
    }

    @Test("EN a 7-digit quantity with no thousands separator reads as a cardinal, not digit by digit")
    func englishLargeQuantityReadsAsCardinal() {
        let expected = "The year nineteen ninety-nine had one million people."
        #expect(SpokenTextNormalizer.normalize("The year 1999 had 1000000 people.", language: "en") == expected)
    }

    // MARK: - C: a currency symbol glued to a separator-free 7+ digit amount never leaks the symbol (fix round 2, adversarial)

    @Test("EN a dollar sign glued to a 7-digit amount spells the whole amount, not a stranded symbol")
    func englishCurrencySymbolLongAmount() {
        let expected = "one million two hundred thirty-four thousand five hundred sixty-seven dollars"
        #expect(SpokenTextNormalizer.normalize("$1234567", language: "en") == expected)
    }

    @Test("IT a euro sign glued to a 7-digit amount spells the whole amount, not a stranded symbol")
    func italianCurrencySymbolLongAmount() {
        let expected = "un milione duecentotrentaquattromilacinquecentosessantasette euro"
        #expect(SpokenTextNormalizer.normalize("€1234567", language: "it") == expected)
    }

    // MARK: - D: a negative separator-free 7+ digit number still reads minus (fix round 2, adversarial)

    @Test("EN a bare negative 7-digit number reads minus, not a stranded dash")
    func englishNegativeLongNumber() {
        let expected = "minus one million two hundred thirty-four thousand five hundred sixty-seven"
        #expect(SpokenTextNormalizer.normalize("-1234567", language: "en") == expected)
    }

    @Test("EN a negative 7-digit number followed by more words still reads minus")
    func englishNegativeLongNumberInSentence() {
        let expected = "It lost minus one million two hundred thirty-four thousand five hundred sixty-seven dollars."
        #expect(SpokenTextNormalizer.normalize("It lost -1234567 dollars.", language: "en") == expected)
    }

    // MARK: - E: I1 and I4 compose (fix round 2, adversarial)

    @Test("IT a negative one euro amount elides to meno un euro, not meno uno euro")
    func italianNegativeOneEuroElides() {
        #expect(SpokenTextNormalizer.normalize("-1 euro", language: "it") == "meno un euro")
    }

    // MARK: - ISO dates (fix round 2, adversarial)

    @Test("EN an ISO date with a valid month and day reads as a spoken date")
    func englishISODate() {
        #expect(SpokenTextNormalizer.normalize("2026-10-06", language: "en") == "October sixth, twenty twenty-six")
    }

    @Test("IT an ISO date with a valid month and day reads as a spoken date")
    func italianISODate() {
        #expect(SpokenTextNormalizer.normalize("2026-10-06", language: "it") == "sei ottobre duemilaventisei")
    }

    @Test("IT an ISO date on the first of the month reads primo, not uno")
    func italianISODateFirstOfMonth() {
        #expect(SpokenTextNormalizer.normalize("2026-10-01", language: "it") == "primo ottobre duemilaventisei")
    }

    @Test("EN an ISO-shaped date with an invalid month falls through unchanged")
    func englishInvalidISODateUnchanged() {
        #expect(SpokenTextNormalizer.normalize("2026-13-06", language: "en") == "2026-13-06")
    }

    // MARK: - F: negative "uno" only elides before a masculine noun (fix round 3, adversarial)

    @Test("IT a standalone negative one keeps the plain cardinal uno, not un")
    func italianNegativeOneStandaloneStaysUno() {
        #expect(SpokenTextNormalizer.normalize("-1", language: "it") == "meno uno")
    }

    @Test("IT a negative one before an unrelated word keeps uno, not un")
    func italianNegativeOneBeforeAdverbStaysUno() {
        let expected = "La temperatura è meno uno oggi."
        #expect(SpokenTextNormalizer.normalize("La temperatura è -1 oggi.", language: "it") == expected)
    }

    @Test("IT a negative one before a feminine noun keeps uno, same as the positive form today")
    func italianNegativeOneBeforeFeminineNounStaysUno() {
        #expect(SpokenTextNormalizer.normalize("-1 mela", language: "it") == "meno uno mela")
    }

    @Test("IT a negative one before a masculine noun from the I4 list still elides to un")
    func italianNegativeOneBeforeMasculineNounStillElides() {
        #expect(SpokenTextNormalizer.normalize("-1 euro", language: "it") == "meno un euro")
    }

    // MARK: - Mixed range with one bare-hour endpoint (fix round 3, cheap)

    @Test("EN a range with only the first side spelled as hh:mm reads the bare side on the hour")
    func englishMixedTimeRangeBareSecondEndpoint() {
        #expect(SpokenTextNormalizer.normalize("10:30-11", language: "en") == "ten thirty to eleven")
    }

    @Test("IT a range with only the first side spelled as hh:mm reads the bare side on the hour")
    func italianMixedTimeRangeBareSecondEndpoint() {
        #expect(SpokenTextNormalizer.normalize("10:30-11", language: "it") == "dieci e trenta a undici")
    }

    @Test("EN a range with only the second side spelled as hh:mm reads the bare side on the hour")
    func englishMixedTimeRangeBareFirstEndpoint() {
        #expect(SpokenTextNormalizer.normalize("9-10:30", language: "en") == "nine to ten thirty")
    }

    @Test("EN a mixed time range inside a sentence leaves no colon and no stray dash")
    func englishMixedTimeRangeInSentence() {
        let result = SpokenTextNormalizer.normalize("Call between 10:30-11 please.", language: "en")
        #expect(result == "Call between ten thirty to eleven please.")
        #expect(!result.contains(":"))
        #expect(!result.contains("-"))
    }
}
