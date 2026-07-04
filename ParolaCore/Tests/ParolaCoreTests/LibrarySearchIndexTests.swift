import Testing
import Foundation
@testable import ParolaCore

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
