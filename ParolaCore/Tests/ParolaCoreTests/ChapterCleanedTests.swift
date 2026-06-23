import Foundation
import Testing
@testable import ParolaCore

@Suite("Chapter cleaned factory")
struct ChapterCleanedTests {
    @Test("a clean title passes through unchanged and matches the plain initializer")
    func cleanTitlePreserved() {
        #expect(Chapter.cleaned(title: "Roadmap review", start: 90) == Chapter(title: "Roadmap review", start: 90))
    }

    @Test("strips surrounding quotes and bold markup")
    func stripsDecoration() {
        #expect(Chapter.cleaned(title: "**\"Welcome\"**", start: 0)?.title == "Welcome")
    }

    @Test("an empty title yields nil")
    func emptyTitleDropped() {
        #expect(Chapter.cleaned(title: "", start: 0) == nil)
    }

    @Test("a whitespace-only title yields nil")
    func whitespaceTitleDropped() {
        #expect(Chapter.cleaned(title: "   ", start: 0) == nil)
    }

    @Test("an all-decorator title yields nil")
    func decoratorOnlyTitleDropped() {
        #expect(Chapter.cleaned(title: "— •", start: 0) == nil)
    }
}
