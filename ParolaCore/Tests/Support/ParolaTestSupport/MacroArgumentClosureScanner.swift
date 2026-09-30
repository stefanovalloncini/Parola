import Foundation

/// Finds a closure literal sitting inside an `#expect`/`#require` argument list, reached through
/// `await` — the shape that collided under Swift 6.4 (two such closures in one wrapper closure can
/// share a symbol, so the later one silently runs the first one's body). A trailing closure, as in
/// `#expect(throws: E.self) { … }`, sits after the argument list's own close paren and never matches.
public enum MacroArgumentClosureScanner {
    public struct Violation: Sendable, Equatable {
        public let line: Int
        public let snippet: String
    }

    public static func violations(in source: String) -> [Violation] {
        let t = Array(source)
        let n = t.count
        var results: [Violation] = []
        var i = 0
        while i < n {
            if let skip = opaqueSkip(t, i, n) {
                i = skip
                continue
            }
            if t[i] == "#", let openParen = matchMacroKeyword(t, i, n) {
                if let closeParen = findMatching(t, openParen, "(", ")", n) {
                    let arg0End = firstTopLevelComma(t, openParen + 1, closeParen) ?? closeParen
                    if let violation = findAwaitClosure(t, openParen + 1, arg0End) {
                        results.append(violation)
                    }
                    i = closeParen + 1
                    continue
                }
            }
            i += 1
        }
        return results
    }

    private static let awaitChars: [Character] = Array("await")

    private static func findAwaitClosure(_ t: [Character], _ start: Int, _ end: Int) -> Violation? {
        var i = start
        while i < end {
            if let skip = opaqueSkip(t, i, end) {
                i = skip
                continue
            }
            if i + 5 <= end, Array(t[i..<(i + 5)]) == awaitChars {
                let beforeOK = i == start || !isIdentChar(t[i - 1])
                let afterOK = i + 5 >= end || !isIdentChar(t[i + 5])
                if beforeOK, afterOK {
                    var j = skipWSComments(t, i + 5, end)
                    if let identEnd = matchIdentifierPath(t, j, end) {
                        j = skipWSComments(t, identEnd, end)
                        if j < end, t[j] == "(" {
                            if let close = findMatching(t, j, "(", ")", end) {
                                j = skipWSComments(t, close + 1, end)
                            } else {
                                i += 5
                                continue
                            }
                        }
                        if j < end, t[j] == "{" {
                            let line = 1 + t[0..<i].lazy.filter { $0 == "\n" }.count
                            let snippetEnd = min(end, i + 70)
                            return Violation(line: line, snippet: String(t[i..<snippetEnd]))
                        }
                    }
                }
                i += 5
                continue
            }
            i += 1
        }
        return nil
    }

    private static func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func matchIdentifierPath(_ t: [Character], _ start: Int, _ end: Int) -> Int? {
        guard start < end, t[start].isLetter || t[start] == "_" else { return nil }
        var i = start
        while i < end, isIdentChar(t[i]) { i += 1 }
        while true {
            var j = i
            while j < end, t[j] == " " || t[j] == "\t" { j += 1 }
            guard j < end, t[j] == "." else { break }
            j += 1
            while j < end, t[j] == " " || t[j] == "\t" { j += 1 }
            guard j < end, t[j].isLetter || t[j] == "_" else { break }
            var k = j
            while k < end, isIdentChar(t[k]) { k += 1 }
            i = k
        }
        return i
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

    private static func firstTopLevelComma(_ t: [Character], _ start: Int, _ end: Int) -> Int? {
        var depth = 0
        var i = start
        while i < end {
            if let skip = opaqueSkip(t, i, end) {
                i = skip
                continue
            }
            let c = t[i]
            if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                depth -= 1
            } else if c == "," && depth == 0 {
                return i
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
