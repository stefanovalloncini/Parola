import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Library row display")
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

    @Test("the cache reuses a row until its entry or its excerpt changes")
    func cacheReusesUntilTheEntryOrExcerptChanges() {
        var cache = LibraryRowDisplayCache()
        let original = entry(aiTitle: "Riunione fornitori", summary: "Ordini al magazzino.")
        let first = cache.display(for: original, excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(first.title == "Riunione fornitori")

        let again = cache.display(for: original, excerpt: "sensori fattivi…", showsAITitle: true, showsAISummary: true)
        #expect(buffer(of: again.tooltip) == buffer(of: first.tooltip))

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

    /// A reused display hands back the same heap buffer — readable only past the 15-byte small-string form, as every fixture tooltip is.
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

    private func spoken(in language: String, seconds: Double? = nil) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalAudioName: "Chiamata con il fornitore.m4a",
            modelName: "m",
            language: language,
            durationSeconds: seconds
        )
        return LibraryEntry(id: "c", bundleURL: URL(fileURLWithPath: "/tmp/c.parola"), manifest: manifest)
    }

    @Test("a row names its language only when the library mostly speaks another")
    func languageOnlyWhenItDiffers() {
        let italian = spoken(in: "it")
        #expect(LibraryRowDisplay(entry: italian, usualLanguage: "EN").language == LanguageDisplay.name(for: "it"))
        #expect(LibraryRowDisplay(entry: italian, usualLanguage: "IT").language == nil)
        #expect(LibraryRowDisplay(entry: spoken(in: "unknown"), usualLanguage: "EN").language == nil)
    }

    @Test("a row states its length in words")
    func lengthInWords() {
        #expect(LibraryRowDisplay(entry: spoken(in: "en", seconds: 4320)).duration == "1 h 12 min")
        #expect(LibraryRowDisplay(entry: spoken(in: "en")).duration == nil)
    }

    @Test("the cache rebuilds a row whose time or usual language changed, and reuses it otherwise")
    func cacheFollowsTheTimeAndTheLanguage() {
        var cache = LibraryRowDisplayCache()
        let subject = spoken(in: "it")

        let first = cache.display(for: subject, when: "9:05", usualLanguage: "EN")
        #expect(first.language == LanguageDisplay.name(for: "it"))
        let again = cache.display(for: subject, when: "9:05", usualLanguage: "EN")
        #expect(buffer(of: again.tooltip) == buffer(of: first.tooltip))

        let lateNight = cache.display(for: subject, when: "Yesterday 9:05", usualLanguage: "EN")
        #expect(lateNight.when == "Yesterday 9:05")
        #expect(buffer(of: lateNight.tooltip) != buffer(of: first.tooltip))
        #expect(cache.display(for: subject, when: "Yesterday 9:05", usualLanguage: "IT").language == nil)
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
