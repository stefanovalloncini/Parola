import Foundation

public struct ActionItem: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let assignee: String?
    public let task: String
    public let dueDate: String?

    public init(id: UUID = UUID(), assignee: String? = nil, task: String, dueDate: String? = nil) {
        self.id = id
        self.assignee = assignee
        self.task = task
        self.dueDate = dueDate
    }
}

public enum ActionItemParser {
    public static func parse(_ text: String) -> [ActionItem] {
        text.split(whereSeparator: { $0.isNewline })
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ raw: String) -> ActionItem? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let body = stripListMarker(trimmed), !body.isEmpty else { return nil }

        var rest = body
        let assignee = takeLeadingBracket(&rest)
        let dueDate = takeTrailingBracket(&rest)
        let task = rest.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return nil }

        return ActionItem(assignee: assignee, task: task, dueDate: dueDate)
    }

    private static func stripListMarker(_ line: String) -> String? {
        for marker in ["-", "*", "•"] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return stripOrderedMarker(line)
    }

    private static func stripOrderedMarker(_ line: String) -> String? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isASCII, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex,
              line[idx] == "." || line[idx] == ")" else { return nil }
        let afterDelimiter = line.index(after: idx)
        // A digit run plus "." or ")" is a list marker only when a space or line end follows, so "3.5 mg" stays prose.
        guard afterDelimiter == line.endIndex || line[afterDelimiter].isWhitespace else { return nil }
        return String(line[afterDelimiter...]).trimmingCharacters(in: .whitespaces)
    }

    private static func takeLeadingBracket(_ rest: inout String) -> String? {
        guard rest.first == "[", let end = rest.firstIndex(of: "]") else { return nil }
        let inside = rest[rest.index(after: rest.startIndex)..<end]
            .trimmingCharacters(in: .whitespaces)
        rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        return inside.isEmpty ? nil : inside
    }

    private static func takeTrailingBracket(_ rest: inout String) -> String? {
        guard rest.last == "]", let start = rest.lastIndex(of: "[") else { return nil }
        let inside = rest[rest.index(after: start)..<rest.index(before: rest.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        rest = String(rest[..<start]).trimmingCharacters(in: .whitespaces)
        let cleaned: String
        if inside.lowercased().hasPrefix("by ") {
            cleaned = String(inside.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else {
            cleaned = inside
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
