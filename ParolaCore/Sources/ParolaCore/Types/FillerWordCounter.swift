import Foundation

public enum FillerWordCounter {
    public static let defaultFillers: [String] = [
        "um", "uh", "uhm", "er", "erm",
        "like", "basically", "actually", "literally", "really",
        "you know", "i mean", "sort of", "kind of",
        "so", "well",
    ]

    /// Counts whole-word, case-insensitive occurrences; a phrase's words must be one character apart.
    public static func count(in text: String, fillers: [String] = defaultFillers) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var matcher = FillerMatcher(fillers: fillers)
        var runStart: String.Index?
        var runLength = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(after: index)
            if CharacterKind(trimmed[index]).isLetterOrDigit {
                if runStart == nil { runStart = index; runLength = 0 }
                runLength += 1
            } else {
                if let start = runStart { matcher.token(trimmed[start..<index], length: runLength) }
                runStart = nil
                matcher.separator()
            }
            index = next
        }
        if let start = runStart { matcher.token(trimmed[start..<trimmed.endIndex], length: runLength) }
        return matcher.count + spacedCount(in: trimmed, fillers: matcher.spacedFillers)
    }

    /// Fillers with a leading, trailing or doubled space keep the substring scan they were always counted with.
    private static func spacedCount(in trimmed: String, fillers: [String]) -> Int {
        guard !fillers.isEmpty else { return 0 }
        let flattened = trimmed.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        let haystack = " " + String(flattened) + " "
        var total = 0
        for filler in fillers {
            let needle = " \(filler) "
            var range = haystack.startIndex..<haystack.endIndex
            while let hit = haystack.range(of: needle, range: range) {
                total += 1
                range = haystack.index(before: hit.upperBound)..<haystack.endIndex
            }
        }
        return total
    }
}

/// Matches fillers against a stream of letter-and-digit runs and the characters between them.
struct FillerMatcher {
    private let singles: [String: Int]
    private let phrases: [[String]]
    private let longestWord: Int
    private let historyLimit: Int
    /// Fillers whose words aren't single-space separated; `FillerWordCounter` scans for those itself.
    let spacedFillers: [String]

    private var history: [(word: String?, gapBefore: Int)] = []
    private var phraseNextStart: [Int]
    private var tokenIndex = 0
    private var gap = 0
    private(set) var count = 0

    init(fillers: [String]) {
        var singles: [String: Int] = [:]
        var phrases: [[String]] = []
        var spaced: [String] = []
        for filler in fillers {
            let words = filler.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if words.contains(where: \.isEmpty) {
                spaced.append(filler)
            } else if words.count == 1 {
                singles[filler, default: 0] += 1
            } else {
                phrases.append(words)
            }
        }
        self.singles = singles
        self.phrases = phrases
        self.spacedFillers = spaced
        self.longestWord = (Array(singles.keys) + phrases.flatMap { $0 }).map(\.count).max() ?? 0
        self.historyLimit = max(1, phrases.map(\.count).max() ?? 1)
        self.phraseNextStart = Array(repeating: 0, count: phrases.count)
    }

    mutating func separator() {
        gap += 1
    }

    /// `length` is the run's character count, so a run longer than every filler word skips the lowercasing.
    mutating func token(_ run: Substring, length: Int) {
        let word = length <= longestWord ? run.lowercased() : nil
        history.append((word, gap))
        if history.count > historyLimit { history.removeFirst() }
        gap = 0
        defer { tokenIndex += 1 }
        guard let word else { return }
        count += singles[word] ?? 0
        for (index, phrase) in phrases.enumerated() where phrase.last == word {
            let start = tokenIndex - phrase.count + 1
            guard start >= phraseNextStart[index], history.count >= phrase.count else { continue }
            let window = history.suffix(phrase.count)
            let matches = zip(window, phrase).enumerated().allSatisfy { offset, pair in
                pair.0.word == pair.1 && (offset == 0 || pair.0.gapBefore == 1)
            }
            guard matches else { continue }
            count += 1
            phraseNextStart[index] = tokenIndex + 1
        }
    }
}
