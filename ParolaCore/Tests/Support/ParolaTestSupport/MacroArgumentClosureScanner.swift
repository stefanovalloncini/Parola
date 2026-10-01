import Foundation

/// Flags closures inside #expect/#require within a closure: Swift 6.4 can give a later same-type closure there the macro closure's symbol.
public enum MacroArgumentClosureScanner {
    public struct Violation: Sendable, Equatable {
        public let line: Int
        public let snippet: String
    }

    private enum BodyKind {
        case topLevel
        case declaration
        case controlFlow
        case closure
    }

    private static let continuationChars: Set<Character> = [
        ",", "+", "-", "*", "/", "%", "=", "<", "(", "[", ".", "&", "|", "~", "^",
    ]
    private static let continuationWords: Set<String> = [
        "as", "where", "return", "throws", "rethrows", "async", "try", "await", "else",
        "is", "case", "default", "some", "any",
    ]
    private static let headerKeywords: Set<String> = ["for", "if", "while", "switch", "guard"]
    private static let controlFlowKeywords: Set<String> = [
        "if", "else", "for", "while", "switch", "do", "catch", "repeat", "guard", "defer",
    ]
    private static let typeKeywords: Set<String> = [
        "struct", "class", "enum", "extension", "protocol", "actor",
    ]
    private static let modifierWords: Set<String> = [
        "static", "private", "fileprivate", "public", "internal", "open", "lazy", "nonisolated",
        "override", "final", "mutating", "nonmutating", "convenience", "required", "dynamic",
        "weak", "unowned", "class",
    ]

    public static func violations(in source: String) -> [Violation] {
        let t = source.unicodeScalars.map(Character.init)
        let n = t.count
        let mask = computeOpaqueMask(t)
        var results: [Violation] = []
        var stack: [BodyKind] = [.topLevel]
        var parenDepthStack: [Int] = []
        var statementStartStack: [Int] = []
        var statementStart = 0
        var nonBraceDepth = 0
        var lastNonSpaceChar: Character?
        var i = 0
        while i < n {
            if mask.isOpaque[i] {
                if !mask.isComment[i] {
                    lastNonSpaceChar = t[i]
                }
                i += 1
                continue
            }
            let c = t[i]
            if c == "(" || c == "[" {
                nonBraceDepth += 1
                lastNonSpaceChar = c
                i += 1
                continue
            }
            if c == ")" || c == "]" {
                nonBraceDepth -= 1
                lastNonSpaceChar = c
                i += 1
                continue
            }
            if c == "\n" {
                if nonBraceDepth <= 0 {
                    let continues = lastNonSpaceChar.map(continuationChars.contains) ?? false
                        || lastWord(t, mask.isComment, i).map(continuationWords.contains) ?? false
                        || peekNextWord(t, mask.isComment, i + 1, n) == "where"
                    if !continues {
                        statementStart = i + 1
                    }
                }
                i += 1
                continue
            }
            if c == ";" {
                i += 1
                statementStart = i
                nonBraceDepth = 0
                lastNonSpaceChar = nil
                continue
            }
            if c == "{" {
                let fragment = sanitizedFragment(t, mask.isOpaque, statementStart, i)
                stack.append(nonBraceDepth > 0 ? .closure : classify(fragment))
                parenDepthStack.append(nonBraceDepth)
                statementStartStack.append(statementStart)
                i += 1
                statementStart = i
                nonBraceDepth = 0
                lastNonSpaceChar = nil
                continue
            }
            if c == "}" {
                if stack.count > 1 { stack.removeLast() }
                nonBraceDepth = parenDepthStack.popLast() ?? 0
                let savedStart = statementStartStack.popLast() ?? 0
                i += 1
                statementStart = nonBraceDepth > 0 ? savedStart : i
                lastNonSpaceChar = nil
                continue
            }
            if c == "#", let openParen = matchMacroKeyword(t, i, n, mask.isOpaque) {
                let macroStart = i
                if let closeParen = findMatching(t, openParen, "(", ")", n, mask.isOpaque) {
                    if nearestNonControlFlow(stack) == .closure {
                        let hasBraceInArgs = containsBrace(t, mask.isOpaque, openParen + 1, closeParen)
                        let headerFragment = sanitizedFragment(t, mask.isOpaque, statementStart, macroStart)
                        let inHeader = firstSignificantWord(headerFragment).map(headerKeywords.contains) ?? false
                        var hasTrailingClosure = false
                        if !inHeader {
                            let trailingStart = skipWSComments(t, mask.isComment, closeParen + 1, n)
                            hasTrailingClosure = trailingStart < n && t[trailingStart] == "{"
                        }
                        if hasBraceInArgs || hasTrailingClosure {
                            let line = lineOf(t, macroStart)
                            let snippetEnd = min(n, macroStart + 70)
                            results.append(Violation(line: line, snippet: String(t[macroStart..<snippetEnd])))
                        }
                    }
                    nonBraceDepth += 1
                    lastNonSpaceChar = "("
                    i = openParen + 1
                    continue
                }
            }
            if !c.isWhitespace {
                lastNonSpaceChar = c
            }
            i += 1
        }
        return results
    }

