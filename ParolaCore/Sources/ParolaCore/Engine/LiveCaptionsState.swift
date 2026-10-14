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

    /// The session delivers a take's new partial before the line it confirms: one that starts with the line is its older form, and one that doesn't is newer and stays.
    private static func remainder(of partial: String, after confirmed: String) -> String {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return partial }
        if confirmed.hasPrefix(text) { return "" }
        guard text.hasPrefix(confirmed) else { return partial }
        return String(text.dropFirst(confirmed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
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
