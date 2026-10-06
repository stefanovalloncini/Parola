import Foundation

/// Rewrites numbers, times, dates, percentages, currency amounts and a handful of abbreviations into
/// words for text-to-speech engines that read digits aloud instead of expanding them, and strips
/// emoji, URLs and bracketed non-speech markers (`[Music]`). English and Italian get the full set of
/// rules; every other language only gets the stripping and plain integers spelled out in its locale.
/// Pure; never changes text outside a matched span.
public enum SpokenTextNormalizer {
    public static func normalize(_ text: String, language: String) -> String {
        let stripped = strippingNonSpeech(text)
        switch SpokenLanguage.baseCode(language) {
        case "en": return normalizingEnglish(stripped)
        case "it": return normalizingItalian(stripped)
        case let other: return normalizingPlainIntegers(stripped, locale: Locale(identifier: other))
        }
    }

    // MARK: - English

    private static let englishAbbreviations: [(String, String)] = [
        ("Dr.", "Doctor"),
        ("Mr.", "Mister"),
        ("Mrs.", "Missus"),
        ("e.g.", "for example"),
        ("etc.", "et cetera"),
        ("vs.", "versus"),
    ]

    private static let englishMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static let englishOrdinalIrregulars: [String: String] = [
        "one": "first", "two": "second", "three": "third", "five": "fifth",
        "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
    ]

    private static func normalizingEnglish(_ text: String) -> String {
        let locale = Locale(identifier: "en_US")
        let numberPattern = "\\d[\\d,]*(?:\\.\\d+)?"
        var result = replacingAbbreviations(text, table: englishAbbreviations)
        result = replacingISODates(result, language: "en", locale: locale)
        result = replacingDigitByDigitRuns(result, locale: locale)
        result = replacingTimes(result, language: "en", locale: locale)
        result = replacingRanges(result, language: "en", locale: locale)
        result = replacingNegativeNumbers(result, language: "en", locale: locale, numberPattern: numberPattern)
        result = replacingCurrencySymbols(result, language: "en", locale: locale, numberPattern: numberPattern)
        result = replacingCurrencyWords(result, language: "en", locale: locale, numberPattern: numberPattern)
        result = replacingPercent(result, suffix: "percent", locale: locale, numberPattern: numberPattern)
        result = replacingVersionStrings(result, locale: locale, joiner: "point")
        result = replacingEnglishDates(result, locale: locale)
        result = replacingEnglishYears(result, locale: locale)
        result = replacingPlainNumbers(result, locale: locale, numberPattern: numberPattern)
        return finish(restoringISOPlaceholders(result))
    }

    private static func replacingEnglishDates(_ text: String, locale: Locale) -> String {
        let monthPattern = englishMonths.joined(separator: "|")
        var result = replaceMatches(pattern: "\\b(\(monthPattern))\\s+(\\d{1,2})\\b", in: text) { match, ns in
            let month = ns.substring(with: match.range(at: 1))
            guard let day = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return month + " " + englishOrdinalDay(day, locale: locale)
        }
        result = replaceMatches(pattern: "\\b(\\d{1,2})\\s+(\(monthPattern))\\b", in: result) { match, ns in
            guard let day = Int(ns.substring(with: match.range(at: 1))) else { return nil }
            let month = ns.substring(with: match.range(at: 2))
            return month + " " + englishOrdinalDay(day, locale: locale)
        }
        return result
    }

    /// `NumberFormatter`'s `.ordinal` style only gives the digit form ("15th"), so the spelled ordinal
    /// is derived from the spelled cardinal: the handful of irregular endings, "-y" → "-ieth", else "+th".
    private static func englishOrdinalDay(_ day: Int, locale: Locale) -> String {
        let cardinal = spellOut(NSNumber(value: day), locale: locale)
        guard let dash = cardinal.lastIndex(of: "-") else {
            return englishOrdinalEnding(cardinal)
        }
        let prefix = cardinal[...dash]
        let lastWord = String(cardinal[cardinal.index(after: dash)...])
        return prefix + englishOrdinalEnding(lastWord)
    }

