import Testing
import Foundation
@testable import ParolaCore

@Suite("LibrarySearchIndex result equality")
struct LibrarySearchEqualityTests {
    private static let filler = String(repeating: "lorem ipsum dolor sit amet consectetur ", count: 12)

    private static let corpus: [(id: String, title: String, text: String, boundaries: [LibrarySearchIndex.SegmentBoundary])] = [
        ("a1", "Café résumé", "Naïve café owners discussed the résumé of Zoë. " + filler + "Sprint planning, then budget review; the budget was fine.", [
            .init(textOffset: 0, seconds: 0), .init(textOffset: 48, seconds: 3.5), .init(textOffset: 520, seconds: 41.25),
        ]),
        ("a2", "Riunione di pianificazione", "Oggi abbiamo parlato della pianificazione dello sprint e del budget. È andata bene! Perché no?", [
            .init(textOffset: 0, seconds: 1), .init(textOffset: 50, seconds: 9),
        ]),
        ("a3", "Besprechung", "Die Straße war gesperrt, Größe spielt keine Rolle. Sprint-Planung und Budget: später.", []),
        ("a4", "会议", "我们讨论了预算和计划。Sprint 计划 next week, 预算 approved.", [.init(textOffset: 0, seconds: 0)]),
        ("a5", "Punctuation", "\"Budget,\" he said -- (really?) -- budget... budget! " + filler + filler + "plan plan planning planned", []),
        ("a6", "Short", "budget", []),
        ("a7", "Plan", "   ", []),
        ("a8", "Multi\nline", "First line about sprint.\n\nSecond   paragraph\tabout the sprint review and planning.", [
            .init(textOffset: 0, seconds: 0), .init(textOffset: 26, seconds: 12),
        ]),
    ]

    private static let queries = [
        "sprint", "sprint planning", "plan", "pla", "budget", "bud", "café", "cafe", "résumé", "naïve",
        "pianificazione", "pian", "straße", "größe", "预算", "计划", "Zoë", "planning budget", "paragraph about",
        "nomatchatall", "x", "second paragraph", "really", "lorem",
    ]

    private func describe(_ matches: [LibrarySearchIndex.Match]) -> [String] {
        matches.sorted { ($1.score, $0.entryID) < ($0.score, $1.entryID) }.map { match in
            let hit = match.firstHit.map { "\($0.seconds)/\($0.segmentIndex)/\($0.textOffset)" } ?? "-"
            let marks = match.highlights.map { "\($0.start)+\($0.length)" }.joined(separator: ",")
            return "\(match.entryID)|\(match.score)|\(match.matchCount)|\(hit)|\(marks)|\(match.snippet)"
        }
    }

    private func results(from index: LibrarySearchIndex) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for query in Self.queries {
            let full = await index.search(query)
            let lean = await index.search(query, snippets: false)
            let filled = await index.withSnippets(lean, query: query)
            #expect(describe(full) == describe(filled), "query \(query)")
            out[query] = describe(full)
        }
        return out
    }

    private func populate(_ index: LibrarySearchIndex) async {
        for entry in Self.corpus {
            await index.index(
                id: entry.id, title: entry.title, text: entry.text,
                auxiliaryText: "Summary about budgets", boundaries: entry.boundaries, createdAt: Date()
            )
        }
    }

    @Test("a live index, a reloaded one and a rebuilt one answer alike")
    func liveReloadedRebuilt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-equality-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = LibrarySearchIndex(indexDirectory: url)
        await populate(live)
        let liveResults = await results(from: live)

        await live.flush()
        let reloaded = LibrarySearchIndex(indexDirectory: url)
        let reloadedResults = await results(from: reloaded)
        #expect(reloadedResults == liveResults)

        let rebuilt = LibrarySearchIndex(indexDirectory: url.appendingPathExtension("rebuilt"))
        defer { try? FileManager.default.removeItem(at: url.appendingPathExtension("rebuilt")) }
        await rebuilt.rebuild(entries: Self.corpus.map {
            .init(id: $0.id, title: $0.title, text: $0.text, auxiliaryText: "Summary about budgets", boundaries: $0.boundaries)
        })
        #expect(await results(from: rebuilt) == liveResults)

        let reader = LibrarySearchIndex(readingSnapshotIn: url)
        #expect(await results(from: reader) == liveResults)

        let actual = Self.queries.flatMap { query in ["# \(query)"] + (liveResults[query] ?? []) }.joined(separator: "\n")
        #expect(actual == searchEqualityGolden)
    }
}
