import Foundation

public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Double

    public init(id: String = UUID().uuidString, title: String, start: Double) {
        self.id = id
        self.title = title
        self.start = start
    }
}

public struct Summary: Codable, Hashable, Sendable {
    public var text: String
    public var chapters: [Chapter]

    public init(text: String, chapters: [Chapter] = []) {
        self.text = text
        self.chapters = chapters
    }
}
