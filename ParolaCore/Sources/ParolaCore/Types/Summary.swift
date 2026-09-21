import Foundation

public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Double

    public init(id: String, title: String, start: Double) {
        self.id = id
        self.title = title
        self.start = start
    }

    public init(title: String, start: Double) {
        self.id = Self.stableID(title: title, start: start)
        self.title = title
        self.start = start
    }

    static func stableID(title: String, start: Double) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let startKey = Int(exactly: max(0, start).rounded()) ?? .max
        return "ch-\(startKey)-\(String(hash, radix: 16))"
    }

    static func cleaned(title rawTitle: String, start: Double) -> Chapter? {
        let title = ChapterTitle.clean(rawTitle)
        guard !title.isEmpty else { return nil }
        return Chapter(title: title, start: start)
    }
}

public struct Summary: Codable, Hashable, Sendable {
    public var text: String
    public var chapters: [Chapter]
    public var actionItems: [String]

    public init(text: String, chapters: [Chapter] = [], actionItems: [String] = []) {
        self.text = text
        self.chapters = chapters
        self.actionItems = actionItems
    }

    private enum CodingKeys: String, CodingKey {
        case text, chapters, actionItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        chapters = try c.decode([Chapter].self, forKey: .chapters)
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(chapters, forKey: .chapters)
        try c.encode(actionItems, forKey: .actionItems)
    }
}
