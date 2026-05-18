import Foundation

public struct LibrarySummary: Sendable, Equatable {
    public let total: Int
    public let pinned: Int
    public let transcriptions: Int
    public let meetings: Int
    public let dictations: Int

    public static let empty = LibrarySummary(total: 0, pinned: 0, transcriptions: 0, meetings: 0, dictations: 0)

    public init(total: Int, pinned: Int, transcriptions: Int, meetings: Int, dictations: Int) {
        self.total = total
        self.pinned = pinned
        self.transcriptions = transcriptions
        self.meetings = meetings
        self.dictations = dictations
    }

    public init(entries: [LibraryEntry]) {
        var total = 0, pinned = 0, t = 0, m = 0, d = 0
        for e in entries {
            total += 1
            if e.pinned { pinned += 1 }
            switch e.category {
            case .transcription: t += 1
            case .meeting: m += 1
            case .dictation: d += 1
            }
        }
        self.init(total: total, pinned: pinned, transcriptions: t, meetings: m, dictations: d)
    }
}
