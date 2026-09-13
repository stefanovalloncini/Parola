import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("RecentEntries")
struct RecentEntriesTests {
    private func entry(_ id: String, at seconds: TimeInterval) -> LibraryEntry {
        LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/\(id).parola"),
            manifest: ParolaDocument.Manifest(
                createdAt: Date(timeIntervalSince1970: seconds),
                originalAudioName: "\(id).wav",
                modelName: "tiny",
                language: "en"
            )
        )
    }

    @Test("orders by most recent first regardless of input order")
    func ordersByRecency() {
        let entries = [entry("a", at: 100), entry("b", at: 300), entry("c", at: 200)]
        #expect(RecentEntries.most(of: entries, limit: 10).map(\.id) == ["b", "c", "a"])
    }

    @Test("caps the result at the limit, keeping the newest")
    func capsAtLimit() {
        let entries = (0..<8).map { entry("e\($0)", at: TimeInterval($0)) }
        let result = RecentEntries.most(of: entries, limit: 5)
        #expect(result.map(\.id) == ["e7", "e6", "e5", "e4", "e3"])
    }

    @Test("returns every entry when there are fewer than the limit")
    func fewerThanLimit() {
        #expect(RecentEntries.most(of: [entry("a", at: 1), entry("b", at: 2)], limit: 5).map(\.id) == ["b", "a"])
    }

    @Test("empty input yields empty output")
    func empty() {
        #expect(RecentEntries.most(of: [], limit: 5).isEmpty)
    }

    @Test("a non-positive limit yields empty output")
    func nonPositiveLimit() {
        #expect(RecentEntries.most(of: [entry("a", at: 1)], limit: 0).isEmpty)
        #expect(RecentEntries.most(of: [entry("a", at: 1)], limit: -3).isEmpty)
    }

    @Test("entries sharing a timestamp keep the order they arrived in")
    func tiesKeepArrivalOrder() {
        let entries = [entry("a", at: 100), entry("b", at: 100), entry("c", at: 100)]
        #expect(RecentEntries.most(of: entries, limit: 10).map(\.id) == ["a", "b", "c"])
        #expect(RecentEntries.most(of: entries, limit: 2).map(\.id) == ["a", "b"])
    }

    @Test("a tie at the cut keeps the entry already in the list")
    func tieAtCutKeepsIncumbent() {
        let entries = [entry("a", at: 300), entry("b", at: 100), entry("c", at: 100)]
        #expect(RecentEntries.most(of: entries, limit: 2).map(\.id) == ["a", "b"])
    }

    @Test("matches a full sort over a large shuffled library")
    func matchesFullSort() {
        let entries = (0..<400).map { entry("e\($0)", at: TimeInterval($0)) }.shuffled()
        let expected = entries.sorted { $0.createdAt > $1.createdAt }.prefix(5).map(\.id)
        #expect(RecentEntries.most(of: entries, limit: 5).map(\.id) == Array(expected))
    }

}
