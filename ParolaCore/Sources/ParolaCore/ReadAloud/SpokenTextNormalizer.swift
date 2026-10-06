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
        result = replacingCurrencySymbols(result, language: "en", locale: locale, numberPattern: numberPattern)
        result = replacingCurrencyWords(result, language: "en", locale: locale, numberPattern: numberPattern)
        result = replacingPercent(result, suffix: "percent", locale: locale, numberPattern: numberPattern)
        result = replacingTimes(result, language: "en", locale: locale)
        result = replacingEnglishDates(result, locale: locale)
        result = replacingEnglishYears(result, locale: locale)
        result = replacingPlainNumbers(result, locale: locale, numberPattern: numberPattern)
        return finish(result)
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

    private static func normalizingItalian(_ text: String) -> String {
        let locale = Locale(identifier: "it_IT")
        let numberPattern = "\\d[\\d.]*(?:,\\d+)?"
        var result = replacingAbbreviations(text, table: italianAbbreviations)
        result = replacingCurrencySymbols(result, language: "it", locale: locale, numberPattern: numberPattern)
        result = replacingCurrencyWords(result, language: "it", locale: locale, numberPattern: numberPattern)
        result = replacingPercent(result, suffix: "per cento", locale: locale, numberPattern: numberPattern)
        result = replacingTimes(result, language: "it", locale: locale)
        result = replacingPlainNumbers(result, locale: locale, numberPattern: numberPattern)
        return finish(result)
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

    // MARK: - Shared: currency

    private struct CurrencyWords {
        let singular: String
        let plural: String
    }

    private static let dollarWords = ["en": CurrencyWords(singular: "dollar", plural: "dollars"),
                                       "it": CurrencyWords(singular: "dollaro", plural: "dollari")]
    private static let euroWords = ["en": CurrencyWords(singular: "euro", plural: "euros"),
                                     "it": CurrencyWords(singular: "euro", plural: "euro")]

    private static func replacingCurrencySymbols(
        _ text: String, language: String, locale: Locale, numberPattern: String
    ) -> String {
        replaceMatches(pattern: "([$€])(\(numberPattern))", in: text) { match, ns in
            let symbol = ns.substring(with: match.range(at: 1))
            let raw = ns.substring(with: match.range(at: 2))
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            let words = symbol == "$" ? dollarWords[language] : euroWords[language]
            guard let words else { return nil }
            return spellOut(amount, locale: locale) + " " + (amount.doubleValue == 1 ? words.singular : words.plural)
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
            return spellOut(amount, locale: locale) + " " + (amount.doubleValue == 1 ? words.singular : words.plural)
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

    // MARK: - Shared: times

    private static func replacingTimes(_ text: String, language: String, locale: Locale) -> String {
        replaceMatches(pattern: "\\b(2[0-3]|[01]?\\d):([0-5]\\d)\\b", in: text) { match, ns in
            guard let hour = Int(ns.substring(with: match.range(at: 1))),
                  let minute = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return spokenTime(hour: hour, minute: minute, language: language, locale: locale)
        }
    }

    private static func spokenTime(hour: Int, minute: Int, language: String, locale: Locale) -> String {
        let hourWords = spellOut(NSNumber(value: hour), locale: locale)
        if language == "it" {
            guard minute != 0 else { return hourWords }
            return hourWords + " e " + spellOut(NSNumber(value: minute), locale: locale)
        }
        guard minute != 0 else { return hourWords + " hundred" }
        let minuteWords = spellOut(NSNumber(value: minute), locale: locale)
        return minute < 10 ? hourWords + " oh " + minuteWords : hourWords + " " + minuteWords
    }

    // MARK: - Shared: plain numbers

    private static func replacingPlainNumbers(_ text: String, locale: Locale, numberPattern: String) -> String {
        replaceMatches(pattern: "\\b(\(numberPattern))\\b", in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            guard let amount = parseNumber(raw, locale: locale) else { return nil }
            return spellOut(amount, locale: locale)
        }
    }

    /// A digit run next to "." or "," could be a decimal or a grouped number in some other locale's
    /// convention, so only a run with no separator on either side counts as a plain integer.
    private static func normalizingPlainIntegers(_ text: String, locale: Locale) -> String {
        finish(replaceMatches(pattern: "(?<![\\d.,])\\d+(?![\\d.,])", in: text) { match, ns in
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

    private static func strippingNonSpeech(_ text: String) -> String {
        var result = replaceMatches(pattern: "\\bhttps?://\\S+|\\bwww\\.\\S+", in: text) { _, _ in "" }
        result = String(result.filter { character in
            !character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        })
        result = replaceMatches(pattern: "\\[[^\\]]*\\]", in: result) { _, _ in "" }
        result = replaceMatches(pattern: "\\(([^()]*)\\)", options: [.caseInsensitive], in: result) { match, ns in
            let content = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
            return nonSpeechParentheticals.contains(content) ? "" : nil
        }
        return result
    }

    private static func finish(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
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
