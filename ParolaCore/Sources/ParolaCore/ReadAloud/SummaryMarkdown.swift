import Foundation

enum SummaryMarkdown {
    enum LineKind {
        case plain
        case heading
        case listItem
    }

    struct StrippedLine {
        let kind: LineKind
        let kept: [Range<String.Index>]
    }

    static func strip(_ line: Substring) -> StrippedLine {
        var index = skippingSpaces(line, from: line.startIndex)
        while index < line.endIndex, line[index] == ">" {
            index = skippingSpaces(line, from: line.index(after: index))
        }
        var kind = LineKind.plain
        if let afterHeading = headingMarkerEnd(line, at: index) {
            kind = .heading
            index = afterHeading
        } else if let afterItem = listMarkerEnd(line, at: index) {
            kind = .listItem
            index = taskBoxEnd(line, at: afterItem) ?? afterItem
        }
        return StrippedLine(kind: kind, kept: inlineKept(line, from: index))
    }

    static func plainText(_ line: Substring) -> String {
        strip(line).kept.map { line[$0] }.joined()
    }

    private static func inlineKept(_ line: Substring, from start: String.Index) -> [Range<String.Index>] {
        var kept: [Range<String.Index>] = []
        var runStart: String.Index?
        var linkTail: Range<String.Index>?
        var index = start

        func close(at end: String.Index) {
            if let open = runStart, open < end { kept.append(open..<end) }
            runStart = nil
        }

        while index < line.endIndex {
            if let tail = linkTail, index == tail.lowerBound {
                close(at: index)
                index = tail.upperBound
                linkTail = nil
                continue
            }
            let character = line[index]
            let next = line.index(after: index)
            if linkTail == nil {
                let bracket = character == "!" && next < line.endIndex && line[next] == "[" ? next : index
                if line[bracket] == "[", let tail = linkTailRange(line, openingAt: bracket) {
                    close(at: index)
                    linkTail = tail
                    index = line.index(after: bracket)
                    continue
                }
            }
            if isInlineMarker(character, at: index, in: line) {
                close(at: index)
            } else if runStart == nil {
                runStart = index
            }
            index = next
        }
        close(at: line.endIndex)
        return kept
    }

    private static func isInlineMarker(_ character: Character, at index: String.Index, in line: Substring) -> Bool {
        switch character {
        case "*", "`":
            return true
        case "~":
            return neighbour(before: index, in: line) == "~" || neighbour(after: index, in: line) == "~"
        case "_":
            return !isWordCharacter(neighbour(before: index, in: line)) || !isWordCharacter(neighbour(after: index, in: line))
        default:
            return false
        }
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private static func neighbour(before index: String.Index, in line: Substring) -> Character? {
        index > line.startIndex ? line[line.index(before: index)] : nil
    }

    private static func neighbour(after index: String.Index, in line: Substring) -> Character? {
        let next = line.index(after: index)
        return next < line.endIndex ? line[next] : nil
    }

    /// The `](url)` after a link's text, when the `[` at `bracket` opens one.
    private static func linkTailRange(_ line: Substring, openingAt bracket: String.Index) -> Range<String.Index>? {
        guard let close = line[line.index(after: bracket)...].firstIndex(of: "]") else { return nil }
        let paren = line.index(after: close)
        guard paren < line.endIndex, line[paren] == "(",
              let end = line[paren...].firstIndex(of: ")") else { return nil }
        return close..<line.index(after: end)
    }

    private static func headingMarkerEnd(_ line: Substring, at start: String.Index) -> String.Index? {
        var index = start
        var hashes = 0
        while index < line.endIndex, line[index] == "#" {
            hashes += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(hashes), index == line.endIndex || line[index].isWhitespace else { return nil }
        return skippingSpaces(line, from: index)
    }

    private static func listMarkerEnd(_ line: Substring, at start: String.Index) -> String.Index? {
        guard start < line.endIndex else { return nil }
        var index = start
        if ["-", "*", "+", "•"].contains(line[index]) {
            index = line.index(after: index)
        } else {
            while index < line.endIndex, line[index].isASCII, line[index].isNumber {
                index = line.index(after: index)
            }
            guard index > start, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index].isWhitespace else { return nil }
        return skippingSpaces(line, from: index)
    }

    private static func taskBoxEnd(_ line: Substring, at start: String.Index) -> String.Index? {
        let box = line[start...].prefix(3)
        guard ["[ ]", "[x]", "[X]"].contains(box) else { return nil }
        let after = box.endIndex
        guard after == line.endIndex || line[after].isWhitespace else { return nil }
        return skippingSpaces(line, from: after)
    }

    private static func skippingSpaces(_ line: Substring, from start: String.Index) -> String.Index {
        line[start...].firstIndex { !$0.isWhitespace } ?? line.endIndex
    }
}