    private static func englishOrdinalEnding(_ word: String) -> String {
        if let irregular = englishOrdinalIrregulars[word] { return irregular }
        if word.hasSuffix("y") { return String(word.dropLast()) + "ieth" }
        return word + "th"
    }

    /// A standalone 4-digit number in 1100–2099 reads as a year: two two-digit groups, not the plain
    /// spell-out ("twenty twenty-six", not "two thousand twenty-six").
    private static func replacingEnglishYears(_ text: String, locale: Locale) -> String {
        replaceMatches(pattern: "(?<![\\d.,])(1[1-9]\\d{2}|20\\d{2})(?![\\d.,])", in: text) { match, ns in
            guard let year = Int(ns.substring(with: match.range(at: 1))) else { return nil }
            return spokenYear(year, locale: locale)
        }
    }

    private static func spokenYear(_ year: Int, locale: Locale) -> String {
        let high = year / 100
        let low = year % 100
        let highWords = spellOut(NSNumber(value: high), locale: locale)
        guard low != 0 else { return highWords + " hundred" }
        let lowWords = spellOut(NSNumber(value: low), locale: locale)
        return low < 10 ? highWords + " oh " + lowWords : highWords + " " + lowWords
    }

    // MARK: - Italian

    private static let italianAbbreviations: [(String, String)] = [
        ("Sig.ra", "Signora"),
        ("Dott.", "Dottor"),
        ("Sig.", "Signor"),
        ("ecc.", "eccetera"),
        ("es.", "per esempio"),
    ]

    private static let italianMonths = [
        "gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
        "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre",
    ]

    private static let italianMasculineNouns = ["minuto", "secondo", "giorno", "anno", "mese"]

    private static func normalizingItalian(_ text: String) -> String {
        let locale = Locale(identifier: "it_IT")
        let numberPattern = "\\d[\\d.]*(?:,\\d+)?"
        var result = replacingAbbreviations(text, table: italianAbbreviations)
        result = replacingISODates(result, language: "it", locale: locale)
        result = replacingDigitByDigitRuns(result, locale: locale)
        result = replacingTimes(result, language: "it", locale: locale)
        result = replacingRanges(result, language: "it", locale: locale)
        result = replacingNegativeNumbers(result, language: "it", locale: locale, numberPattern: numberPattern)
        result = replacingCurrencySymbols(result, language: "it", locale: locale, numberPattern: numberPattern)
        result = replacingCurrencyWords(result, language: "it", locale: locale, numberPattern: numberPattern)
        result = replacingItalianMasculineOne(result, locale: locale)
        result = replacingPercent(result, suffix: "per cento", locale: locale, numberPattern: numberPattern)
        result = replacingVersionStrings(result, locale: locale, joiner: "punto")
        result = replacingItalianDates(result)
        result = replacingPlainNumbers(result, locale: locale, numberPattern: numberPattern)
        return finish(restoringISOPlaceholders(result))
    }

    /// Italian elides "uno" to "un" before any of these masculine nouns, standing alone (not as the
    /// last digit of a larger number: "ventuno euro" keeps `NumberFormatter`'s own form). Goes through
    /// the same `italianNumeralWords` helper as the currency and negative-number passes.
    private static func replacingItalianMasculineOne(_ text: String, locale: Locale) -> String {
        let wordPattern = italianMasculineNouns.joined(separator: "|")
        return replaceMatches(pattern: "\\b1\\s+(\(wordPattern))\\b", in: text) { match, ns in
            let word = ns.substring(with: match.range(at: 1))
            return italianNumeralWords(NSNumber(value: 1), locale: locale, followedBy: word) + " " + word
        }
    }

    /// The first of the month is always "primo" in Italian, never the cardinal "uno"; every other day
    /// stays a plain cardinal, handled by the generic number pass.
    private static func replacingItalianDates(_ text: String) -> String {
        let monthPattern = italianMonths.joined(separator: "|")
        return replaceMatches(pattern: "\\b1°?\\s+(\(monthPattern))\\b", options: [.caseInsensitive], in: text) { match, ns in
            "primo " + ns.substring(with: match.range(at: 1))
        }
    }

