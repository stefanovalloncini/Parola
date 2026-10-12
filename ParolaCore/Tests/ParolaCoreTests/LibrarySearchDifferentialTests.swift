import Testing
import Foundation
@testable import ParolaCore

@Suite("LibrarySearchIndex against a brute-force model")
struct LibrarySearchDifferentialTests {
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private struct Row {
        var title: String
        var text: String
        var aux: String
        var boundaries: [LibrarySearchIndex.SegmentBoundary]
        var tokens: [String: (count: Int, offset: Int)]
    }

    private struct Expected: Equatable {
        let score: Int
        let matchCount: Int
        let hit: String
    }

    private static let vocabulary = [
        "a", "i", "plan", "planning", "planned", "plant", "budget", "budgets", "bud", "sprint", "sprints", "spring",
        "review", "reviews", "zeta", "zebra", "zen", "alpha", "alphabet", "beta", "gamma", "delta", "delay", "del",
        "meeting", "meet", "meets", "x1", "x12", "x123", "caffe", "cafe", "riunione", "riuni", "progetto", "pro",
    ]

    private static func words(_ text: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var offset = 0
        for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
            if piece.count > 1 { out.append((String(piece), offset)) }
            offset += piece.count + 1
        }
        return out
    }

    private static func tokens(title: String, text: String, aux: String) -> [String: (count: Int, offset: Int)] {
        var table: [String: (count: Int, offset: Int)] = [:]
        for (word, _) in words(title) { table[word, default: (0, -1)].count += 1 }
        for (word, offset) in words(text) {
            var tally = table[word, default: (0, -1)]
            tally.count += 1
            if tally.offset == -1 { tally.offset = offset }
            table[word] = tally
        }
        for (word, _) in words(aux) { table[word, default: (0, -1)].count += 1 }
        return table
    }

    private static func sentence(_ rng: inout SplitMix, length: Int) -> String {
        (0..<length).map { _ in vocabulary[Int(rng.next() % UInt64(vocabulary.count))] }.joined(separator: " ")
    }

    private static func boundaries(for text: String, _ rng: inout SplitMix) -> [LibrarySearchIndex.SegmentBoundary] {
        var offsets = [0]
        var offset = 0
        for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
            offset += piece.count + 1
            if offset < text.count, rng.next() % 5 == 0 { offsets.append(offset) }
        }
        return offsets.enumerated().map { .init(textOffset: $1, seconds: Double($0) * 2.25) }
    }

    private static func expected(for query: String, in rows: [String: Row]) -> [String: Expected] {
        let queryTokens = Set(words(query).map(\.0))
        var out: [String: Expected] = [:]
        for (id, row) in rows {
            var score = 0
            var count = 0
            var earliest = Int.max
            for queryToken in queryTokens {
                for (token, tally) in row.tokens where token.hasPrefix(queryToken) {
                    score += 1
                    count += max(1, tally.count)
                    if tally.offset >= 0 { earliest = min(earliest, tally.offset) }
                }
            }
            guard score > 0 else { continue }
            var hit = "-"
            if earliest != Int.max, !row.boundaries.isEmpty {
                let index = max(0, (row.boundaries.lastIndex { $0.textOffset <= earliest } ?? 0))
                hit = "\(Int((row.boundaries[index].seconds * 100).rounded()))/\(index)/\(earliest)"
            }
            out[id] = Expected(score: score, matchCount: count, hit: hit)
        }
        return out
    }

    private static func actual(_ matches: [LibrarySearchIndex.Match]) -> [String: Expected] {
        Dictionary(uniqueKeysWithValues: matches.map { match in
            let hit = match.firstHit.map { "\(Int(($0.seconds * 100).rounded()))/\($0.segmentIndex)/\($0.textOffset)" } ?? "-"
            return (match.entryID, Expected(score: match.score, matchCount: match.matchCount, hit: hit))
        })
    }

    private func check(_ index: LibrarySearchIndex, _ rows: [String: Row], _ rng: inout SplitMix, _ label: String) async {
        var queries = (0..<6).map { _ in Self.sentence(&rng, length: Int(1 + rng.next() % 2)) }
        queries += (0..<6).map { _ in
            let word = Self.vocabulary[Int(rng.next() % UInt64(Self.vocabulary.count))]
            return String(word.prefix(Int(2 + rng.next() % 3)))
        }
        queries.append("nomatchhere")
        for query in queries {
            let matches = await index.search(query, snippets: false)
            #expect(Self.actual(matches) == Self.expected(for: query, in: rows), "\(label): \(query)")
            #expect(matches.map(\.score) == matches.map(\.score).sorted(by: >), "\(label): order \(query)")
        }
    }

    @Test("random add, remove, reindex and auxiliary swaps answer like the model, live and after a reload", arguments: [1, 2, 3, 4, 5, 6])
    func randomSequences(seed: Int) async throws {
        var rng = SplitMix(state: UInt64(seed) &* 7919)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        var index = LibrarySearchIndex(indexDirectory: url)
        var rows: [String: Row] = [:]
        let ids = (0..<14).map { "entry-\($0)" }

        for step in 0..<70 {
            let id = ids[Int(rng.next() % UInt64(ids.count))]
            switch rng.next() % 6 {
            case 0:
                await index.remove(id)
                rows[id] = nil
            case 1:
                guard var row = rows[id] else { continue }
                let old = row.aux
                let new = Self.sentence(&rng, length: Int(rng.next() % 4))
                let replaced = await index.replaceAuxiliaryText(old, with: new, for: id)
                #expect(replaced)
                for (word, _) in Self.words(old) { row.tokens[word]?.count -= 1 }
                for (word, _) in Self.words(new) { row.tokens[word, default: (0, -1)].count += 1 }
                row.tokens = row.tokens.filter { $0.value.count > 0 || $0.value.offset != -1 }
                row.aux = new
                rows[id] = row
            case 2 where step % 2 == 0:
                await index.flush()
                index = LibrarySearchIndex(indexDirectory: url)
                await check(index, rows, &rng, "seed \(seed) step \(step) reloaded")
            default:
                let title = Self.sentence(&rng, length: Int(rng.next() % 3))
                let text = Self.sentence(&rng, length: Int(rng.next() % 40))
                let aux = Self.sentence(&rng, length: Int(rng.next() % 5))
                let boundaries = Self.boundaries(for: text, &rng)
                await index.index(id: id, title: title, text: text, auxiliaryText: aux, boundaries: boundaries, createdAt: Date())
                rows[id] = Row(title: title, text: text, aux: aux, boundaries: boundaries, tokens: Self.tokens(title: title, text: text, aux: aux))
            }
            if step % 7 == 0 { await check(index, rows, &rng, "seed \(seed) step \(step)") }
        }
        await check(index, rows, &rng, "seed \(seed) end")
    }
}
