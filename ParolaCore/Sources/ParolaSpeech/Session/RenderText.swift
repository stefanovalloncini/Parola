import Foundation
import ParolaCore

/// What a renderer is given for one reading unit: the text spelled out for a renderer that can't expand
/// numbers, trimmed, and cut into pieces no longer than `maxUnitChars`. No pieces means the unit has
/// nothing to say.
enum RenderText {
    private static let clauseMarks: Set<Character> = [",", ";", ":"]
    private static let fullWidthMarks: Set<Character> = ["、", "，", "；", "：", "。"]

    static func pieces(of text: String, language: String, capabilities: SpeechRendererCapabilities) -> [String] {
        let spoken = capabilities.expandsNumbers ? text : SpokenTextNormalizer.normalize(text, language: language)
        return split(spoken, maxLength: capabilities.maxUnitChars).filter(isSpoken)
    }

    /// Cuts after the last clause mark that fits, else at the last space, else after `maxLength` characters.
    static func split(_ text: String, maxLength: Int) -> [String] {
        let limit = max(1, maxLength)
        var pieces: [String] = []
        var rest = text[...]
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { break }
            guard let end = rest.index(rest.startIndex, offsetBy: limit, limitedBy: rest.endIndex),
                  end < rest.endIndex
            else {
                pieces.append(trimmingTrailingWhitespace(rest))
                break
            }
            let cut = cut(in: rest, before: end)
            let piece = trimmingTrailingWhitespace(rest[..<cut])
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...]
        }
        return pieces
    }

    private static func cut(in text: Substring, before end: Substring.Index) -> Substring.Index {
        var clause: Substring.Index?
        var space: Substring.Index?
        var index = text.startIndex
        while index < end {
            let character = text[index]
            let next = text.index(after: index)
            if fullWidthMarks.contains(character) {
                clause = next
            } else if clauseMarks.contains(character), next == text.endIndex || text[next].isWhitespace {
                clause = next
            } else if character.isWhitespace, index > text.startIndex {
                space = index
            }
            index = next
        }
        return clause ?? space ?? end
    }

    private static func trimmingTrailingWhitespace(_ text: Substring) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard text[before].isWhitespace else { break }
            end = before
        }
        return String(text[..<end])
    }

    private static func isSpoken(_ piece: String) -> Bool {
        piece.contains { $0.isLetter || $0.isNumber }
    }
}
