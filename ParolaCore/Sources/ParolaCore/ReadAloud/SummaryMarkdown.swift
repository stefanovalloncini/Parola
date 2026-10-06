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
        let indices = Array(line[start...].indices)
        let characters = indices.map { line[$0] }
        var dropped = [Bool](repeating: false, count: characters.count)
        dropLinkSyntax(in: characters, &dropped)
        dropCodeAndStrikeMarks(in: characters, &dropped)
        dropEmphasisPairs(in: characters, &dropped)

        var kept: [Range<String.Index>] = []
        var runStart: Int?
        for position in 0...characters.count {
            let keeps = position < characters.count && !dropped[position]
            if keeps, runStart == nil {
                runStart = position
            } else if !keeps, let open = runStart {
                kept.append(indices[open]..<(position < indices.count ? indices[position] : line.endIndex))
                runStart = nil
            }
        }
        return kept
    }

    private static func dropLinkSyntax(in characters: [Character], _ dropped: inout [Bool]) {
        var position = 0
        while position < characters.count {
            guard characters[position] == "[", let tail = linkTail(in: characters, openingAt: position) else {
                position += 1
                continue
            }
            if position > 0, characters[position - 1] == "!" { dropped[position - 1] = true }
            dropped[position] = true
            for index in tail { dropped[index] = true }
            position = tail.upperBound
        }
    }

    /// The `](address)` after a link's text, when the `[` at `bracket` opens one; the address may nest parentheses.
    private static func linkTail(in characters: [Character], openingAt bracket: Int) -> Range<Int>? {
        guard let close = characters[(bracket + 1)...].firstIndex(of: "]"),
              close + 1 < characters.count, characters[close + 1] == "(" else { return nil }
        var depth = 0
        for position in (close + 1)..<characters.count {
            if characters[position] == "(" {
                depth += 1
            } else if characters[position] == ")" {
                depth -= 1
                if depth == 0 { return close..<position + 1 }
            }
        }
        return nil
    }

    private static func dropCodeAndStrikeMarks(in characters: [Character], _ dropped: inout [Bool]) {
        for position in characters.indices where !dropped[position] {
            switch characters[position] {
            case "`":
                dropped[position] = true
            case "~":
                let doubled = (position > 0 && characters[position - 1] == "~")
                    || (position + 1 < characters.count && characters[position + 1] == "~")
                if doubled { dropped[position] = true }
            default:
                break
            }
        }
    }

    /// Drops `*` and `_` runs only as matched opener/closer pairs, CommonMark's flanking rules without intraword emphasis.
    private static func dropEmphasisPairs(in characters: [Character], _ dropped: inout [Bool]) {
        var openers: [(mark: Character, run: Range<Int>)] = []
        var position = 0
        while position < characters.count {
            let mark = characters[position]
            guard mark == "*" || mark == "_", !dropped[position] else {
                position += 1
                continue
            }
            var end = position + 1
            while end < characters.count, characters[end] == mark, !dropped[end] { end += 1 }
            let before = position > 0 ? characters[position - 1] : nil
            let after = end < characters.count ? characters[end] : nil
            let left = isLeftFlanking(before: before, after: after)
            let right = isLeftFlanking(before: after, after: before)
            let canOpen = left && (!right || isPunctuation(before))
            let canClose = right && (!left || isPunctuation(after))
            if canClose, let match = openers.lastIndex(where: { $0.mark == mark }) {
                for index in openers[match].run { dropped[index] = true }
                for index in position..<end { dropped[index] = true }
                openers.removeSubrange(match...)
            } else if canOpen {
                openers.append((mark, position..<end))
            }
            position = end
        }
    }

    private static func isLeftFlanking(before: Character?, after: Character?) -> Bool {
        guard let after, !after.isWhitespace else { return false }
        guard isPunctuation(after) else { return true }
        guard let before else { return true }
        return before.isWhitespace || isPunctuation(before)
    }

    private static func isPunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isPunctuation || character.isSymbol
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
