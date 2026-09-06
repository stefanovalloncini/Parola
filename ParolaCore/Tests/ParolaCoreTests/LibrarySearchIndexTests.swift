import Testing
import Foundation
import os
@testable import ParolaCore

private func eventually(
    timeoutMs: Int = 5000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<timeoutMs {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

@Suite("LibrarySearchIndex")
struct LibrarySearchIndexTests {
    private func makeTempIndex() -> (LibrarySearchIndex, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        return (LibrarySearchIndex(indexURL: url), url)
    }

    @Test("index then search returns the entry")
    func indexThenSearch() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Stand-up notes", text: "Discussed sprint planning and bug triage today.", createdAt: Date())
        let matches = await index.search("sprint")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("search returns empty for unknown query")
    func searchEmpty() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Stand-up", text: "Bug triage", createdAt: Date())
        let matches = await index.search("unknownword")
        #expect(matches.isEmpty)
    }

    @Test("removing an entry deindexes it")
    func removeDeindexes() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "Sprint planning", createdAt: Date())
        await index.index(id: "e2", title: "Other", text: "Sprint review", createdAt: Date())
        await index.remove("e1")
        let matches = await index.search("planning")
        #expect(matches.contains(where: { $0.entryID == "e1" }) == false)
        let stillMatches = await index.search("review")
        #expect(stillMatches.contains(where: { $0.entryID == "e2" }))
    }

    @Test("empty transcript does not crash")
    func emptyTranscript() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Empty", text: "", createdAt: Date())
        let matches = await index.search("empty")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("re-indexing replaces old tokens")
    func reindexReplaces() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "v1", text: "Sprint planning", createdAt: Date())
        await index.index(id: "e1", title: "v2", text: "Retro feedback", createdAt: Date())
        let oldMatches = await index.search("planning")
        #expect(oldMatches.contains(where: { $0.entryID == "e1" }) == false)
        let newMatches = await index.search("retro")
        #expect(newMatches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("snapshot persists across instances")
    func snapshotRoundTrip() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "Sprint planning", createdAt: Date())
        await index1.flush()
        let index2 = LibrarySearchIndex(indexURL: url)
        let matches = await index2.search("sprint")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("prefix match finds longer tokens")
    func prefixMatch() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Lecture", text: "transcription of the meeting", createdAt: Date())
        let matches = await index.search("transc")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("title tokens are indexed")
    func titleIndexed() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Quarterly review", text: "n/a", createdAt: Date())
        let matches = await index.search("quarterly")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("score ranks multi-token hits higher")
    func scoreRanksMultiHit() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Sprint planning", text: "sprint", createdAt: Date())
        await index.index(id: "e2", title: "Other", text: "sprint planning", createdAt: Date())
        let matches = await index.search("sprint planning")
        // Both match; e2's text has both tokens, e1's title has both. Either way matches must come back ranked.
        #expect(matches.count == 2)
        let first = try #require(matches.first)
        let last = try #require(matches.last)
        #expect(first.score >= last.score)
    }

    @Test("repeating a query token does not inflate the score")
    func repeatedQueryTokenScore() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint", createdAt: Date())
        let once = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        let twice = try #require(await index.search("sprint sprint").first(where: { $0.entryID == "e1" }))
        #expect(once.score == twice.score)
    }

    @Test("the match count sums every occurrence, the title's included")
    func matchCountSumsOccurrences() async throws {
        let (index, _) = makeTempIndex()
        await index.index(
            id: "e1",
            title: "Sprint notes",
            text: "The sprint began late and the sprint ended early.",
            createdAt: Date()
        )
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 3)
    }

    @Test("a single occurrence counts as one match")
    func matchCountCountsOnce() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "One sprint only.", createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 1)
    }

    @Test("the match count survives the snapshot round trip")
    func matchCountRoundTrips() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(
            id: "e1",
            title: "Notes",
            text: "Sprint one, sprint two, sprint three.",
            createdAt: Date()
        )
        await index1.flush()
        let index2 = LibrarySearchIndex(indexURL: url)
        let match = try #require(await index2.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 3)
    }

    @Test("a snapshot written before the counts existed is discarded and rebuilt")
    func snapshotBeforeCountsIsDiscarded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-v5-\(UUID().uuidString).json")
        let v5 = #"{"version":5,"entries":[{"id":"e1","title":"Notes","excerpt":"Sprint planning","#
            + #""tokens":["notes","planning","sprint"],"fingerprint":"f1"}]}"#
        try Data(v5.utf8).write(to: url)
        let index = LibrarySearchIndex(indexURL: url)
        #expect(await index.search("sprint").isEmpty)
        #expect(await index.needsRebuild(matching: ["e1": "f1"]))
        await index.rebuild(entries: [
            .init(id: "e1", title: "Notes", text: "Sprint planning and sprint retro", fingerprint: "f1")
        ])
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 2)
    }

    @Test("a snapshot written before the hit positions existed is discarded and rebuilt")
    func snapshotBeforePositionsIsDiscarded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-v6-\(UUID().uuidString).json")
        let v6 = #"{"version":6,"entries":[{"id":"e1","title":"Notes","excerpt":"Sprint planning",""#
            + #"tokens":["notes","planning","sprint"],"counts":[1,1,1],"fingerprint":"f1"}]}"#
        try Data(v6.utf8).write(to: url)
        let index = LibrarySearchIndex(indexURL: url)
        #expect(await index.search("sprint").isEmpty)
        #expect(await index.needsRebuild(matching: ["e1": "f1"]))
        await index.rebuild(entries: [
            .init(
                id: "e1",
                title: "Notes",
                text: "Sprint planning and sprint retro",
                boundaries: [.init(textOffset: 0, seconds: 0)],
                fingerprint: "f1"
            )
        ])
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 2)
    }

    @Test("the snapshot carries each entry's segment boundaries")
    func snapshotStoresSegmentBoundaries() async throws {
        let (index, url) = makeTempIndex()
        await index.index(
            id: "e1",
            title: "Notes",
            text: "Sprint planning today. Retro tomorrow.",
            boundaries: [
                .init(textOffset: 0, seconds: 0),
                .init(textOffset: 23, seconds: 12.399999618530273)
            ],
            createdAt: Date()
        )
        await index.flush()
        let raw = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(raw.contains(#""version":7"#))
        #expect(raw.contains(#""boundaryOffsets":[0,23]"#))
        #expect(raw.contains(#""boundaryCentiseconds":[0,1240]"#))
    }

    @Test("an entry whose counts went missing still counts its hit once")
    func missingCountsFallBackToOne() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "Sprint planning and sprint retro", createdAt: Date())
        await index1.flush()
        // Empty the counts out of the snapshot the actor just wrote, keeping its version and every other field.
        var snapshot = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var entries = try #require(snapshot["entries"] as? [[String: Any]])
        entries = entries.map { entry in
            var stripped = entry
            stripped["counts"] = [Int]()
            return stripped
        }
        snapshot["entries"] = entries
        try JSONSerialization.data(withJSONObject: snapshot).write(to: url)

        let index2 = LibrarySearchIndex(indexURL: url)
        let match = try #require(await index2.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 1)
    }

    @Test("match snippet includes highlight ranges around each hit")
    func snippetHighlights() async throws {
        let (index, _) = makeTempIndex()
        let body = "Quarterly review of sprint planning and sprint retro outcomes."
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let matches = await index.search("sprint")
        let match = try #require(matches.first(where: { $0.entryID == "e1" }))
        #expect(match.highlights.count >= 1)
        for highlight in match.highlights {
            let start = match.snippet.index(match.snippet.startIndex, offsetBy: highlight.start)
            let end = match.snippet.index(start, offsetBy: highlight.length)
            #expect(match.snippet[start..<end].lowercased() == "sprint")
        }
    }

    @Test("a snippet cut out of a longer line is marked at both ends")
    func snippetMarksWhereItWasCut() async throws {
        let (index, _) = makeTempIndex()
        let body = String(repeating: "ab ", count: 20) + "sprint" + String(repeating: " cd", count: 34)
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.hasPrefix("…"))
        #expect(match.snippet.hasSuffix("…"))
        for highlight in match.highlights {
            let start = match.snippet.index(match.snippet.startIndex, offsetBy: highlight.start)
            let end = match.snippet.index(start, offsetBy: highlight.length)
            #expect(match.snippet[start..<end].lowercased() == "sprint")
        }
    }

    @Test("a hit near the excerpt's cap is still marked as cut, since the line may continue past it")
    func snippetNearExcerptCapKeepsTrailingEllipsis() async throws {
        let (index, _) = makeTempIndex()
        let body = String(repeating: "ab ", count: 60) + "sprint" + String(repeating: " cd", count: 30)
        #expect(body.count > 200)
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.hasSuffix("…"))
    }

    @Test("a snippet that is the whole line carries no ellipsis")
    func wholeLineSnippetIsNotMarked() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint retro", createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(!match.snippet.contains("…"))
        #expect(match.snippet == "sprint retro")
    }

    @Test("a cut snippet starts and ends on whole words")
    func snippetCutsOnWordBoundaries() async throws {
        let (index, _) = makeTempIndex()
        let body = "Nella conferenza di apertura parliamo del lavoro ibrido e del lancio "
            + "di nuove abitudini con le macchine nuove del reparto"
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let match = try #require(await index.search("lancio").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.hasPrefix("…"))
        #expect(match.snippet.hasSuffix("…"))
        let cut = match.snippet.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        let range = try #require(body.range(of: cut))
        #expect(body[body.index(before: range.lowerBound)] == " ")
        #expect(body[range.upperBound] == " ")
    }

    @Test("the snippet's leading cut lands on a word even when the hit is close to it")
    func snippetLeadingCutStopsAtTheHit() async throws {
        let (index, _) = makeTempIndex()
        let body = String(repeating: "x", count: 60) + " sprint planning"
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet == "…sprint planning")
    }

    @Test("snippet surfaces the hit when text changes length when lowercased")
    func snippetNonASCIICaseFold() async throws {
        let (index, _) = makeTempIndex()
        // İ (U+0130) lowercases to "i̇" (i + combining dot), which is longer in UTF-8, so
        // `text.lowercased()` is longer than `text`. A snippet built from the lowercased copy's
        // indices then misaligns (or traps) against the original text.
        let body = String(repeating: "İ", count: 60) + " sprint planning notes"
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let matches = await index.search("sprint")
        let match = try #require(matches.first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.lowercased().contains("sprint"))
        for highlight in match.highlights {
            let start = match.snippet.index(match.snippet.startIndex, offsetBy: highlight.start)
            let end = match.snippet.index(start, offsetBy: highlight.length)
            #expect(match.snippet[start..<end].lowercased() == "sprint")
        }
    }

    @Test("flush persists pending debounced writes")
    func flushPersists() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "Sprint planning", createdAt: Date())
        await index1.flush()
        let exists = FileManager.default.fileExists(atPath: url.path)
        #expect(exists)
    }

    @Test("snapshot stores an excerpt, not the full text")
    func snapshotExcerptOnly() async throws {
        let (index, url) = makeTempIndex()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 10)
        let text = filler + "ZzyzxMarker closing remarks"
        await index.index(id: "e1", title: "Notes", text: text, createdAt: Date())
        await index.flush()

        let raw = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(!raw.contains("ZzyzxMarker"))
        #expect(raw.contains("zzyzxmarker"))

        let matches = await index.search("zzyzxmarker")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("tokens beyond the excerpt survive a reload")
    func tokensBeyondExcerptSurviveReload() async throws {
        let (index1, url) = makeTempIndex()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 10)
        await index1.index(id: "e1", title: "Notes", text: filler + "zzyzxmarker tail", createdAt: Date())
        await index1.flush()

        let index2 = LibrarySearchIndex(indexURL: url)
        let matches = await index2.search("zzyzxmarker")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
        let headMatches = await index2.search("lorem")
        let head = try #require(headMatches.first(where: { $0.entryID == "e1" }))
        #expect(head.snippet.lowercased().contains("lorem"))
    }

    @Test("removing one entry leaves shared tokens for the other")
    func removalKeepsSharedTokens() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "First", text: "sprint planning alpha", createdAt: Date())
        await index.index(id: "e2", title: "Second", text: "sprint review alpha", createdAt: Date())
        await index.remove("e1")

        let shared = await index.search("alpha")
        #expect(shared.map(\.entryID) == ["e2"])
        let sprint = await index.search("sprint")
        #expect(sprint.map(\.entryID) == ["e2"])
        let gone = await index.search("planning")
        #expect(gone.isEmpty)
    }

    @Test("auxiliary text is searchable but stays out of the snippet")
    func auxiliarySearchable() async throws {
        let (index, _) = makeTempIndex()
        await index.index(
            id: "e1",
            title: "Notes",
            text: "Discussed sprint planning today.",
            auxiliaryText: "Renewal deadlines are slipping\nMarta",
            createdAt: Date()
        )
        let matches = await index.search("renewal")
        let match = try #require(matches.first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.lowercased().contains("renewal") == false)
        #expect(await index.search("marta").contains(where: { $0.entryID == "e1" }))
    }

    @Test("re-indexing replaces auxiliary tokens too")
    func reindexReplacesAuxiliary() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint", auxiliaryText: "kanban", createdAt: Date())
        await index.index(id: "e1", title: "Notes", text: "sprint", auxiliaryText: "roadmap", createdAt: Date())
        #expect(await index.search("kanban").isEmpty)
        #expect(await index.search("roadmap").contains(where: { $0.entryID == "e1" }))
    }

    @Test("rebuild indexes each entry's auxiliary text")
    func rebuildCarriesAuxiliary() async throws {
        let (index, _) = makeTempIndex()
        await index.rebuild(entries: [
            .init(id: "e1", title: "Notes", text: "sprint planning", auxiliaryText: "kanban board")
        ])
        #expect(await index.search("kanban").contains(where: { $0.entryID == "e1" }))
    }

    @Test("a version-2 snapshot is discarded as stale")
    func v2SnapshotDiscarded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        let v2 = """
        {"version":2,"entries":{"e1":{"title":"Old","excerpt":"sprint planning","tokens":["sprint","planning"]}}}
        """
        try Data(v2.utf8).write(to: url)
        let index = LibrarySearchIndex(indexURL: url)
        #expect(await index.needsRebuild(matching: [:]))
        #expect(await index.search("sprint").isEmpty)
    }

    @Test("a version-3 snapshot is discarded as stale")
    func v3SnapshotDiscarded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        let v3 = """
        {"version":3,"entries":{"e1":{"title":"Old","excerpt":"sprint planning","tokens":["planning","sprint"]}}}
        """
        try Data(v3.utf8).write(to: url)
        let index = LibrarySearchIndex(indexURL: url)
        #expect(await index.needsRebuild(matching: [:]))
        #expect(await index.search("sprint").isEmpty)
    }

    @Test("an incrementally updated index matches a from-scratch rebuild")
    func incrementalMatchesRebuild() async throws {
        let final: [LibrarySearchIndex.RebuildEntry] = [
            .init(id: "e1", title: "Stand-up", text: "sprint planning and bug triage", auxiliaryText: "Marta"),
            .init(id: "e2", title: "Retro v2", text: "retro feedback on the release", auxiliaryText: "kanban"),
            .init(id: "e4", title: "Weekly", text: "alpha sprint review notes", auxiliaryText: "")
        ]

        let (incremental, url) = makeTempIndex()
        await incremental.index(id: "e1", title: "Stand-up", text: "sprint planning and bug triage", auxiliaryText: "Marta", createdAt: Date())
        await incremental.index(id: "e2", title: "Retro v1", text: "old placeholder text", auxiliaryText: "roadmap", createdAt: Date())
        await incremental.index(id: "e3", title: "Doomed", text: "zzyzxmarker filler", createdAt: Date())
        await incremental.index(id: "e4", title: "Weekly", text: "alpha sprint review notes", createdAt: Date())
        await incremental.index(id: "e2", title: "Retro v2", text: "retro feedback on the release", auxiliaryText: "kanban", createdAt: Date())
        await incremental.remove("e3")
        await incremental.flush()

        let (scratch, _) = makeTempIndex()
        await scratch.rebuild(entries: final)

        let reloaded = LibrarySearchIndex(indexURL: url)
        let queries = ["sprint", "retro", "alpha", "kanban", "marta", "roadmap", "zzyzxmarker", "notes", "spr"]
        for query in queries {
            let a = await keyed(incremental.search(query))
            let b = await keyed(scratch.search(query))
            let c = await keyed(reloaded.search(query))
            #expect(a == b, "query \(query)")
            #expect(a == c, "query \(query)")
        }
    }

    private func keyed(_ matches: [LibrarySearchIndex.Match]) -> [String: LibrarySearchIndex.Match] {
        Dictionary(uniqueKeysWithValues: matches.map { ($0.entryID, $0) })
    }

    @Test("a save re-encodes only the entries that changed")
    func saveEncodesOnlyChangedEntries() async throws {
        let (index, _) = makeTempIndex()
        for i in 1...3 {
            await index.index(id: "e\(i)", title: "Entry \(i)", text: "sprint planning \(i)", createdAt: Date())
        }
        await index.flush()
        let afterFirstSave = await index.entriesEncoded
        #expect(afterFirstSave == 3)

        await index.flush()
        #expect(await index.entriesEncoded == afterFirstSave)

        await index.index(id: "e2", title: "Entry 2", text: "retro feedback", createdAt: Date())
        await index.flush()
        #expect(await index.entriesEncoded == afterFirstSave + 1)
    }

    @Test("a cold-loaded entry is encoded once and then reused")
    func coldLoadEncodesEachEntryOnce() async throws {
        let (index1, url) = makeTempIndex()
        for i in 1...3 {
            await index1.index(id: "e\(i)", title: "Entry \(i)", text: "sprint planning \(i)", createdAt: Date())
        }
        await index1.flush()

        let index2 = LibrarySearchIndex(indexURL: url)
        await index2.index(id: "e2", title: "Entry 2", text: "retro feedback", createdAt: Date())
        await index2.flush()
        #expect(await index2.entriesEncoded == 3)

        await index2.index(id: "e1", title: "Entry 1", text: "alpha notes", createdAt: Date())
        await index2.flush()
        #expect(await index2.entriesEncoded == 4)
    }

    @Test("flushing an unchanged index writes nothing")
    func cleanFlushWritesNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let index = LibrarySearchIndex(indexURL: url, saveDebounce: .seconds(60), clock: ContinuousClock()) { data, target in
            writes.withLock { $0 += 1 }
            try data.write(to: target, options: .atomic)
        }
        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        await index.flush()
        #expect(writes.withLock { $0 } == 1)

        await index.flush()
        await index.flush()
        #expect(writes.withLock { $0 } == 1)
    }

    @Test("a superseded snapshot write never lands")
    func supersededWriteDropped() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        let gate = DispatchSemaphore(value: 0)
        let written = OSAllocatedUnfairLock(initialState: 0)
        let index = LibrarySearchIndex(indexURL: url, saveDebounce: .seconds(60), clock: ContinuousClock()) { data, target in
            let isFirst = written.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if isFirst { gate.wait() }
            try data.write(to: target, options: .atomic)
        }

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        let first = Task { await index.flush() }
        #expect(await eventually { written.withLock { $0 } > 0 })

        await index.index(id: "e2", title: "Two", text: "retro feedback", createdAt: Date())
        let second = Task { await index.flush() }
        #expect(await eventually { await index.snapshotGeneration >= 2 })
        await index.index(id: "e3", title: "Three", text: "alpha review", createdAt: Date())
        let third = Task { await index.flush() }
        #expect(await eventually { await index.snapshotGeneration >= 3 })

        gate.signal()
        await first.value
        await second.value
        await third.value

        #expect(written.withLock { $0 } == 2)
        let raw = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(raw.contains("\"e2\""))
        #expect(raw.contains("\"e3\""))
    }

    @Test("a snapshot write that fails leaves the index pending, not clean")
    func failedWriteStaysPending() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let index = LibrarySearchIndex(indexURL: url, saveDebounce: .seconds(60), clock: ContinuousClock()) { data, target in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            guard attempt > 1 else { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: target, options: .atomic)
        }

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        await index.flush()
        #expect(attempts.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        await index.flush()
        #expect(attempts.withLock { $0 } == 2)
        let raw = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(raw.contains("\"e1\""))
    }

    @Test("a failed write reschedules itself without another mutation")
    func failedWriteReschedules() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-search-test-\(UUID().uuidString).json")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let index = LibrarySearchIndex(indexURL: url, saveDebounce: .milliseconds(1), clock: ContinuousClock()) { data, target in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            guard attempt > 1 else { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: target, options: .atomic)
        }

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })
    }

    @Test("a missing snapshot asks for a rebuild")
    func missingSnapshotNeedsRebuild() async throws {
        let (index, _) = makeTempIndex()
        #expect(await index.needsRebuild(matching: [:]))
    }

    @Test("indexing on a cold instance does not clobber the loaded snapshot")
    func coldMutationPreservesSnapshot() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Old", text: "sprint planning", createdAt: Date())
        await index1.flush()

        let index2 = LibrarySearchIndex(indexURL: url)
        await index2.index(id: "e2", title: "New", text: "retro feedback", createdAt: Date())
        let old = await index2.search("sprint")
        #expect(old.contains(where: { $0.entryID == "e1" }))
        let new = await index2.search("retro")
        #expect(new.contains(where: { $0.entryID == "e2" }))
    }
}
