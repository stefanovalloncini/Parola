import Foundation

public enum WordFrequency {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { word }
        public let word: String
        public let count: Int
    }

    public static let defaultStopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "while",
        "of", "at", "by", "for", "with", "about", "against", "between", "into", "through",
        "during", "before", "after", "above", "below", "to", "from", "up", "down", "in",
        "out", "on", "off", "over", "under", "again", "further", "once",
        "here", "there", "all", "any", "both", "each", "few", "more", "most", "other",
        "some", "such", "no", "nor", "not", "only", "own", "same", "so", "than", "too", "very",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "having",
        "do", "does", "did", "doing", "will", "would", "should", "could", "shall", "may",
        "might", "must", "can",
        "this", "that", "these", "those", "i", "me", "my", "we", "our", "you", "your",
        "he", "him", "his", "she", "her", "it", "its", "they", "them", "their", "what",
        "which", "who", "whom", "as", "just", "really", "also",
    ]

    public static let italianStopWords: Set<String> = [
        "il", "lo", "la", "gli", "le", "un", "uno", "una",
        "del", "dello", "della", "dei", "degli", "delle",
        "al", "allo", "alla", "ai", "agli", "alle",
        "dal", "dallo", "dalla", "dai", "dagli", "dalle",
        "nel", "nello", "nella", "nei", "negli", "nelle",
        "sul", "sullo", "sulla", "sui", "sugli", "sulle",
        "col", "coi",
        "di", "da", "in", "con", "su", "per", "tra", "fra",
        "ed", "od", "ma", "se", "che", "come", "perché", "perche",
        "quando", "mentre", "anche", "oppure", "però", "pero",
        "quindi", "dunque", "infatti", "cioè", "cioe", "ovvero",
        "allora", "insomma", "comunque", "ecco",
        "io", "tu", "lui", "lei", "noi", "voi", "loro",
        "mi", "ti", "ci", "vi", "si", "ne", "me", "te", "chi", "cui",
        "mio", "mia", "miei", "mie", "tuo", "tua", "tuoi", "tue",
        "suo", "sua", "suoi", "sue",
        "nostro", "nostra", "nostri", "nostre",
        "vostro", "vostra", "vostri", "vostre",
        "questo", "questa", "questi", "queste",
        "quello", "quella", "quelli", "quelle", "quel",
        "non", "più", "piu", "meno", "molto", "molta", "molti", "molte",
        "poco", "poca", "pochi", "poche", "tanto", "tanta", "tanti", "tante",
        "troppo", "tutto", "tutta", "tutti", "tutte",
        "già", "gia", "ancora", "sempre", "mai",
        "qui", "qua", "là", "lì", "dove", "quanto", "quanti",
        "sono", "sei", "siamo", "siete", "era", "ero", "eri", "erano", "eravamo",
        "sia", "siano", "essere",
        "ho", "hai", "ha", "abbiamo", "avete", "hanno",
        "avevo", "aveva", "avevano", "avere", "abbia",
    ]

    /// Stop words for a transcript's language. Falls back to the English set for languages
    /// without a dedicated list, so the "Top words" view never surfaces function words.
    public static func stopWords(for languageCode: String?) -> Set<String> {
        let code = String((languageCode ?? "").lowercased().prefix(2))
        return code == "it" ? defaultStopWords.union(italianStopWords) : defaultStopWords
    }

    public static func compute(
        text: String,
        limit: Int = 20,
        minLength: Int = 2,
        stopWords: Set<String> = defaultStopWords
    ) -> [Entry] {
        var counts: [String: Int] = [:]
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && !$0.isApostrophe }) {
            tally(raw, into: &counts, minLength: minLength, stopWords: stopWords)
        }
        return top(counts, limit: limit)
    }

    /// Counts one run of letters, digits and apostrophes, lowercased and stripped of its outer apostrophes.
    static func tally(_ raw: Substring, into counts: inout [String: Int], minLength: Int, stopWords: Set<String>) {
        var token = raw.lowercased()
        while token.first?.isApostrophe == true { token.removeFirst() }
        while token.last?.isApostrophe == true { token.removeLast() }
        guard token.count >= minLength else { return }
        guard !stopWords.contains(token) else { return }
        counts[token, default: 0] += 1
    }

    static func top(_ counts: [String: Int], limit: Int) -> [Entry] {
        counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        .prefix(limit)
        .map { Entry(word: $0.key, count: $0.value) }
    }
}

extension Character {
    var isApostrophe: Bool { self == "'" || self == "\u{2019}" }
}
