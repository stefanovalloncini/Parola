import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Entry row")
struct EntryRowTests {
    @Test("an excerpt stops on the last whole word that fits and says it was cut")
    func excerptCutsOnAWordBoundary() {
        let text = "Il primo paragrafo della trascrizione continua ben oltre il limite richiesto."
        #expect(LibrarySearchIndex.excerpt(from: text, maxLength: 30) == "Il primo paragrafo della…")
    }

    @Test("an excerpt that fits is quoted whole, without an ellipsis")
    func shortTextIsQuotedWhole() {
        #expect(LibrarySearchIndex.excerpt(from: "Due parole.", maxLength: 240) == "Due parole.")
    }

    @Test("line breaks and runs of spaces collapse to one space")
    func whitespaceCollapses() {
        let text = "  Prima riga.\n\nSeconda   riga.\t Terza.  "
        #expect(LibrarySearchIndex.excerpt(from: text, maxLength: 240) == "Prima riga. Seconda riga. Terza.")
    }

    @Test("an entry with nothing indexed has no excerpt at all")
    func emptyTextHasNoExcerpt() {
        #expect(LibrarySearchIndex.excerpt(from: "", maxLength: 240) == nil)
        #expect(LibrarySearchIndex.excerpt(from: "   \n  ", maxLength: 240) == nil)
        #expect(LibrarySearchIndex.excerpt(from: "parola", maxLength: 0) == nil)
    }

    /// A word longer than the whole allowance has no boundary to cut on, and still must not run past it.
    @Test("a single long word is cut where the allowance ends")
    func oneLongWordIsCutHard() {
        let excerpt = LibrarySearchIndex.excerpt(from: String(repeating: "a", count: 40), maxLength: 10)
        #expect(excerpt == String(repeating: "a", count: 10) + "…")
    }
}
