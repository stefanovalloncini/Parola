import Foundation
import Testing
@testable import ParolaCore

@Suite struct SnapshotEntryScannerTests {
    private func entry(
        title: String = "Weekly sync",
        excerpt: String? = "We met on Monday.",
        tokens: [String] = ["met", "monday", "we"],
        offsets: [Int32] = [3, -1, 0],
        bodyHash: UInt64 = 14_695_981_039_346_656_037
    ) -> SnapshotEntry {
        SnapshotEntry(
            id: "20260101T000000-abc", title: title, excerpt: excerpt, bodyBytes: 4_096, bodyHash: bodyHash,
            tokens: tokens, counts: [1, 2, 3], offsets: offsets, boundaryOffsets: [0, 120, 250],
            boundaryCentiseconds: [0, 1_250, 4_000_000_000], fingerprint: "fp-1"
        )
    }

    @Test(arguments: [
        "Weekly sync",
        "Q&A / follow-ups",
        "She said \"hello\" \\ bye",
        "Line one\nline two\ttabbed",
        "Café, naïve, 東京, 🎙️",
        "",
        "a\rb",
        "\u{08}\u{0C}",
        "\u{FEFF}x",
        "\u{FEFF}",
        "e\u{301}",
    ])
    func scanningMatchesTheDecoder(title: String) throws {
        let original = entry(title: title, excerpt: title)
        let data = try JSONEncoder().encode(original)
        let scanned = try #require(SnapshotEntry(scanning: data))
        #expect(scanned == original)
        #expect(Array(scanned.title.utf8) == Array(original.title.utf8))
        #expect(Array(try #require(scanned.excerpt).utf8) == Array(title.utf8))
        #expect(try JSONDecoder().decode(SnapshotEntry.self, from: data) == original)
    }

    @Test func trickyCharactersKeepTheirBytesAnywhereInAString() throws {
        let tricky = ["\u{FEFF}", "e\u{301}", "\u{200B}", "\r", "\u{08}", "\u{0C}", "/", "\"", "\\", "é", "🎙️"]
        for character in tricky {
            for text in [character, character + "x", "x" + character, "x" + character + "y", character + character] {
                let original = entry(title: text, excerpt: text, tokens: [text])
                let data = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(SnapshotEntry.self, from: data)
                guard let scanned = SnapshotEntry(scanning: data) else { continue }
                #expect(Array(scanned.title.utf8) == Array(decoded.title.utf8), "title \(Array(text.unicodeScalars))")
                #expect(Array((scanned.excerpt ?? "").utf8) == Array((decoded.excerpt ?? "").utf8), "excerpt \(Array(text.unicodeScalars))")
                #expect(scanned.tokens.map { Array($0.utf8) } == decoded.tokens.map { Array($0.utf8) }, "tokens \(Array(text.unicodeScalars))")
            }
        }
    }

    @Test func absentAndNullExcerptsBothScan() throws {
        let original = entry(excerpt: nil)
        let data = try JSONEncoder().encode(original)
        #expect(SnapshotEntry(scanning: data) == original)
        let withNull = try #require(String(data: data, encoding: .utf8)).replacingOccurrences(of: "{", with: "{\"excerpt\":null,")
        #expect(SnapshotEntry(scanning: Data(withNull.utf8)) == original)
    }

    @Test func emptyArraysAndExtremesScan() throws {
        let original = SnapshotEntry(
            id: "x", title: "t", excerpt: nil, bodyBytes: 0, bodyHash: UInt64.max, tokens: [],
            counts: [], offsets: [Int32.min, Int32.max], boundaryOffsets: [], boundaryCentiseconds: [UInt32.max], fingerprint: ""
        )
        let data = try JSONEncoder().encode(original)
        #expect(SnapshotEntry(scanning: data) == original)
    }

    @Test func prettyPrintedFileScans() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let original = entry()
        #expect(SnapshotEntry(scanning: try encoder.encode(original)) == original)
    }

    @Test func unicodeEscapesAreLeftToTheDecoder() throws {
        let original = entry(title: "bell \u{07} ring")
        let data = try JSONEncoder().encode(original)
        #expect(SnapshotEntry(scanning: data) == nil)
        #expect(SnapshotEntry.decode(data) == original)
    }

    @Test func malformedFilesDoNotScan() throws {
        let good = try #require(String(data: try JSONEncoder().encode(entry()), encoding: .utf8))
        let bad = [
            String(good.dropLast()),
            good + "x",
            good.replacingOccurrences(of: "\"counts\":[1,2,3]", with: "\"counts\":[1,2,3.5]"),
            good.replacingOccurrences(of: "\"counts\":[1,2,3]", with: "\"counts\":[1,2,-3]"),
            good.replacingOccurrences(of: "\"counts\":[1,2,3]", with: "\"counts\":[1,2,4294967296]"),
            good.replacingOccurrences(of: "\"counts\":[1,2,3]", with: "\"counts\":[1,2,03]"),
            good.replacingOccurrences(of: "\"fingerprint\":\"fp-1\"", with: "\"fingerprint\":\"fp-1\",\"extra\":1"),
            good.replacingOccurrences(of: ",\"fingerprint\":\"fp-1\"", with: ""),
            good.replacingOccurrences(of: "\"title\"", with: "\"titel\""),
            "",
            "[]",
        ]
        for text in bad {
            #expect(SnapshotEntry(scanning: Data(text.utf8)) == nil, "\(text.prefix(80))")
            #expect(SnapshotEntry.decode(Data(text.utf8)) == (try? JSONDecoder().decode(SnapshotEntry.self, from: Data(text.utf8))))
        }
    }
}
