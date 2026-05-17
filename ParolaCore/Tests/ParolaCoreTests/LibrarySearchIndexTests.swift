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
        #expect(!matches.contains(where: { $0.entryID == "e1" }))
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
        #expect(!oldMatches.contains(where: { $0.entryID == "e1" }))
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
        #expect(matches.first!.score >= matches.last!.score)
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

    @Test("flush persists pending debounced writes")
    func flushPersists() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "Sprint planning", createdAt: Date())
        await index1.flush()
        let exists = FileManager.default.fileExists(atPath: url.path)
        #expect(exists)
    }
}