    private static func lastWord(_ t: [Character], _ isComment: [Bool], _ before: Int) -> String? {
        var j = before
        while j > 0, isComment[j - 1] || t[j - 1] == " " || t[j - 1] == "\t" { j -= 1 }
        var k = j
        while k > 0, isIdentChar(t[k - 1]) { k -= 1 }
        guard k < j else { return nil }
        if k > 0, t[k - 1] == "." { return nil }
        return String(t[k..<j])
    }

    private static func peekNextWord(_ t: [Character], _ isComment: [Bool], _ from: Int, _ n: Int) -> String? {
        var i = from
        while i < n {
            let c = t[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
                continue
            }
            if isComment[i] {
                i += 1
                continue
            }
            break
        }
        guard i < n else { return nil }
        return firstWord(String(t[i..<min(n, i + 24)]))
    }

    private static func nearestNonControlFlow(_ stack: [BodyKind]) -> BodyKind {
        for kind in stack.reversed() where kind != .controlFlow {
            return kind
        }
        return .topLevel
    }

    private static func classify(_ fragment: String) -> BodyKind {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .closure }
        guard let first = firstSignificantWord(trimmed) else { return .closure }
        if let afterFirst = trimmed.range(of: first)?.upperBound,
           trimmed[afterFirst...].first(where: { $0 != " " && $0 != "\t" }) == ":" {
            return .closure
        }
        if first == "get" || first == "set" || first == "willSet" || first == "didSet" {
            return .declaration
        }
        if controlFlowKeywords.contains(first) { return .controlFlow }
        if typeKeywords.contains(first) { return .declaration }
        if first == "func" || first == "init" || first == "deinit" || first == "subscript" {
            return .declaration
        }
        if (first == "var" || first == "let") && !trimmed.contains("=") {
            return .declaration
        }
        return .closure
    }

    /// The fragment's first real word, after skipping leading `@attributes` and modifier keywords.
    private static func firstSignificantWord(_ fragment: String) -> String? {
        var rest = Substring(fragment)
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            if rest.first == "@" {
                var idx = rest.index(after: rest.startIndex)
                while idx < rest.endIndex, isIdentChar(rest[idx]) { idx = rest.index(after: idx) }
                if idx < rest.endIndex, rest[idx] == "(" {
                    var depth = 1
                    idx = rest.index(after: idx)
                    while idx < rest.endIndex, depth > 0 {
                        if rest[idx] == "(" { depth += 1 }
                        if rest[idx] == ")" { depth -= 1 }
                        idx = rest.index(after: idx)
                    }
                }
                rest = rest[idx...]
                continue
            }
            if let word = firstWord(String(rest)), modifierWords.contains(word) {
                rest = rest.dropFirst(word.count)
                continue
            }
            break
        }
        return firstWord(String(rest))
    }

    private static func firstWord(_ s: String) -> String? {
        var word = ""
        for c in s {
            if c.isLetter || c.isNumber || c == "_" {
                word.append(c)
            } else {
                break
            }
        }
        return word.isEmpty ? nil : word
    }

    private static func sanitizedFragment(_ t: [Character], _ isOpaque: [Bool], _ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        var out = [Character]()
        out.reserveCapacity(end - start)
        var i = start
        while i < end {
            out.append(isOpaque[i] ? " " : t[i])
            i += 1
        }
        return String(out)
    }

    private static func containsBrace(_ t: [Character], _ isOpaque: [Bool], _ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end {
            if !isOpaque[i], t[i] == "{" { return true }
            i += 1
        }
        return false
    }

    private static func lineOf(_ t: [Character], _ pos: Int) -> Int {
        1 + t[0..<pos].lazy.filter { $0 == "\n" }.count
    }

    private static func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func matchMacroKeyword(_ t: [Character], _ i: Int, _ n: Int, _ isOpaque: [Bool]) -> Int? {
        for keyword in ["expect", "require"] {
            let kchars = Array(keyword)
            let end = i + 1 + kchars.count
            guard end <= n, Array(t[(i + 1)..<end]) == kchars else { continue }
            if end < n, isIdentChar(t[end]) { continue }
            var j = end
            while j < n, t[j] == " " || t[j] == "\t" || t[j] == "\n" || t[j] == "\r" { j += 1 }
            if j < n, t[j] == "(" { return j }
        }
        return nil
    }

    private static func skipWSComments(_ t: [Character], _ isComment: [Bool], _ start: Int, _ n: Int) -> Int {
        var i = start
        while i < n {
            let c = t[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
                continue
            }
            if isComment[i] {
                i += 1
                continue
            }
            break
        }
        return i
    }

    private static func findMatching(
        _ t: [Character], _ openIdx: Int, _ openCh: Character, _ closeCh: Character, _ n: Int, _ isOpaque: [Bool]
    ) -> Int? {
        var depth = 0
        var i = openIdx
        while i < n {
            if isOpaque[i] {
                i += 1
                continue
            }
            if t[i] == openCh {
                depth += 1
            } else if t[i] == closeCh {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func matchesRun(_ t: [Character], _ i: Int, _ ch: Character, _ count: Int, _ n: Int) -> Bool {
        guard count > 0, i + count <= n else { return count == 0 }
        for k in 0..<count where t[i + k] != ch { return false }
        return true
    }

    private struct OpaqueMask {
        var isOpaque: [Bool]
        var isComment: [Bool]
    }

    /// One pass classifying every character as code, comment, or string text, scanning a string's own interpolation back out as ordinary code.
    private static func computeOpaqueMask(_ t: [Character]) -> OpaqueMask {
        let n = t.count
        var isOpaque = [Bool](repeating: false, count: n)
        var isComment = [Bool](repeating: false, count: n)

        enum Frame {
            case string(qlen: Int, hashes: Int)
            case interpolation(parenDepth: Int)
        }
        var frames: [Frame] = []
        var i = 0

        func markOpaque(_ start: Int, _ end: Int) {
            for x in start..<end { isOpaque[x] = true }
        }
        func markComment(_ start: Int, _ end: Int) {
            for x in start..<end {
                isOpaque[x] = true
                isComment[x] = true
            }
        }

        while i < n {
            if case .string(let qlen, let hashes) = frames.last {
                if hashes == 0, t[i] == "\\" {
                    if i + 1 < n, t[i + 1] == "(" {
                        markOpaque(i, i + 2)
                        frames.append(.interpolation(parenDepth: 0))
                        i += 2
                        continue
                    }
                    let end = min(i + 2, n)
                    markOpaque(i, end)
                    i = end
                    continue
                }
                if hashes > 0, t[i] == "\\" {
                    var k = i + 1
                    var hcount = 0
                    while k < n, t[k] == "#" {
                        hcount += 1
                        k += 1
                    }
                    if hcount == hashes, k < n, t[k] == "(" {
                        markOpaque(i, k + 1)
                        frames.append(.interpolation(parenDepth: 0))
                        i = k + 1
                        continue
                    }
                }
                if matchesRun(t, i, "\"", qlen, n) {
                    if hashes == 0 {
                        markOpaque(i, i + qlen)
                        frames.removeLast()
                        i += qlen
                        continue
                    } else if matchesRun(t, i + qlen, "#", hashes, n) {
                        markOpaque(i, i + qlen + hashes)
                        frames.removeLast()
                        i += qlen + hashes
                        continue
                    }
                }
                isOpaque[i] = true
                i += 1
                continue
            }

            if t[i] == "/", i + 1 < n, t[i + 1] == "/" {
                let start = i
                while i < n, t[i] != "\n" { i += 1 }
                markComment(start, i)
                continue
            }
            if t[i] == "/", i + 1 < n, t[i + 1] == "*" {
                let start = i
                var depth = 1
                i += 2
                while i < n, depth > 0 {
                    if i + 1 < n, t[i] == "/", t[i + 1] == "*" {
                        depth += 1
                        i += 2
                        continue
                    }
                    if i + 1 < n, t[i] == "*", t[i + 1] == "/" {
                        depth -= 1
                        i += 2
                        continue
                    }
                    i += 1
                }
                markComment(start, i)
                continue
            }
            if t[i] == "#" || t[i] == "\"" {
                var k = i
                var hashes = 0
                while k < n, t[k] == "#" {
                    hashes += 1
                    k += 1
                }
                if k < n, t[k] == "\"" {
                    let triple = k + 2 < n && t[k + 1] == "\"" && t[k + 2] == "\""
                    let qlen = triple ? 3 : 1
                    markOpaque(i, k + qlen)
                    frames.append(.string(qlen: qlen, hashes: hashes))
                    i = k + qlen
                    continue
                }
                i += 1
                continue
            }
            if case .interpolation(let depth) = frames.last {
                if t[i] == "(" {
                    frames[frames.count - 1] = .interpolation(parenDepth: depth + 1)
                    i += 1
                    continue
                }
                if t[i] == ")" {
                    if depth == 0 {
                        isOpaque[i] = true
                        frames.removeLast()
                    } else {
                        frames[frames.count - 1] = .interpolation(parenDepth: depth - 1)
                    }
                    i += 1
                    continue
                }
            }
            i += 1
        }
        return OpaqueMask(isOpaque: isOpaque, isComment: isComment)
    }
}
