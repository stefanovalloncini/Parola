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
}
