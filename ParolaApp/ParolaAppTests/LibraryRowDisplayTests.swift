import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Library row display prefers AI metadata when asked")
struct LibraryRowDisplayTests {
    private func entry(aiTitle: String?, summary: String?) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(originalAudioName: "New Recording 160.m4a", modelName: "m", language: "it")
        manifest.aiTitle = aiTitle
        manifest.shortSummary = summary
        return LibraryEntry(id: "e", bundleURL: URL(fileURLWithPath: "/tmp/e.parola"), manifest: manifest)
    }

    @Test("AI title and summary replace the file name and excerpt when the toggles are on")
    func prefersAI() {
        let row = LibraryRowDisplay(entry: entry(aiTitle: "Riunione fornitori", summary: "Ordini al magazzino."), excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(row.title == "Riunione fornitori")
        #expect(row.excerpt == "Ordini al magazzino.")
    }

    @Test("falls back to the file name and excerpt without AI metadata or with the toggles off")
    func fallsBack() {
        let plain = LibraryRowDisplay(entry: entry(aiTitle: nil, summary: nil), excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(plain.title == "New Recording 160")
        #expect(plain.excerpt == "sensori fattivi…")
        let off = LibraryRowDisplay(entry: entry(aiTitle: "Riunione fornitori", summary: "Ordini."), excerpt: "sensori fattivi…")
        #expect(off.title == "New Recording 160")
        #expect(off.excerpt == "sensori fattivi…")
    }

    @Test("the cache reuses a display for a matching raw excerpt and recomputes for a changed one")
    func cacheReusesOnMatchingRawExcerpt() {
        var cache = LibraryRowDisplayCache()
        let original = entry(aiTitle: "Riunione fornitori", summary: "Ordini al magazzino.")
        let first = cache.display(for: original, excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(first.title == "Riunione fornitori")

        let changed = entry(aiTitle: "Titolo diverso", summary: "Riassunto diverso.")
        let second = cache.display(for: changed, excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(second.title == "Titolo diverso")

        let third = cache.display(for: changed, excerpt: "testo differente", showsAITitle: true, showsAISummary: true)
        #expect(third.title == "Titolo diverso")
        #expect(third.excerpt == "Riassunto diverso.")
    }

    private func named(_ id: String, title: String) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: "\(title).m4a",
            title: title,
            modelName: "m",
            language: "it"
        )
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/\(id).parola"), manifest: manifest)
    }

    /// A reused display hands back the very same string, buffer and all; a rebuilt one allocates a fresh one.
    private func buffer(of string: String) -> UInt {
        var copy = string
        return copy.withUTF8 { UInt(bitPattern: $0.baseAddress) }
    }

    @Test("one entry changing rebuilds its own row and leaves every other row alone")
    func onlyTheChangedRowIsRebuilt() {
        var cache = LibraryRowDisplayCache()
        let first = named("a", title: "Riunione settimanale")
        let other = named("b", title: "Chiamata con il fornitore")
        let firstBefore = cache.display(for: first)
        let otherBefore = cache.display(for: other)

        var renamed = first.manifest
        renamed.title = "Riunione settimanale (rev 2)"
        let edited = LibraryEntry(id: first.id, bundleURL: first.bundleURL, manifest: renamed)
        let firstAfter = cache.display(for: edited)
        let otherAfter = cache.display(for: other)

        #expect(firstAfter.title == "Riunione settimanale (rev 2)")
        #expect(buffer(of: firstAfter.tooltip) != buffer(of: firstBefore.tooltip))
        #expect(buffer(of: otherAfter.tooltip) == buffer(of: otherBefore.tooltip))
    }

    @Test("flipping the AI toggles rebuilds the row the toggles change")
    func aiTogglesRebuildTheRow() {
        var cache = LibraryRowDisplayCache()
        let subject = entry(aiTitle: "Riunione fornitori", summary: "Ordini al magazzino.")

        let off = cache.display(for: subject, excerpt: "sensori fattivi…")
        #expect(off.title == "New Recording 160")
        #expect(off.excerpt == "sensori fattivi…")

        let on = cache.display(for: subject, excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(on.title == "Riunione fornitori")
        #expect(on.excerpt == "Ordini al magazzino.")

        let titleOnly = cache.display(for: subject, excerpt: "sensori fattivi…", showsAITitle: true)
        #expect(titleOnly.title == "Riunione fornitori")
        #expect(titleOnly.excerpt == "sensori fattivi…")
    }
}
