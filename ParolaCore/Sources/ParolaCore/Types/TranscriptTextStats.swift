import Foundation

/// What the transcript inspector counts in a transcript's text, gathered in one walk over it.
public struct TranscriptTextStats: Equatable, Sendable {
    public var charCount = 0
    public var wordCount = 0
    public var sentenceCount = 0
    public var fillerCount = 0
    /// Letter-and-digit runs in each segment, in segment order: the words the speech-rate bins spread.
    public var segmentWordCounts: [Int] = []
    public var topWords: [WordFrequency.Entry] = []

    public init() {}

    /// Counts `Transcript.text` as `SentenceCounter`, `FillerWordCounter` and `WordFrequency` would, without building it.
    /// Throws `CancellationError` when the task running it is cancelled.
    public static func compute(
        segments: [TranscriptSegment],
        stopWords: Set<String> = WordFrequency.defaultStopWords,
        topWordLimit: Int = 20
    ) throws -> TranscriptTextStats {
        var scanner = TextStatsScanner(stopWords: stopWords)
        var segmentWordCounts: [Int] = []
        segmentWordCounts.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            segmentWordCounts.append(scanner.scan(segment.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        var stats = scanner.finish(topWordLimit: topWordLimit)
        stats.segmentWordCounts = segmentWordCounts
        return stats
    }
}

/// Feeds trimmed segment bodies through every counter at once, joined by one space as `Transcript.text` joins them.
private struct TextStatsScanner {
    private let stopWords: Set<String>
    private var fillers = FillerMatcher(fillers: FillerWordCounter.defaultFillers)
    private var sentences = SentenceTally()
    private var frequencies: [String: Int] = [:]
    private var charCount = 0
    private var wordCount = 0
    private var afterWhitespace = true
    private var hasText = false

    init(stopWords: Set<String>) {
        self.stopWords = stopWords
    }

    /// Returns the body's letter-and-digit runs.
    mutating func scan(_ body: String) -> Int {
        guard !body.isEmpty else { return 0 }
        if hasText { joiningSpace() }
        hasText = true
        var runs = 0
        var runStart: String.Index?
        var runLength = 0
        var wordStart: String.Index?
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(after: index)
            let character = body[index]
            charCount += 1
            let kind = CharacterKind(character)
            if !kind.isWhitespace, afterWhitespace { wordCount += 1 }
            afterWhitespace = kind.isWhitespace
            sentences.feed(character, kind: kind)
            let isLetterOrDigit = kind.isLetterOrDigit
            if isLetterOrDigit {
                if runStart == nil { runStart = index; runLength = 0; runs += 1 }
                runLength += 1
            } else {
                if let start = runStart { fillers.token(body[start..<index], length: runLength) }
                runStart = nil
                fillers.separator()
            }
            if isLetterOrDigit || character.isApostrophe {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                WordFrequency.tally(body[start..<index], into: &frequencies, minLength: 2, stopWords: stopWords)
                wordStart = nil
            }
            index = next
        }
        if let start = runStart { fillers.token(body[start..<body.endIndex], length: runLength) }
        if let start = wordStart {
            WordFrequency.tally(body[start..<body.endIndex], into: &frequencies, minLength: 2, stopWords: stopWords)
        }
        return runs
    }

    private mutating func joiningSpace() {
        charCount += 1
        afterWhitespace = true
        sentences.feed(" ", kind: CharacterKind(" "))
        fillers.separator()
    }

    func finish(topWordLimit: Int) -> TranscriptTextStats {
        var stats = TranscriptTextStats()
        guard hasText else { return stats }
        var sentences = sentences
        stats.charCount = charCount
        stats.wordCount = wordCount
        stats.sentenceCount = sentences.finish()
        stats.fillerCount = fillers.count
        stats.topWords = WordFrequency.top(frequencies, limit: topWordLimit)
        return stats
    }
}
