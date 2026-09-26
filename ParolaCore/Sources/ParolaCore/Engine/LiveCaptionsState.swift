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
    public var error: String?

    public init(
        confirmedLines: [String] = [],
        partial: String = "",
        maxLines: Int = 4,
        isActive: Bool = false,
        isLoading: Bool = false,
        error: String? = nil
    ) {
        self.confirmedLines = confirmedLines
        self.history = confirmedLines
        self.partial = partial
        self.maxLines = maxLines
        self.isActive = isActive
        self.isLoading = isLoading
        self.error = error
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
            && lhs.error == rhs.error
    }

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
            partial = ""
        case .voiceActivity:
            break
        case .warning(let msg):
            error = msg
        case .failed(let msg):
            error = msg
            isActive = false
            isLoading = false
        case .finished:
            partial = ""
        }
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
    }
}
