import Foundation
import Testing
@testable import ParolaCore

/// The per-form implementation the single alternation replaced, kept verbatim as the reference.
private enum PerFormOrthography {
    static let acuteForms = [
        "perché", "poiché", "affinché", "benché", "finché", "sicché", "giacché",
        "nonché", "anziché", "cosicché", "fuorché", "purché", "dopodiché",
        "macché", "dacché", "allorché", "acciocché", "sennonché",
        "granché", "checché", "ché",
    ]

    static let corrections: [(regex: NSRegularExpression, acute: String)] = acuteForms.compactMap { acute in
        guard let last = acute.last, last == "é" else { return nil }
        let grave = acute.dropLast() + "è"
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: String(grave)) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, acute)
    }

    static let truncations: [(regex: NSRegularExpression, replacement: String)] = {
        guard let po = try? NSRegularExpression(pattern: "\\bp[oò]\\b(?![\u{27}\u{2019}])") else { return [] }
        return [(po, "po'")]
    }()

    static func correct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mayHaveGrave = text.contains("è") || text.contains("È")
        let mayHaveTruncation = text.contains("po") || text.contains("pò")
        guard mayHaveGrave || mayHaveTruncation else { return text }
        var result = text
        if mayHaveGrave {
            for (regex, acute) in corrections {
                result = replaceMatches(of: regex, in: result, with: acute)
            }
        }
        if mayHaveTruncation {
            for (regex, replacement) in truncations {
                result = replaceMatches(of: regex, in: result, with: replacement)
            }
        }
        return result
    }

    static func replaceMatches(of regex: NSRegularExpression, in text: String, with acute: String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            let cased = caseMatched(acute, like: matched)
            result = (result as NSString).replacingCharacters(in: match.range, with: cased)
        }
        return result
    }

    static func caseMatched(_ replacement: String, like matched: String) -> String {
        if matched != matched.lowercased(), matched == matched.uppercased() {
            return replacement.uppercased()
        }
        if let first = matched.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}

@Suite("Italian orthography single-scan fold")
struct ItalianOrthographyFoldTests {
    private static func fixture() -> [String] {
        let graves = PerFormOrthography.acuteForms.map { String($0.dropLast()) + "è" }
        var cased: [String] = []
        for grave in graves {
            cased += [grave, grave.capitalized, grave.uppercased(), grave.prefix(1).uppercased() + grave.dropFirst()]
        }
        let others = [
            "caffè", "cioè", "Po", "po'", "po\u{2019}", "pò", "un po", "un pò", "tè", "è", "È",
            "perchèperchè", "l'perchè", "perchè-perchè", "per chè", "chèchè", "anzichè2", "_perchè",
            "Perchè?Perchè!", "«perchè»", "(finchè)", "benchè…", "PERCHè", "pErChÈ", "poiche",
        ]
        let words = cased + others
        var sentences = words
        var seed: UInt64 = 0x5eed
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let joins = [" ", ", ", "; ", ". ", "? ", "-", "'", " — ", "\n"]
        for _ in 0..<3000 {
            var sentence = ""
            for index in 0..<(3 + next(8)) {
                if index > 0 { sentence += joins[next(joins.count)] }
                sentence += words[next(words.count)]
            }
            sentences.append(sentence)
        }
        return sentences
    }

    @Test("one alternation rewrites every fixture line byte for byte like the per-form regexes")
    func foldMatchesPerFormPasses() {
        let fixture = Self.fixture()
        var changed = 0
        for line in fixture {
            let expected = PerFormOrthography.correct(line)
            #expect(Array(ItalianOrthography.correct(line).utf8) == Array(expected.utf8), "\(line)")
            if expected != line { changed += 1 }
        }
        #expect(changed > fixture.count / 2)
    }
}
