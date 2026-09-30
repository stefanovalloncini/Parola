import Testing
import Foundation
import os
@testable import ParolaCore

private func eventually(
    timeoutMs: Int = 5000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private struct SnapshotWrites: Sendable {
    var written: [URL] = []
    var removed: [URL] = []

    var writtenNames: [String] { written.map(\.lastPathComponent) }
    var removedNames: [String] { removed.map(\.lastPathComponent) }
}

@Suite("LibrarySearchIndex")
final class LibrarySearchIndexTests {
    private var tempDirectories: [URL] = []

    deinit {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
            // The legacy single-file snapshot is a sibling of the directory, not inside it.
            try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
        }
    }

    private func makeObservedIndex(
        at directory: URL,
        saveDebounce: Duration = .seconds(60)
    ) -> (LibrarySearchIndex, OSAllocatedUnfairLock<SnapshotWrites>) {
        let log = OSAllocatedUnfairLock(initialState: SnapshotWrites())
        let index = LibrarySearchIndex(
            indexDirectory: directory,
            saveDebounce: saveDebounce,
            clock: ContinuousClock(),
            writeSnapshotData: { data, target in
                log.withLock { $0.written.append(target) }
                try data.write(to: target, options: .atomic)
            },
            removeSnapshotFile: { target in
                log.withLock { $0.removed.append(target) }
                try FileManager.default.removeItem(at: target)
            }
        )
        return (index, log)
    }

    private func makeTempDirectory(_ name: String = "parola-search-test") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(url)
        return url
    }

    private func makeTempIndex(saveDebounce: Duration = .seconds(60)) -> (LibrarySearchIndex, URL) {
        let url = makeTempDirectory()
        return (LibrarySearchIndex(indexDirectory: url, saveDebounce: saveDebounce), url)
    }

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func entryURL(_ id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("entries", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func legacySnapshotURL(for directory: URL) -> URL {
        directory.appendingPathExtension("json")
    }

    private func manifestEntries(in directory: URL) throws -> [String: String] {
        let data = try Data(contentsOf: manifestURL(in: directory))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 11)
        return try #require(object["entries"] as? [String: String])
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

    @Test("replacing auxiliary text swaps its words and keeps the body's")
    func replaceAuxiliaryTextSwapsWords() async throws {
        let (index, _) = makeTempIndex()
        await index.index(
            id: "e1", title: "Notes", text: "Sprint planning review",
            auxiliaryText: "Walrus\nplanning", createdAt: Date()
        )

        #expect(await index.replaceAuxiliaryText("Walrus\nplanning", with: "Narwhal", for: "e1"))

        #expect(await index.search("walrus").isEmpty)
        #expect(await index.search("narwhal").map(\.entryID) == ["e1"])
        let body = try #require(await index.search("planning").first)
        #expect(body.entryID == "e1")
        #expect(body.matchCount == 1)
        #expect(await index.search("notes").map(\.entryID) == ["e1"])
    }

    @Test("replacing auxiliary text on an entry the index lacks says so")
    func replaceAuxiliaryTextOnMissingEntry() async {
        let (index, _) = makeTempIndex()
        #expect(await index.replaceAuxiliaryText("", with: "Narwhal", for: "missing") == false)
        #expect(await index.search("narwhal").isEmpty)
    }

    @Test("snapshot persists across instances")
    func snapshotRoundTrip() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "Sprint planning", createdAt: Date())
        await index1.flush()
        let index2 = LibrarySearchIndex(indexDirectory: url)
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
        let index2 = LibrarySearchIndex(indexDirectory: url)
        let match = try #require(await index2.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 3)
    }

    @Test("a snapshot written before the counts existed is discarded and rebuilt")
    func snapshotBeforeCountsIsDiscarded() async throws {
        let url = makeTempDirectory("parola-search-v5")
        let v5 = #"{"version":5,"entries":[{"id":"e1","title":"Notes","excerpt":"Sprint planning","#
            + #""tokens":["notes","planning","sprint"],"fingerprint":"f1"}]}"#
        try Data(v5.utf8).write(to: legacySnapshotURL(for: url))
        let index = LibrarySearchIndex(indexDirectory: url)
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
        let url = makeTempDirectory("parola-search-v6")
        let v6 = #"{"version":6,"entries":[{"id":"e1","title":"Notes","excerpt":"Sprint planning",""#
            + #"tokens":["notes","planning","sprint"],"counts":[1,1,1],"fingerprint":"f1"}]}"#
        try Data(v6.utf8).write(to: legacySnapshotURL(for: url))
        let index = LibrarySearchIndex(indexDirectory: url)
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

    /// v7 boundaries counted blank segments, so their indices address a transcript the app never sees.
    @Test("a v7 snapshot's raw-segment boundaries are discarded")
    func snapshotWithRawSegmentBoundariesIsDiscarded() async throws {
        let url = makeTempDirectory("parola-search-v7")
        let v7 = #"{"version":7,"entries":[{"id":"e1","title":"Riunione","excerpt":"Buongiorno a tutti lancio",""#
            + #""excerptTruncated":false,"tokens":["buongiorno","lancio","riunione","tutti"],"counts":[1,1,1,1],"#
            + #""offsets":[0,19,-1,14],"boundaryOffsets":[0,19,19],"boundaryCentiseconds":[0,450,900],"#
            + #""fingerprint":"f1"}]}"#
        try Data(v7.utf8).write(to: legacySnapshotURL(for: url))
        let index = LibrarySearchIndex(indexDirectory: url)

        #expect(await index.search("lancio").isEmpty)
        #expect(await index.needsRebuild(matching: ["e1": "f1"]))

        let transcript = makeTranscript([(0, "Buongiorno a tutti"), (4.5, ""), (9, "lancio di primavera")])
        await index.rebuild(entries: [
            .init(
                id: "e1",
                title: "Riunione",
                text: transcript.text,
                boundaries: LibraryStore.segmentBoundaries(for: transcript),
                fingerprint: "f1"
            )
        ])
        let hit = try #require(await index.search("lancio").first(where: { $0.entryID == "e1" })?.firstHit)
        #expect(hit.segmentIndex == 1)
        #expect(hit.seconds == 9)
        await index.flush()
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
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1"])
        let raw = try #require(String(data: Data(contentsOf: entryURL("e1", in: url)), encoding: .utf8))
        #expect(raw.contains(#""boundaryOffsets":[0,23]"#))
        #expect(raw.contains(#""boundaryCentiseconds":[0,1240]"#))
    }

    @Test("an entry whose counts went missing still counts its hit once")
    func missingCountsFallBackToOne() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "Sprint planning and sprint retro", createdAt: Date())
        await index1.flush()
        // Empty the counts out of the entry file the actor just wrote, keeping every other field.
        var entry = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: entryURL("e1", in: url))) as? [String: Any]
        )
        entry["counts"] = [Int]()
        try JSONSerialization.data(withJSONObject: entry).write(to: entryURL("e1", in: url))

        let index2 = LibrarySearchIndex(indexDirectory: url)
        let match = try #require(await index2.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.matchCount == 1)
    }

    private func makeTranscript(_ segments: [(start: Double, text: String)]) -> Transcript {
        Transcript(
            segments: segments.enumerated().map {
                TranscriptSegment(id: $0.offset, start: $0.element.start, end: $0.element.start + 1, text: $0.element.text)
            },
            language: "it",
            modelName: "tiny"
        )
    }

    private func indexTranscript(
        _ transcript: Transcript,
        title: String,
        in index: LibrarySearchIndex,
        id: String = "e1"
    ) async {
        await index.index(
            id: id,
            title: title,
            text: transcript.text,
            boundaries: LibraryStore.segmentBoundaries(for: transcript),
            createdAt: Date()
        )
    }

    private static let meeting: [(start: Double, text: String)] = [
        (0, "Buongiorno a tutti"),
        (12.4, "parliamo del lancio di primavera"),
        (30, "poi le domande")
    ]

    @Test("a match reports the segment its first hit falls in")
    func firstHitReportsItsSegment() async throws {
        let (index, _) = makeTempIndex()
        let transcript = makeTranscript(Self.meeting)
        await indexTranscript(transcript, title: "Riunione", in: index)
        let match = try #require(await index.search("lancio").first(where: { $0.entryID == "e1" }))
        let hit = try #require(match.firstHit)
        #expect(hit.segmentIndex == 1)
        #expect(hit.seconds == 12.4)
        let text = transcript.text
        let start = text.index(text.startIndex, offsetBy: hit.textOffset)
        #expect(text[start...].hasPrefix("lancio"))
    }

    @Test("a prefix query reports the same first hit as the whole word")
    func firstHitCountsPrefixMatches() async throws {
        let (index, _) = makeTempIndex()
        await indexTranscript(makeTranscript(Self.meeting), title: "Riunione", in: index)
        let whole = try #require(await index.search("lancio").first?.firstHit)
        let prefix = try #require(await index.search("lanc").first?.firstHit)
        #expect(prefix == whole)
    }

    @Test("a two-term query reports the earlier of the two hits")
    func firstHitTakesTheEarliestTerm() async throws {
        let (index, _) = makeTempIndex()
        await indexTranscript(makeTranscript(Self.meeting), title: "Riunione", in: index)
        let hit = try #require(await index.search("domande lancio").first?.firstHit)
        #expect(hit.segmentIndex == 1)
    }

    @Test("an entry matched on its title alone has no first hit")
    func titleOnlyMatchHasNoFirstHit() async throws {
        let (index, _) = makeTempIndex()
        await indexTranscript(makeTranscript(Self.meeting), title: "Riunione", in: index)
        let match = try #require(await index.search("riunione").first(where: { $0.entryID == "e1" }))
        #expect(match.firstHit == nil)
        #expect(match.matchCount == 1)
    }

    @Test("an entry indexed without boundaries has no first hit")
    func matchWithoutBoundariesHasNoFirstHit() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.firstHit == nil)
    }

    @Test("the first hit survives the snapshot round trip")
    func firstHitRoundTrips() async throws {
        let (index1, url) = makeTempIndex()
        await indexTranscript(makeTranscript(Self.meeting), title: "Riunione", in: index1)
        await index1.flush()
        let index2 = LibrarySearchIndex(indexDirectory: url)
        let hit = try #require(await index2.search("lancio").first?.firstHit)
        #expect(hit.segmentIndex == 1)
        #expect(hit.seconds == 12.4)
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

    @Test("a hit followed by more real text keeps the trailing ellipsis")
    func snippetFollowedByMoreTextKeepsTrailingEllipsis() async throws {
        let (index, _) = makeTempIndex()
        let body = String(repeating: "ab ", count: 60) + "sprint" + String(repeating: " cd", count: 30)
        #expect(body.count > 200) // well past where the old excerpt cap used to sit
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.hasSuffix("…"))
    }

    @Test("a hit at the true end of a long document is not marked as cut")
    func snippetAtTheDocumentsEndIsNotMarked() async throws {
        let (index, _) = makeTempIndex()
        let body = String(repeating: "ab ", count: 80) + "z " + "sprint"
        #expect(body.count > 200) // the whole document, well past the old excerpt cap, ends right here
        await index.index(id: "e1", title: "Notes", text: body, createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.hasPrefix("…"))
        #expect(match.snippet.hasSuffix("sprint"))
    }

    @Test("a snippet that is the whole line carries no ellipsis")
    func wholeLineSnippetIsNotMarked() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint retro", createdAt: Date())
        let match = try #require(await index.search("sprint").first(where: { $0.entryID == "e1" }))
        #expect(!match.snippet.contains("…"))
        #expect(match.snippet == "sprint retro")
    }

    @Test("a two-term query snippets the earlier of the two hits")
    func snippetTakesTheEarliestTerm() async throws {
        let (index, _) = makeTempIndex()
        let body = "parliamo del lancio di primavera " + String(repeating: "riempitivo ", count: 20) + "poi le domande"
        await index.index(id: "e1", title: "Riunione", text: body, createdAt: Date())
        let match = try #require(await index.search("domande lancio").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.contains("lancio"))
        #expect(match.snippet.contains("domande") == false)
    }

    @Test("a match on the title alone snippets the opening of the body")
    func titleOnlyMatchSnippetsTheOpening() async throws {
        let (index, _) = makeTempIndex()
        await index.index(
            id: "e1",
            title: "Riunione",
            text: "parliamo del lancio di primavera e poi delle domande aperte del reparto "
                + String(repeating: "e delle altre cose ", count: 5),
            createdAt: Date()
        )
        let match = try #require(await index.search("riunione").first(where: { $0.entryID == "e1" }))
        #expect(match.snippet.hasPrefix("parliamo del lancio"))
        #expect(match.snippet.hasSuffix("…"))
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
        #expect(FileManager.default.fileExists(atPath: manifestURL(in: url).path))
        #expect(FileManager.default.fileExists(atPath: entryURL("e1", in: url).path))
    }

    @Test("the snapshot stores the full body text, not a truncated excerpt")
    func snapshotStoresFullText() async throws {
        let (index, url) = makeTempIndex()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 10)
        let text = filler + "ZzyzxMarker closing remarks"
        await index.index(id: "e1", title: "Notes", text: text, createdAt: Date())
        await index.flush()

        let raw = try #require(String(data: Data(contentsOf: entryURL("e1", in: url)), encoding: .utf8))
        #expect(raw.contains("ZzyzxMarker"))

        let matches = await index.search("zzyzxmarker")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
    }

    @Test("tokens far into a long document survive a reload")
    func tokensFarIntoDocumentSurviveReload() async throws {
        let (index1, url) = makeTempIndex()
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 10)
        await index1.index(id: "e1", title: "Notes", text: filler + "zzyzxmarker tail", createdAt: Date())
        await index1.flush()

        let index2 = LibrarySearchIndex(indexDirectory: url)
        let matches = await index2.search("zzyzxmarker")
        #expect(matches.contains(where: { $0.entryID == "e1" }))
        let headMatches = await index2.search("lorem")
        let head = try #require(headMatches.first(where: { $0.entryID == "e1" }))
        #expect(head.snippet.lowercased().contains("lorem"))
    }

    @Test("a hit past 200 characters gets a real, highlighted snippet with no re-read needed")
    func snippetFarIntoDocumentIsReal() async throws {
        let (index, _) = makeTempIndex()
        let filler = String(repeating: "lorem ipsum dolor sit amet consectetur adipiscing elit ", count: 100)
        let text = filler + "zzyzxmarker tail"
        let hitOffset = text.distance(from: text.startIndex, to: try #require(text.range(of: "zzyzxmarker")).lowerBound)
        #expect(hitOffset > 5000)
        await index.index(id: "e1", title: "Notes", text: text, createdAt: Date())

        let matches = await index.search("zzyzxmarker")
        let match = try #require(matches.first(where: { $0.entryID == "e1" }))

        #expect(match.snippet.lowercased().contains("zzyzxmarker"))
        #expect(match.highlights.count >= 1)
        for highlight in match.highlights {
            let start = match.snippet.index(match.snippet.startIndex, offsetBy: highlight.start)
            let end = match.snippet.index(start, offsetBy: highlight.length)
            #expect(match.snippet[start..<end].lowercased() == "zzyzxmarker")
        }
    }

    @Test("indexing an entry whose tokens are all known keeps the sorted vocabulary")
    func knownTokensKeepTheSortedVocabulary() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        _ = await index.search("sprint")
        #expect(await index.vocabularySorts == 1)

        await index.index(id: "e2", title: "Notes", text: "planning sprint", createdAt: Date())
        _ = await index.search("sprint")
        #expect(await index.vocabularySorts == 1)

        await index.index(id: "e3", title: "Notes", text: "retro feedback", createdAt: Date())
        _ = await index.search("sprint")
        #expect(await index.vocabularySorts == 2)
    }

    @Test("removing an entry whose tokens survive keeps the sorted vocabulary")
    func survivingTokensKeepTheSortedVocabulary() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        await index.index(id: "e2", title: "Notes", text: "sprint planning", createdAt: Date())
        _ = await index.search("sprint")
        #expect(await index.vocabularySorts == 1)

        await index.remove("e2")
        let matches = await index.search("sprint")
        #expect(matches.map(\.entryID) == ["e1"])
        #expect(await index.vocabularySorts == 1)
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

    @Test("a rebuild of many entries indexes each one exactly as indexing it would")
    func rebuildMatchesEntryByEntryIndexing() async throws {
        let words = ["sprint", "retro", "lancio", "kanban", "riunione", "alpha", "primavera", "domande"]
        let entries = (0..<60).map { position -> LibrarySearchIndex.RebuildEntry in
            let body = (0..<12).map { words[($0 &* 7 &+ position) % words.count] }.joined(separator: " ")
            return .init(
                id: "e\(position)",
                title: "Entry \(position) \(words[position % words.count])",
                text: "\(body) marker\(position)",
                auxiliaryText: words[(position &+ 3) % words.count],
                boundaries: [.init(textOffset: 0, seconds: Double(position))],
                fingerprint: "f\(position)"
            )
        }

        let (rebuilt, _) = makeTempIndex()
        await rebuilt.rebuild(entries: entries)

        let (incremental, _) = makeTempIndex()
        for entry in entries {
            await incremental.index(
                id: entry.id, title: entry.title, text: entry.text, auxiliaryText: entry.auxiliaryText,
                boundaries: entry.boundaries, fingerprint: entry.fingerprint, createdAt: Date()
            )
        }

        for query in words + ["marker7", "marker59", "entry"] {
            let a = await keyed(rebuilt.search(query))
            let b = await keyed(incremental.search(query))
            #expect(a == b, "query \(query)")
        }
        #expect(await rebuilt.needsRebuild(matching: Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0.fingerprint) }
        )) == false)
    }

    @Test("a version-2 snapshot is discarded as stale")
    func v2SnapshotDiscarded() async throws {
        let url = makeTempDirectory()
        let v2 = """
        {"version":2,"entries":{"e1":{"title":"Old","excerpt":"sprint planning","tokens":["sprint","planning"]}}}
        """
        try Data(v2.utf8).write(to: legacySnapshotURL(for: url))
        let index = LibrarySearchIndex(indexDirectory: url)
        #expect(await index.needsRebuild(matching: [:]))
        #expect(await index.search("sprint").isEmpty)
    }

    @Test("a version-3 snapshot is discarded as stale")
    func v3SnapshotDiscarded() async throws {
        let url = makeTempDirectory()
        let v3 = """
        {"version":3,"entries":{"e1":{"title":"Old","excerpt":"sprint planning","tokens":["planning","sprint"]}}}
        """
        try Data(v3.utf8).write(to: legacySnapshotURL(for: url))
        let index = LibrarySearchIndex(indexDirectory: url)
        #expect(await index.needsRebuild(matching: [:]))
        #expect(await index.search("sprint").isEmpty)
    }

    @Test("a v10 single-file snapshot is discarded and its file removed once the directory lands")
    func legacySingleFileSnapshotIsReplaced() async throws {
        let url = makeTempDirectory()
        let v10 = #"{"version":10,"entries":[{"id":"e1","title":"Notes","text":"sprint planning",""#
            + #""tokens":["notes","planning","sprint"],"counts":[1,1,1],"offsets":[-1,7,0],"#
            + #""boundaryOffsets":[],"boundaryCentiseconds":[],"fingerprint":"f1"}]}"#
        try Data(v10.utf8).write(to: legacySnapshotURL(for: url))

        let index = LibrarySearchIndex(indexDirectory: url)
        #expect(await index.search("sprint").isEmpty)
        #expect(await index.needsRebuild(matching: ["e1": "f1"]))
        #expect(FileManager.default.fileExists(atPath: legacySnapshotURL(for: url).path))

        await index.rebuild(entries: [.init(id: "e1", title: "Notes", text: "sprint planning", fingerprint: "f1")])
        await index.flush()

        #expect(await index.search("sprint").map(\.entryID) == ["e1"])
        #expect(try manifestEntries(in: url) == ["e1": "f1"])
        #expect(FileManager.default.fileExists(atPath: legacySnapshotURL(for: url).path) == false)
    }

    @Test("a manifest row whose entry file is gone makes the snapshot stale")
    func missingEntryFileIsStale() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "sprint planning", fingerprint: "f1", createdAt: Date())
        await index1.index(id: "e2", title: "Other", text: "retro feedback", fingerprint: "f2", createdAt: Date())
        await index1.flush()
        try FileManager.default.removeItem(at: entryURL("e2", in: url))

        let index2 = LibrarySearchIndex(indexDirectory: url)
        #expect(await index2.needsRebuild(matching: ["e1": "f1", "e2": "f2"]))
        #expect(await index2.search("sprint").isEmpty)
    }

    @Test("a manifest row whose entry file will not decode makes the snapshot stale")
    func corruptEntryFileIsStale() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "sprint planning", fingerprint: "f1", createdAt: Date())
        await index1.flush()
        try Data("not json".utf8).write(to: entryURL("e1", in: url))

        let index2 = LibrarySearchIndex(indexDirectory: url)
        #expect(await index2.needsRebuild(matching: ["e1": "f1"]))
        #expect(await index2.search("sprint").isEmpty)
    }

    @Test("an entry file whose fingerprint is not the manifest's makes the snapshot stale")
    func fingerprintMismatchIsStale() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "sprint planning", fingerprint: "f1", createdAt: Date())
        await index1.flush()
        // The manifest of a later save, over an entry file an earlier save failed to replace.
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL(in: url))) as? [String: Any]
        )
        manifest["entries"] = ["e1": "f2"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL(in: url))

        let index2 = LibrarySearchIndex(indexDirectory: url)
        #expect(await index2.needsRebuild(matching: ["e1": "f2"]))
        #expect(await index2.search("sprint").isEmpty)
    }

    @Test("an entry file the manifest does not list is ignored and pruned")
    func unlistedEntryFileIsPruned() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        await index1.flush()
        let ghost = entryURL("ghost", in: url)
        try Data(contentsOf: entryURL("e1", in: url)).write(to: ghost)

        let index2 = LibrarySearchIndex(indexDirectory: url)
        #expect(await index2.search("sprint").map(\.entryID) == ["e1"])
        await index2.index(id: "e2", title: "Other", text: "retro feedback", createdAt: Date())
        await index2.flush()

        #expect(FileManager.default.fileExists(atPath: ghost.path) == false)
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1", "e2"])
    }

    @Test("a crash-orphaned temp file in entries/ is pruned even without a json extension")
    func unlistedNonJSONFileIsPruned() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        await index1.flush()
        let entryData = try Data(contentsOf: entryURL("e1", in: url))
        let junk = url.appendingPathComponent("entries", isDirectory: true).appendingPathComponent("junk.tmp")
        try entryData.write(to: junk)
        let ghost = entryURL("ghost", in: url)
        try entryData.write(to: ghost)

        let index2 = LibrarySearchIndex(indexDirectory: url)
        await index2.index(id: "e2", title: "Other", text: "retro feedback", createdAt: Date())
        await index2.flush()

        #expect(FileManager.default.fileExists(atPath: junk.path) == false)
        #expect(FileManager.default.fileExists(atPath: ghost.path) == false)
        #expect(FileManager.default.fileExists(atPath: entryURL("e1", in: url).path))
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1", "e2"])
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

        let reloaded = LibrarySearchIndex(indexDirectory: url)
        let queries = ["sprint", "retro", "alpha", "kanban", "marta", "roadmap", "zzyzxmarker", "notes", "spr"]
        for query in queries {
            let a = await keyed(incremental.search(query))
            let b = await keyed(scratch.search(query))
            let c = await keyed(reloaded.search(query))
            #expect(a == b, "query \(query)")
            #expect(a == c, "query \(query)")
        }
    }

    @Test("staleness names the entries a scan found new, rewritten or gone")
    func stalenessNamesChangedAndRemoved() async {
        let (index, _) = makeTempIndex()
        await index.rebuild(entries: [
            .init(id: "e1", title: "One", text: "first", fingerprint: "f1"),
            .init(id: "e2", title: "Two", text: "second", fingerprint: "f2"),
            .init(id: "e3", title: "Three", text: "third", fingerprint: "f3")
        ])

        let staleness = await index.staleness(matching: ["e1": "f1", "e2": "f2b", "e4": "f4"])

        #expect(staleness == .init(changed: ["e2", "e4"], removed: ["e3"]))
        #expect(await index.staleness(matching: ["e1": "f1", "e2": "f2", "e3": "f3"]).isCurrent)
    }

    @Test("reconciling the changed entries answers as a rebuild of all of them would")
    func reconcileMatchesRebuild() async {
        let final: [LibrarySearchIndex.RebuildEntry] = [
            .init(id: "e1", title: "Stand-up", text: "sprint planning and bug triage", fingerprint: "f1"),
            .init(id: "e2", title: "Retro v2", text: "retro feedback on the release", fingerprint: "f2b"),
            .init(id: "e4", title: "Weekly", text: "alpha sprint review notes", fingerprint: "f4")
        ]
        let (reconciled, _) = makeTempIndex()
        await reconciled.rebuild(entries: [
            .init(id: "e1", title: "Stand-up", text: "sprint planning and bug triage", fingerprint: "f1"),
            .init(id: "e2", title: "Retro v1", text: "old placeholder text", fingerprint: "f2"),
            .init(id: "e3", title: "Doomed", text: "zzyzxmarker filler", fingerprint: "f3")
        ])
        await reconciled.reconcile(entries: [final[1], final[2]], removing: ["e3"])
        let (scratch, _) = makeTempIndex()
        await scratch.rebuild(entries: final)

        for query in ["sprint", "retro", "alpha", "placeholder", "zzyzxmarker", "notes", "spr"] {
            #expect(await keyed(reconciled.search(query)) == keyed(scratch.search(query)), "query \(query)")
        }
        #expect(await reconciled.excerpts(after: -1)?.byEntry == scratch.excerpts(after: -1)?.byEntry)
        #expect(await reconciled.staleness(matching: ["e1": "f1", "e2": "f2b", "e4": "f4"]).isCurrent)
    }

    @Test("an index reading another process's snapshot answers from it and never writes")
    func readingIndexNeverWrites() async throws {
        let (owner, url) = makeTempIndex()
        await owner.index(id: "e1", title: "Notes", text: "sprint planning", fingerprint: "f1", createdAt: Date())
        await owner.flush()
        let manifestBefore = try Data(contentsOf: manifestURL(in: url))

        let reader = LibrarySearchIndex(readingSnapshotIn: url)
        #expect(await reader.search("sprint").map(\.entryID) == ["e1"])
        await reader.index(id: "e2", title: "Retro", text: "sprint retro", fingerprint: "f2", createdAt: Date())
        await reader.rebuild(entries: [.init(id: "e3", title: "Other", text: "sprint other", fingerprint: "f3")])
        await reader.flush()

        #expect(await reader.search("sprint").map(\.entryID) == ["e3"])
        #expect(try Data(contentsOf: manifestURL(in: url)) == manifestBefore)
        #expect(!FileManager.default.fileExists(atPath: entryURL("e2", in: url).path))
        #expect(!FileManager.default.fileExists(atPath: entryURL("e3", in: url).path))
    }

    @Test("the snapshot is read when something first asks, not when the index is made")
    func snapshotLoadsOnFirstUse() async throws {
        let (owner, url) = makeTempIndex()
        await owner.index(id: "e1", title: "Notes", text: "sprint planning", fingerprint: "f1", createdAt: Date())
        await owner.flush()

        let later = LibrarySearchIndex(indexDirectory: url)
        await owner.index(id: "e2", title: "Retro", text: "sprint retro", fingerprint: "f2", createdAt: Date())
        await owner.flush()

        #expect(await later.search("sprint").count == 2, "the load sees what landed after the index was made")
    }

    @Test("a reader refreshes from the owner's newer snapshot by decoding only what changed")
    func readerRefreshDecodesOnlyChanges() async throws {
        let (owner, url) = makeTempIndex()
        await owner.index(id: "e1", title: "One", text: "alpha notes", fingerprint: "f1", createdAt: Date())
        await owner.index(id: "e2", title: "Two", text: "beta notes", fingerprint: "f2", createdAt: Date())
        await owner.index(id: "e3", title: "Three", text: "gamma notes", fingerprint: "f3", createdAt: Date())
        await owner.flush()
        let reader = LibrarySearchIndex(readingSnapshotIn: url)
        #expect(await reader.search("notes").count == 3)
        #expect(await reader.entriesDecoded == 3)
        await reader.index(id: "mine", title: "Mine", text: "epsilon notes", fingerprint: "fm", createdAt: Date())

        await owner.index(id: "e2", title: "Two qqxwtitle", text: "beta notes", fingerprint: "f2", createdAt: Date())
        await owner.index(id: "e4", title: "Four", text: "delta notes", fingerprint: "f4", createdAt: Date())
        await owner.remove("e3")
        await owner.flush()

        #expect(await reader.refreshFromSnapshot())
        #expect(await reader.entriesDecoded == 5, "only the renamed and the new entry are decoded again")
        #expect(await reader.search("qqxwtitle").map(\.entryID) == ["e2"])
        #expect(await reader.search("gamma").isEmpty)
        #expect(Set(await reader.search("notes").map(\.entryID)) == ["e1", "e2", "e4", "mine"])
        let fresh = LibrarySearchIndex(readingSnapshotIn: url)
        #expect(await keyed(reader.search("delta")) == keyed(fresh.search("delta")))
    }

    @Test("an entry file stamped in the same instant as the manifest the reader read is decoded again")
    func readerRefreshTakesATiedEntry() async throws {
        let (owner, url) = makeTempIndex()
        await owner.index(id: "e1", title: "One", text: "alpha", fingerprint: "f1", createdAt: Date())
        await owner.flush()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: instant], ofItemAtPath: manifestURL(in: url).path)
        let reader = LibrarySearchIndex(readingSnapshotIn: url)
        #expect(await reader.search("alpha").count == 1)

        await owner.index(id: "e1", title: "One qqxwtitle", text: "alpha", fingerprint: "f1", createdAt: Date())
        await owner.flush()
        try FileManager.default.setAttributes([.modificationDate: instant], ofItemAtPath: entryURL("e1", in: url).path)

        #expect(await reader.refreshFromSnapshot())
        #expect(await reader.search("qqxwtitle").map(\.entryID) == ["e1"])
    }

    @Test("a snapshot a reader can't refresh from sends it back to a whole load")
    func readerRefreshFallsBack() async throws {
        let (owner, url) = makeTempIndex()
        await owner.index(id: "e1", title: "One", text: "alpha", fingerprint: "f1", createdAt: Date())
        await owner.flush()
        let reader = LibrarySearchIndex(readingSnapshotIn: url)
        #expect(await reader.refreshFromSnapshot(), "nothing loaded yet: the first search reads the snapshot anyway")
        #expect(await reader.search("alpha").count == 1)

        try Data("not json".utf8).write(to: manifestURL(in: url))

        #expect(await !reader.refreshFromSnapshot())
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

    @Test("a cold-loaded entry is never re-encoded to save another one")
    func coldLoadEncodesOnlyWhatChanged() async throws {
        let (index1, url) = makeTempIndex()
        for i in 1...3 {
            await index1.index(id: "e\(i)", title: "Entry \(i)", text: "sprint planning \(i)", createdAt: Date())
        }
        await index1.flush()

        let index2 = LibrarySearchIndex(indexDirectory: url)
        await index2.index(id: "e2", title: "Entry 2", text: "retro feedback", createdAt: Date())
        await index2.flush()
        #expect(await index2.entriesEncoded == 1)

        await index2.index(id: "e1", title: "Entry 1", text: "alpha notes", createdAt: Date())
        await index2.flush()
        #expect(await index2.entriesEncoded == 2)
    }

    @Test("a save writes the entries that changed and the manifest last")
    func saveWritesOnlyTheChangedEntries() async throws {
        let url = makeTempDirectory()
        let (index, log) = makeObservedIndex(at: url)

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        await index.flush()
        #expect(log.withLock { $0.writtenNames } == ["e1.json", "manifest.json"])
        #expect(log.withLock { $0.removedNames }.isEmpty)

        log.withLock { $0 = SnapshotWrites() }
        await index.index(id: "e2", title: "Two", text: "retro feedback", createdAt: Date())
        await index.flush()
        #expect(log.withLock { $0.writtenNames } == ["e2.json", "manifest.json"])
        #expect(log.withLock { $0.removedNames }.isEmpty)
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1", "e2"])
    }

    @Test("a save deletes the file of a removed entry")
    func saveDeletesRemovedEntryFiles() async throws {
        let url = makeTempDirectory()
        let (index, log) = makeObservedIndex(at: url)
        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        await index.index(id: "e2", title: "Two", text: "retro feedback", createdAt: Date())
        await index.flush()

        log.withLock { $0 = SnapshotWrites() }
        await index.remove("e2")
        await index.flush()

        #expect(log.withLock { $0.removedNames } == ["e2.json"])
        #expect(log.withLock { $0.writtenNames } == ["manifest.json"])
        #expect(FileManager.default.fileExists(atPath: entryURL("e2", in: url).path) == false)
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1"])
    }

    @Test("flushing an unchanged index writes nothing")
    func cleanFlushWritesNothing() async throws {
        let url = makeTempDirectory()
        let (index, log) = makeObservedIndex(at: url)
        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        await index.flush()
        #expect(log.withLock { $0.written.count } == 2)

        await index.flush()
        await index.flush()
        #expect(log.withLock { $0.written.count } == 2)
    }

    @Test("a superseded snapshot write leaves the manifest to the newer generation")
    func supersededWriteDropped() async throws {
        let url = makeTempDirectory()
        let gate = DispatchSemaphore(value: 0)
        let log = OSAllocatedUnfairLock(initialState: SnapshotWrites())
        let index = LibrarySearchIndex(
            indexDirectory: url,
            saveDebounce: .seconds(60),
            clock: ContinuousClock(),
            writeSnapshotData: { data, target in
                let isFirst = log.withLock { state -> Bool in
                    state.written.append(target)
                    return state.written.count == 1
                }
                if isFirst { gate.wait() }
                try data.write(to: target, options: .atomic)
            }
        )

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        let first = Task { await index.flush() }
        let logHasWrites = await eventually { log.withLock { $0.written.count } > 0 }
        #expect(logHasWrites)

        await index.index(id: "e2", title: "Two", text: "retro feedback", createdAt: Date())
        let second = Task { await index.flush() }
        let generationAtLeastTwo = await eventually { await index.snapshotGeneration >= 2 }
        #expect(generationAtLeastTwo)
        await index.index(id: "e3", title: "Three", text: "alpha review", createdAt: Date())
        let third = Task { await index.flush() }
        let generationAtLeastThree = await eventually { await index.snapshotGeneration >= 3 }
        #expect(generationAtLeastThree)

        gate.signal()
        await first.value
        await second.value
        await third.value

        let names = log.withLock { $0.writtenNames }
        #expect(names.filter { $0 == "manifest.json" }.count == 1, "only the newest generation writes the manifest")
        #expect(names.last == "manifest.json")
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1", "e2", "e3"])
        for id in ["e1", "e2", "e3"] {
            #expect(FileManager.default.fileExists(atPath: entryURL(id, in: url).path), "\(id) landed")
        }
    }

    @Test("a snapshot write that fails leaves the index pending, not clean")
    func failedWriteStaysPending() async throws {
        let url = makeTempDirectory()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let index = LibrarySearchIndex(
            indexDirectory: url,
            saveDebounce: .seconds(60),
            clock: ContinuousClock(),
            writeSnapshotData: { data, target in
                let attempt = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard attempt > 1 else { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: target, options: .atomic)
            }
        )

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        await index.flush()
        #expect(attempts.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: manifestURL(in: url).path) == false)

        await index.flush()
        #expect(attempts.withLock { $0 } == 3, "the entry file and the manifest")
        #expect(try manifestEntries(in: url).keys.sorted() == ["e1"])
        let raw = try #require(String(data: Data(contentsOf: entryURL("e1", in: url)), encoding: .utf8))
        #expect(raw.contains("\"e1\""))
    }

    @Test("a failed write reschedules itself without another mutation")
    func failedWriteReschedules() async throws {
        let url = makeTempDirectory()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let index = LibrarySearchIndex(
            indexDirectory: url,
            saveDebounce: .milliseconds(1),
            clock: ContinuousClock(),
            writeSnapshotData: { data, target in
                let attempt = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard attempt > 1 else { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: target, options: .atomic)
            }
        )

        await index.index(id: "e1", title: "One", text: "sprint planning", createdAt: Date())
        let manifestPath = manifestURL(in: url).path
        let fileExistsWait = await eventually { FileManager.default.fileExists(atPath: manifestPath) }
        #expect(fileExistsWait)
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

        let index2 = LibrarySearchIndex(indexDirectory: url)
        await index2.index(id: "e2", title: "New", text: "retro feedback", createdAt: Date())
        let old = await index2.search("sprint")
        #expect(old.contains(where: { $0.entryID == "e1" }))
        let new = await index2.search("retro")
        #expect(new.contains(where: { $0.entryID == "e2" }))
    }

    @Test("excerpts are cut when an entry is indexed and a caller that is current gets nothing")
    func excerptsCutAtIndexTime() async throws {
        let (index, _) = makeTempIndex()
        let text = "Il primo paragrafo   della riunione.\n\nSeconda riga."
        await index.index(id: "e1", title: "Riunione", text: text, createdAt: Date())
        await index.index(id: "e2", title: "Empty", text: "  ", createdAt: Date())

        let first = try #require(await index.excerpts(after: 0))
        #expect(first.byEntry == [
            "e1": try #require(LibrarySearchIndex.excerpt(from: text, maxLength: LibrarySearchIndex.excerptLength)),
        ])
        #expect(await index.excerpts(after: first.generation) == nil)
    }

    @Test("the excerpt generation moves only when an excerpt does")
    func excerptGenerationFollowsTheText() async throws {
        let (index, _) = makeTempIndex()
        await index.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        let start = try #require(await index.excerpts(after: 0)).generation

        await index.index(id: "e1", title: "Renamed notes", text: "sprint planning", createdAt: Date())
        _ = await index.replaceAuxiliaryText("", with: "A summary", for: "e1")
        #expect(await index.excerpts(after: start) == nil)

        await index.index(id: "e1", title: "Renamed notes", text: "retro feedback", createdAt: Date())
        let edited = try #require(await index.excerpts(after: start))
        #expect(edited.byEntry == ["e1": "retro feedback"])

        await index.remove("e1")
        let removed = try #require(await index.excerpts(after: edited.generation))
        #expect(removed.byEntry.isEmpty)
    }

    @Test("excerpts come back with a loaded snapshot and leave with a rebuild that drops the entry")
    func excerptsFollowLoadAndRebuild() async throws {
        let (index1, url) = makeTempIndex()
        await index1.index(id: "e1", title: "Notes", text: "sprint planning", createdAt: Date())
        await index1.index(id: "e2", title: "Other", text: "retro feedback", createdAt: Date())
        await index1.flush()

        let index2 = LibrarySearchIndex(indexDirectory: url)
        let loaded = try #require(await index2.excerpts(after: 0))
        #expect(loaded.byEntry == ["e1": "sprint planning", "e2": "retro feedback"])

        await index2.rebuild(entries: [.init(id: "e2", title: "Other", text: "retro feedback")])
        let rebuilt = try #require(await index2.excerpts(after: loaded.generation))
        #expect(rebuilt.byEntry == ["e2": "retro feedback"])
    }

    @Test("two query terms starting at the same place frame the snippet on the longer one")
    func snippetHitTieTakesTheLongerTerm() async throws {
        let (index, _) = makeTempIndex()
        let text = String(repeating: "filler ", count: 12) + "parola " + String(repeating: "filler ", count: 12)
        await index.index(id: "e1", title: "Tie", text: text, createdAt: Date())
        let match = try #require(await index.search("pa parol").first)
        let filled = try #require(await index.withSnippets(
            [LibrarySearchIndex.Match(entryID: "e1", score: match.score, snippet: "")],
            query: "parol pa"
        ).first)
        #expect(filled.snippet == match.snippet)
        #expect(filled.highlights == match.highlights)
        #expect(await index.search("pa parol", snippets: false).first?.snippet == "")
    }
}
