import Foundation

public struct LiveCaptionsState: Sendable, Equatable {
    public var confirmedLines: [String]
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

    public mutating func apply(_ event: StreamingEvent) {
        switch event {
        case .partial(let text):
            partial = text
        case .confirmed(let segment):
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
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

    public mutating func reset() {
        confirmedLines = []
        partial = ""
        error = nil
        isLoading = false
    }
}