    // MARK: - Shared: abbreviations

    private static func replacingAbbreviations(_ text: String, table: [(String, String)]) -> String {
        let lookup = Dictionary(uniqueKeysWithValues: table)
        let alternatives = table.map { NSRegularExpression.escapedPattern(for: $0.0) }
        let pattern = "\\b(?:" + alternatives.joined(separator: "|") + ")"
        return replaceMatches(pattern: pattern, in: text) { match, ns in
            lookup[ns.substring(with: match.range)]
        }
    }

    // MARK: - Shared: ISO dates

    /// "2026-10-06" reads as a date, not a dash-joined ID: a valid month (1–12) and day (1–31) read as
    /// "October sixth, twenty twenty-six" (EN) / "sei ottobre duemilaventisei" (IT, day 1 → "primo").
    /// An out-of-range month or day falls through unchanged: the whole span is parked behind
    /// `isoDatePlaceholder`'s private-use characters so no later numeric rule (the digit-by-digit or
    /// range passes would otherwise claim this exact shape) can touch it, then restored before `finish`.
    private static func replacingISODates(_ text: String, language: String, locale: Locale) -> String {
        replaceMatches(pattern: "\\b(\\d{4})-(\\d{2})-(\\d{2})\\b", in: text) { match, ns in
            guard let year = Int(ns.substring(with: match.range(at: 1))),
                  let month = Int(ns.substring(with: match.range(at: 2))),
                  let day = Int(ns.substring(with: match.range(at: 3))),
                  (1...12).contains(month), (1...31).contains(day) else {
                return isoDatePlaceholder(ns.substring(with: match.range))
            }
            if language == "it" {
                let monthName = italianMonths[month - 1]
                let dayWords = day == 1 ? "primo" : spellOut(NSNumber(value: day), locale: locale)
                let yearWords = spellOut(NSNumber(value: year), locale: locale)
                return "\(dayWords) \(monthName) \(yearWords)"
            }
            let monthName = englishMonths[month - 1]
            let dayWords = englishOrdinalDay(day, locale: locale)
            let yearWords = spokenYear(year, locale: locale)
            return "\(monthName) \(dayWords), \(yearWords)"
        }
    }

    private static let isoPlaceholderBase: UInt32 = 0xE000
    private static let isoPlaceholderDash: UInt32 = 0xE00A

    /// Maps "2026-13-42" to private-use characters one-for-one (digit → `isoPlaceholderBase` + digit,
    /// "-" → `isoPlaceholderDash`), so it reads as nothing to every other rule in the pipeline until
    /// `restoringISOPlaceholders` maps it back, right before `finish`.
    private static func isoDatePlaceholder(_ raw: String) -> String {
        String(raw.compactMap { character -> Character? in
            if let ascii = character.asciiValue, (0x30...0x39).contains(ascii) {
                return Character(Unicode.Scalar(isoPlaceholderBase + UInt32(ascii - 0x30))!)
            }
            return Character(Unicode.Scalar(isoPlaceholderDash)!)
        })
    }

