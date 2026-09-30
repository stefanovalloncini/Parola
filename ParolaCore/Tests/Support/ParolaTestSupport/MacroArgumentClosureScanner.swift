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
        ",", "+", "-", "*", "/", "%", "=", "<", ">", "?", ":", "(", "[", ".", "&", "|", "!", "~", "^",
    ]
    private static let continuationWords: Set<String> = [
        "as", "in", "where", "return", "throws", "rethrows", "async", "try", "await", "else",
        "is", "case", "default", "some", "any",
    ]

    public static func violations(in source: String) -> [Violation] {
        let t = Array(source)
        let n = t.count
        var results: [Violation] = []
        var stack: [BodyKind] = [.topLevel]
        var statementStart = 0
        var nonBraceDepth = 0
        var lastNonSpaceChar: Character?
        var i = 0
        while i < n {
            if let skip = opaqueSkip(t, i, n) {
                lastNonSpaceChar = t[skip - 1]
                i = skip
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
                        || lastWord(t, i).map(continuationWords.contains) ?? false
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
                let fragment = sanitizedFragment(t, statementStart, i)
                stack.append(classify(fragment))
                i += 1
                statementStart = i
                nonBraceDepth = 0
                lastNonSpaceChar = nil
                continue
            }
            if c == "}" {
                if stack.count > 1 { stack.removeLast() }
                i += 1
                statementStart = i
                nonBraceDepth = 0
                lastNonSpaceChar = nil
                continue
            }
            if c == "#", let openParen = matchMacroKeyword(t, i, n) {
                let macroStart = i
                if let closeParen = findMatching(t, openParen, "(", ")", n) {
                    if nearestNonControlFlow(stack) == .closure {
                        let hasBraceInArgs = containsBrace(t, openParen + 1, closeParen)
                        let trailingStart = skipWSComments(t, closeParen + 1, n)
                        let hasTrailingClosure = trailingStart < n && t[trailingStart] == "{"
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

    private static func lastWord(_ t: [Character], _ before: Int) -> String? {
        var j = before
        while j > 0, t[j - 1] == " " || t[j - 1] == "\t" { j -= 1 }
        var k = j
        while k > 0, isIdentChar(t[k - 1]) { k -= 1 }
        guard k < j else { return nil }
        return String(t[k..<j])
    }

    private static func nearestNonControlFlow(_ stack: [BodyKind]) -> BodyKind {
        for kind in stack.reversed() where kind != .controlFlow {
            return kind
        }
        return .topLevel
    }

    private static let controlFlowKeywords: Set<String> = [
        "if", "else", "for", "while", "switch", "do", "catch", "repeat", "guard", "defer",
    ]
    private static let typeKeywords: Set<String> = [
        "struct", "class", "enum", "extension", "protocol", "actor",
    ]

    private static func classify(_ fragment: String) -> BodyKind {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .closure }
        if trimmed == "get" || trimmed == "set" || trimmed == "willSet" || trimmed == "didSet"
            || trimmed.hasPrefix("willSet(") || trimmed.hasPrefix("didSet(") {
            return .declaration
        }
        if let first = firstWord(trimmed), controlFlowKeywords.contains(first) {
            return .controlFlow
        }
        if let first = firstWord(trimmed), typeKeywords.contains(first) {
            return .declaration
        }
        if containsStandaloneWord(trimmed, "func", excludeDotPrefix: true)
            || containsStandaloneWord(trimmed, "init", excludeDotPrefix: true)
            || containsStandaloneWord(trimmed, "deinit", excludeDotPrefix: true)
            || containsStandaloneWord(trimmed, "subscript", excludeDotPrefix: true) {
            return .declaration
        }
        if !trimmed.contains("=")
            && (containsStandaloneWord(trimmed, "var", excludeDotPrefix: false)
                || containsStandaloneWord(trimmed, "let", excludeDotPrefix: false)) {
            return .declaration
        }
        return .closure
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

    private static func containsStandaloneWord(_ s: String, _ word: String, excludeDotPrefix: Bool) -> Bool {
        let chars = Array(s)
        let wordChars = Array(word)
        let wlen = wordChars.count
        var i = 0
        while i + wlen <= chars.count {
            if Array(chars[i..<(i + wlen)]) == wordChars {
                let beforeIsIdent = i > 0 && isIdentChar(chars[i - 1])
                let beforeIsDot = i > 0 && chars[i - 1] == "."
                let afterIsIdent = i + wlen < chars.count && isIdentChar(chars[i + wlen])
                if !beforeIsIdent, !afterIsIdent, !(excludeDotPrefix && beforeIsDot) {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    private static func sanitizedFragment(_ t: [Character], _ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        var out = [Character]()
        var i = start
        while i < end {
            if let skip = opaqueSkip(t, i, end) {
                out.append(" ")
                i = skip
                continue
            }
            out.append(t[i])
            i += 1
        }
        return String(out)
    }

    private static func containsBrace(_ t: [Character], _ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end {
            if let skip = opaqueSkip(t, i, end) {
                i = skip
                continue
            }
            if t[i] == "{" { return true }
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

    private static func matchMacroKeyword(_ t: [Character], _ i: Int, _ n: Int) -> Int? {
        for keyword in ["expect", "require"] {
            let kchars = Array(keyword)
            let end = i + 1 + kchars.count
            guard end <= n, Array(t[(i + 1)..<end]) == kchars else { continue }
            if end < n, isIdentChar(t[end]) { continue }
            let j = skipWSComments(t, end, n)
            if j < n, t[j] == "(" { return j }
        }
        return nil
    }

    private static func skipWSComments(_ t: [Character], _ start: Int, _ n: Int) -> Int {
        var i = start
        while i < n {
            if t[i] == " " || t[i] == "\t" || t[i] == "\n" || t[i] == "\r" {
                i += 1
                continue
            }
            if t[i] == "/", let skip = opaqueSkip(t, i, n) {
                i = skip
                continue
            }
            break
        }
        return i
    }

    private static func findMatching(_ t: [Character], _ openIdx: Int, _ openCh: Character, _ closeCh: Character, _ n: Int) -> Int? {
        var depth = 0
        var i = openIdx
        while i < n {
            if let skip = opaqueSkip(t, i, n) {
                i = skip
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

    /// Returns `nil`, meaning "not a comment or string", when `i` starts neither.
    private static func opaqueSkip(_ t: [Character], _ i: Int, _ n: Int) -> Int? {
        let c = t[i]
        if c == "/", i + 1 < n, t[i + 1] == "/" {
            var j = i
            while j < n, t[j] != "\n" { j += 1 }
            return j
        }
        if c == "/", i + 1 < n, t[i + 1] == "*" {
            var depth = 1
            var j = i + 2
            while j < n, depth > 0 {
                if j + 1 < n, t[j] == "/", t[j + 1] == "*" {
                    depth += 1
                    j += 2
                    continue
                }
                if j + 1 < n, t[j] == "*", t[j + 1] == "/" {
                    depth -= 1
                    j += 2
                    continue
                }
                j += 1
            }
            return j
        }
        if c == "#" || c == "\"" {
            var k = i
            var hashes = 0
            while k < n, t[k] == "#" {
                hashes += 1
                k += 1
            }
            guard k < n, t[k] == "\"" else { return nil }
            let triple = k + 2 < n && t[k + 1] == "\"" && t[k + 2] == "\""
            let qlen = triple ? 3 : 1
            var j = k + qlen
            while j < n {
                if hashes == 0, qlen == 1, t[j] == "\\" {
                    j += 2
                    continue
                }
                if matchesRun(t, j, "\"", qlen, n) {
                    if hashes == 0 { return j + qlen }
                    if matchesRun(t, j + qlen, "#", hashes, n) { return j + qlen + hashes }
                    j += 1
                    continue
                }
                j += 1
            }
            return n
        }
        return nil
    }

    private static func matchesRun(_ t: [Character], _ i: Int, _ ch: Character, _ count: Int, _ n: Int) -> Bool {
        guard count > 0, i + count <= n else { return count == 0 }
        for k in 0..<count where t[i + k] != ch { return false }
        return true
    }
}
