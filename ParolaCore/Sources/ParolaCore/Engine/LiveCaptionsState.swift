import Foundation

public struct LiveCaptionsState: Sendable, Equatable {
    /// The last `maxLines` confirmed lines, for the caption display.
    public var confirmedLines: [String]
    /// Every line the session confirmed, for saving; the display keeps only the last few.
    public private(set) var history: [String]
    public var partial: String
    public var maxLines: Int
    public var isActive: Bool
    public var isLoading: Bool
    /// How far the model's download has got while there is one, so the panel can say so instead of just loading.
    public var downloadFraction: Double?
    public var error: String?

    public init(
        confirmedLines: [String] = [],
        partial: String = "",
        maxLines: Int = 4,
        isActive: Bool = false,
        isLoading: Bool = false,
        downloadFraction: Double? = nil,
        error: String? = nil
    ) {
        self.confirmedLines = confirmedLines
        self.history = confirmedLines
        self.partial = partial
        self.maxLines = maxLines
        self.isActive = isActive
        self.isLoading = isLoading
        self.downloadFraction = downloadFraction
        self.error = error
    }

    /// The newest confirmed line and the partial after it: what the panel rolls up, oldest words first.
    public var captionText: String {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return [confirmedLines.last, trimmed.isEmpty ? nil : trimmed].compactMap { $0 }.joined(separator: " ")
    }

    public var displayedText: String {
        var parts = confirmedLines
        if !partial.isEmpty { parts.append(partial) }
        return parts.joined(separator: " ")
    }

    /// The whole session one line per caption, the unconfirmed partial last: what Save Captions writes.
    public var historyText: String {
        var lines = history
        if !partial.isEmpty { lines.append(partial) }
        return lines.joined(separator: "\n")
    }

    /// The history by its length: comparing every line of a long session on each partial would cost O(lines).
    public static func == (lhs: LiveCaptionsState, rhs: LiveCaptionsState) -> Bool {
        lhs.confirmedLines == rhs.confirmedLines
            && lhs.history.count == rhs.history.count
            && lhs.partial == rhs.partial
            && lhs.maxLines == rhs.maxLines
            && lhs.isActive == rhs.isActive
            && lhs.isLoading == rhs.isLoading
            && lhs.downloadFraction == rhs.downloadFraction
            && lhs.error == rhs.error
    }

    /// The partial a streaming session shows before any speech has been decoded.
    public static let waitingPlaceholder = "Waiting for speech..."

    public mutating func apply(_ event: StreamingEvent) {
        switch event {
        case .partial(let text):
            partial = text
        case .confirmed(let segment):
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                history.append(trimmed)
                confirmedLines.append(trimmed)
                if confirmedLines.count > maxLines {
                    confirmedLines.removeFirst(confirmedLines.count - maxLines)
                }
            }
            partial = Self.remainder(of: partial, after: trimmed)
        case .voiceActivity:
            break
        case .warning(let msg):
            error = msg
        case .failed(let msg):
            error = msg
            isActive = false
            isLoading = false
            downloadFraction = nil
        case .finished:
            partial = ""
        }
    }

    /// The new partial arrives before the line it confirms: it loses the confirmed words only when it starts with all of them or is an older form of them.
    private static func remainder(of partial: String, after confirmed: String) -> String {
        let confirmedWords = confirmed.split(whereSeparator: \.isWhitespace).map(comparable)
        let words = partial.split(whereSeparator: \.isWhitespace)
        var matched = 0
        while matched < min(words.count, confirmedWords.count), comparable(words[matched]) == confirmedWords[matched] { matched += 1 }
        if matched == confirmedWords.count, matched > 0 { return words.dropFirst(matched).joined(separator: " ") }
        let endsInsideAWord = matched == words.count - 1 && matched < confirmedWords.count
            && confirmedWords[matched].hasPrefix(comparable(words[matched]))
        return matched == words.count || endsInsideAWord ? "" : partial
    }

    private static func comparable<S: StringProtocol>(_ word: S) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Puts an earlier run's captions ahead of this one's, for a session restarted mid-way.
    public mutating func continuing(after earlier: LiveCaptionsState) {
        history = earlier.history + history
        confirmedLines = Array((earlier.confirmedLines + confirmedLines).suffix(maxLines))
    }

    public mutating func reset() {
        confirmedLines = []
        history = []
        partial = ""
        error = nil
        isLoading = false
        downloadFraction = nil
    }
}