    private static func restoringISOPlaceholders(_ text: String) -> String {
        String(text.map { character -> Character in
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return character }
            if (isoPlaceholderBase...isoPlaceholderBase + 9).contains(scalar.value) {
                return Character(Unicode.Scalar(0x30 + (scalar.value - isoPlaceholderBase))!)
            }
            if scalar.value == isoPlaceholderDash {
                return "-"
            }
            return character
        })
    }

    // MARK: - Shared: digit-by-digit runs (phone numbers and IDs)

    /// A "+" country-code prefix, or a run of 2+ space/dash-separated digit groups totalling 7+ digits,
    /// reads as a phone number or an ID, not a cardinal: each digit spelled on its own, groups paused
    /// with a comma. A standalone digit run with no separator at all is a quantity, never digit by
    /// digit — "1500000" is "one million five hundred thousand", handled by the plain-number pass.
    private static func replacingDigitByDigitRuns(_ text: String, locale: Locale) -> String {
        var result = replaceMatches(pattern: "\\+\\d(?:[\\d \\-]*\\d)?", in: text) { match, ns in
            let raw = ns.substring(with: match.range).dropFirst()
            return spellingDigitGroups(raw, locale: locale)
        }
        result = replaceMatches(pattern: "\\b\\d+(?:[ -]\\d+)+\\b", in: result) { match, ns in
            let raw = ns.substring(with: match.range)
            guard raw.filter(\.isNumber).count >= 7 else { return nil }
            return spellingDigitGroups(Substring(raw), locale: locale)
        }
        return result
    }

    private static func spellingDigitGroups(_ raw: Substring, locale: Locale) -> String {
        raw.split(whereSeparator: { $0 == " " || $0 == "-" })
            .map { spellingDigits($0, locale: locale) }
            .joined(separator: ", ")
    }

    private static func spellingDigits(_ digits: Substring, locale: Locale) -> String {
        digits.compactMap { character -> String? in
            guard let value = character.wholeNumberValue else { return nil }
            return spellOut(NSNumber(value: value), locale: locale)
        }.joined(separator: " ")
    }

    // MARK: - Shared: ranges

    /// "10-12" reads as "ten to twelve"/"dieci a dodici", not a bare spelled hyphen. Declines when
    /// the earlier digit-by-digit pass has already claimed the span (phone-shaped, 7+ digits).
    private static func replacingRanges(_ text: String, language: String, locale: Locale) -> String {
        let connector = language == "it" ? "a" : "to"
        return replaceMatches(pattern: "\\b(\\d+)-(\\d+)\\b", in: text) { match, ns in
            guard let first = parseNumber(ns.substring(with: match.range(at: 1)), locale: locale),
                  let second = parseNumber(ns.substring(with: match.range(at: 2)), locale: locale) else { return nil }
            return spellOut(first, locale: locale) + " " + connector + " " + spellOut(second, locale: locale)
        }
    }

    // MARK: - Shared: negative numbers

    /// A "-"/"−" right at a word start (not glued after a letter, as in "COVID-19", and not the dash
    /// of a range) reads as "minus"/"meno". A negative number elides "uno" the same way a positive one
    /// does — only right before a masculine noun — so the following word (if any) is captured too,
    /// just to check it against `italianNumeralWords`, and handed back unchanged either way.
    private static func replacingNegativeNumbers(
        _ text: String, language: String, locale: Locale, numberPattern: String
    ) -> String {
        let word = language == "it" ? "meno" : "minus"
        let pattern = "(?<![\\w.,])[-\u{2212}](\(numberPattern))(?:(\\s+)(\\p{L}+))?"
        return replaceMatches(pattern: pattern, in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            let wordRange = match.range(at: 3)
            let followingWord = wordRange.location != NSNotFound ? ns.substring(with: wordRange) : nil
            let numeral = language == "it"
                ? italianNumeralWords(amount, locale: locale, followedBy: followingWord)
                : spellOut(amount, locale: locale)
            guard let followingWord else { return word + " " + numeral }
            let space = ns.substring(with: match.range(at: 2))
            return word + " " + numeral + space + followingWord
        }
    }

    // MARK: - Shared: currency

    private struct CurrencyWords {
        let singular: String
        let plural: String
    }

    private static let dollarWords = ["en": CurrencyWords(singular: "dollar", plural: "dollars"),
                                       "it": CurrencyWords(singular: "dollaro", plural: "dollari")]
    private static let euroWords = ["en": CurrencyWords(singular: "euro", plural: "euros"),
                                     "it": CurrencyWords(singular: "euro", plural: "euro")]

    /// Italian "uno" elides to "un" only right before one of these masculine nouns; every other
    /// context — standalone, or before any other word — keeps the plain cardinal "uno". Shared by the
    /// currency, masculine-noun and negative-number passes so they can't drift on what counts as
    /// elidable (the negative-number path doesn't get to assume a noun follows at all).
    private static let italianElidingNouns: Set<String> = [
        "euro", "dollaro", "dollari", "minuto", "secondo", "giorno", "anno", "mese",
    ]

    private static func italianNumeralWords(_ amount: NSNumber, locale: Locale, followedBy word: String?) -> String {
        guard amount.doubleValue == 1 else { return spellOut(amount, locale: locale) }
        guard let word, italianElidingNouns.contains(word.lowercased()) else { return "uno" }
        return "un"
    }

    private static func replacingCurrencySymbols(
        _ text: String, language: String, locale: Locale, numberPattern: String
    ) -> String {
        replaceMatches(pattern: "([$€])(\(numberPattern))", in: text) { match, ns in
            let symbol = ns.substring(with: match.range(at: 1))
            let raw = ns.substring(with: match.range(at: 2))
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            let words = symbol == "$" ? dollarWords[language] : euroWords[language]
            guard let words else { return nil }
            let unit = amount.doubleValue == 1 ? words.singular : words.plural
            let numeral = language == "it" ? italianNumeralWords(amount, locale: locale, followedBy: unit) : spellOut(amount, locale: locale)
            return numeral + " " + unit
        }
    }

    private static func replacingCurrencyWords(
        _ text: String, language: String, locale: Locale, numberPattern: String
    ) -> String {
        let wordPattern = language == "en" ? "dollars?|euros?" : "dollari|dollaro|euro"
        return replaceMatches(pattern: "(\(numberPattern))\\s+(\(wordPattern))\\b", options: [.caseInsensitive], in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            let word = ns.substring(with: match.range(at: 2)).lowercased()
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            let words = word.hasPrefix("dollar") ? dollarWords[language] : euroWords[language]
            guard let words else { return nil }
            let unit = amount.doubleValue == 1 ? words.singular : words.plural
            let numeral = language == "it" ? italianNumeralWords(amount, locale: locale, followedBy: unit) : spellOut(amount, locale: locale)
            return numeral + " " + unit
        }
    }

    // MARK: - Shared: percent

    private static func replacingPercent(
        _ text: String, suffix: String, locale: Locale, numberPattern: String
    ) -> String {
        replaceMatches(pattern: "(\(numberPattern))\\s*%", in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            return spellOut(amount, locale: locale) + " " + suffix
        }
    }

    // MARK: - Shared: version strings

    /// "2.0.1" is a version, not a decimal with a dropped segment: each dot-separated part is spelled
    /// on its own and joined with "point"/"punto".
    private static func replacingVersionStrings(_ text: String, locale: Locale, joiner: String) -> String {
        replaceMatches(pattern: "\\b\\d+(?:\\.\\d+){2,}\\b", in: text) { match, ns in
            let raw = ns.substring(with: match.range)
            let segments = raw.split(separator: ".", omittingEmptySubsequences: false)
            var words: [String] = []
            for segment in segments {
                guard let value = Int(segment) else { return nil }
                words.append(spellOut(NSNumber(value: value), locale: locale))
            }
            return words.joined(separator: " \(joiner) ")
        }
    }

    // MARK: - Shared: times

    private static let timeHourMinute = "(2[0-4]|[01]?\\d):([0-5]\\d)"
    private static let timeHourOnly = "(2[0-4]|[01]?\\d)"

    /// Runs before the generic dash-range rule, so "10:30-11:00" reads as one time range instead of
    /// the range regex cutting across the colon and leaving a bogus "10:"/":00" behind. A range with
    /// only one side spelled out in full ("10:30-11") reads the bare side as on the hour, so neither
    /// a colon nor the dash itself ever leaks into the output.
    private static func replacingTimes(_ text: String, language: String, locale: Locale) -> String {
        let connector = language == "it" ? "a" : "to"
        var result = replaceMatches(pattern: "\\b\(timeHourMinute)-\(timeHourMinute)\\b", in: text) { match, ns in
            guard let hour1 = Int(ns.substring(with: match.range(at: 1))),
                  let minute1 = Int(ns.substring(with: match.range(at: 2))),
                  let hour2 = Int(ns.substring(with: match.range(at: 3))),
                  let minute2 = Int(ns.substring(with: match.range(at: 4))) else { return nil }
            let first = spokenTime(hour: hour1, minute: minute1, language: language, locale: locale, inRange: true)
            let second = spokenTime(hour: hour2, minute: minute2, language: language, locale: locale, inRange: true)
            return first + " " + connector + " " + second
        }
        result = replaceMatches(pattern: "\\b\(timeHourMinute)-\(timeHourOnly)(?!:)\\b", in: result) { match, ns in
            guard let hour1 = Int(ns.substring(with: match.range(at: 1))),
                  let minute1 = Int(ns.substring(with: match.range(at: 2))),
                  let hour2 = Int(ns.substring(with: match.range(at: 3))) else { return nil }
            let first = spokenTime(hour: hour1, minute: minute1, language: language, locale: locale, inRange: true)
            let second = spokenTime(hour: hour2, minute: 0, language: language, locale: locale, inRange: true)
            return first + " " + connector + " " + second
        }
        result = replaceMatches(pattern: "\\b\(timeHourOnly)-\(timeHourMinute)\\b", in: result) { match, ns in
            guard let hour1 = Int(ns.substring(with: match.range(at: 1))),
                  let hour2 = Int(ns.substring(with: match.range(at: 2))),
                  let minute2 = Int(ns.substring(with: match.range(at: 3))) else { return nil }
            let first = spokenTime(hour: hour1, minute: 0, language: language, locale: locale, inRange: true)
            let second = spokenTime(hour: hour2, minute: minute2, language: language, locale: locale, inRange: true)
            return first + " " + connector + " " + second
        }
        result = replaceMatches(pattern: "\\b\(timeHourMinute)\\b", in: result) { match, ns in
            guard let hour = Int(ns.substring(with: match.range(at: 1))),
                  let minute = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return spokenTime(hour: hour, minute: minute, language: language, locale: locale)
        }
        // Anything else shaped like "number:number" (an out-of-range hour, a one-digit minute, …)
        // isn't a valid time; decline the time reading but never leave the literal colon behind.
        result = replaceMatches(pattern: "\\b(\\d+):(\\d+)\\b", in: result) { match, ns in
            guard let first = parseNumber(ns.substring(with: match.range(at: 1)), locale: locale),
                  let second = parseNumber(ns.substring(with: match.range(at: 2)), locale: locale) else { return nil }
            return spellOut(first, locale: locale) + " " + spellOut(second, locale: locale)
        }
        return result
    }

    /// `inRange` drops the EN on-the-hour "hundred" ("ten thirty to eleven", not "… to eleven hundred");
    /// Italian already reads an on-the-hour time as the bare hour either way.
    private static func spokenTime(hour: Int, minute: Int, language: String, locale: Locale, inRange: Bool = false) -> String {
        let hourWords = spellOut(NSNumber(value: hour), locale: locale)
        if language == "it" {
            guard minute != 0 else { return hourWords }
            return hourWords + " e " + spellOut(NSNumber(value: minute), locale: locale)
        }
        guard minute != 0 else { return inRange ? hourWords : hourWords + " hundred" }
        let minuteWords = spellOut(NSNumber(value: minute), locale: locale)
        return minute < 10 ? hourWords + " oh " + minuteWords : hourWords + " " + minuteWords
    }

    // MARK: - Shared: plain numbers

    /// A digit run glued right after a letter-dash, as in "COVID-19", is a token, not a number.
    private static func replacingPlainNumbers(_ text: String, locale: Locale, numberPattern: String) -> String {
        replaceMatches(pattern: "(?<![A-Za-z-])\\b(\(numberPattern))\\b", in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            return spellOut(amount, locale: locale)
        }
    }

    /// A digit run next to "." or "," could be a decimal or a grouped number in some other locale's
    /// convention, and one glued after a letter-dash is a token, so only a separator-free, letter-free
    /// run counts as a plain integer.
    private static func normalizingPlainIntegers(_ text: String, locale: Locale) -> String {
        finish(replaceMatches(pattern: "(?<![\\d.,A-Za-z-])\\d+(?![\\d.,])", in: text) { match, ns in
            guard let value = Int(ns.substring(with: match.range)) else { return nil }
            return spellOut(NSNumber(value: value), locale: locale)
        })
    }

    // MARK: - Stripping

    private static let nonSpeechParentheticals: Set<String> = [
        "laughs", "laughing", "laugh", "laughter", "chuckles", "chuckling",
        "sighs", "sigh", "coughs", "cough", "applause", "clapping", "pause", "silence",
        "ride", "ridendo", "risata", "risate", "applausi", "sospira", "tossisce", "silenzio", "pausa",
    ]

    private static let urlWrapperPairs: [(open: String, close: String)] = [
        ("(", ")"), ("[", "]"), ("<", ">"), ("\"", "\""),
    ]

    private static let urlTrailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")

    private static func strippingNonSpeech(_ text: String) -> String {
        var result = strippingURLs(text)
        result = String(result.filter { character in
            let isEmoji = character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || character.unicodeScalars.last?.value == 0x20E3
            return !isEmoji
        })
        result = replaceMatches(pattern: "\\[[^\\]]*\\]", in: result) { _, _ in "" }
        result = replaceMatches(pattern: "\\(([^()]*)\\)", options: [.caseInsensitive], in: result) { match, ns in
            let content = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            return nonSpeechParentheticals.contains(content) ? "" : nil
        }
        return result
    }

    /// A URL wrapped in `() [] <> ""` disappears along with its wrapper; an unwrapped one keeps any
    /// sentence punctuation that follows it (the greedy match swallows it, so the transform hands it
    /// back as the replacement instead of discarding it).
    private static func strippingURLs(_ text: String) -> String {
        var result = text
        for (open, close) in urlWrapperPairs {
            let openPattern = NSRegularExpression.escapedPattern(for: open)
            let closePattern = NSRegularExpression.escapedPattern(for: close)
            let excluded = open == close ? "\\s\(openPattern)" : "\\s\(openPattern)\(closePattern)"
            let pattern = "\(openPattern)(?:https?://|www\\.)[^\(excluded)]+\(closePattern)"
            result = replaceMatches(pattern: pattern, in: result) { _, _ in "" }
        }
        return replaceMatches(pattern: "\\bhttps?://\\S+|\\bwww\\.\\S+", in: result) { match, ns in
            var trimmed = Substring(ns.substring(with: match.range))
            var trailing = ""
            while let last = trimmed.unicodeScalars.last, urlTrailingPunctuation.contains(last) {
                trailing = String(last) + trailing
                trimmed = trimmed.dropLast()
            }
            return trailing
        }
    }

    /// Collapses whitespace and drops every Unicode format character (category Cf — soft hyphens from
    /// `NumberFormatter`'s Italian spell-out, zero-width spaces, BOM, …), which a TTS engine would
    /// otherwise tokenize as a stray click or pause.
    private static func finish(_ text: String) -> String {
        let withoutFormatCharacters = String(text.unicodeScalars.filter { $0.properties.generalCategory != .format })
        return withoutFormatCharacters.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - NumberFormatter

    private static func spellOut(_ number: NSNumber, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .spellOut
        return formatter.string(from: number) ?? number.stringValue
    }

    private static func parseNumber(_ raw: String, locale: Locale) -> NSNumber? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.number(from: raw)
    }

    // MARK: - Regex

    /// Right-to-left replacement so an earlier match's range stays valid after a later one is replaced.
    private static func replaceMatches(
        pattern: String,
        options: NSRegularExpression.Options = [],
        in text: String,
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let replacement = transform(match, ns) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }
}
