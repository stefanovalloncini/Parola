import Foundation
import Testing
@testable import ParolaCore

@Suite("Chapter id")
struct ChapterIDTests {
    @Test("two chapters with the same title and start share an id")
    func stableAcrossConstruction() {
        let a = Chapter(title: "Intro", start: 0)
        let b = Chapter(title: "Intro", start: 0)
        #expect(a.id == b.id)
    }

    @Test("different titles produce different ids")
    func titleAffectsID() {
        let a = Chapter(title: "Intro", start: 0)
        let b = Chapter(title: "Outro", start: 0)
        #expect(a.id != b.id)
    }

    @Test("different starts produce different ids")
    func startAffectsID() {
        let a = Chapter(title: "Same", start: 0)
        let b = Chapter(title: "Same", start: 120)
        #expect(a.id != b.id)
    }

    @Test("explicit id wins over derivation")
    func explicitIDPreserved() {
        let chapter = Chapter(id: "custom", title: "Same", start: 0)
        #expect(chapter.id == "custom")
    }

    @Test("derived id is a fixed, cross-process-stable value")
    func deterministicLiteral() {
        #expect(Chapter(title: "Intro", start: 0).id == "ch-0-ba77daf5b55d0cd1")
    }

    @Test(
        "a non-finite or out-of-range start yields a stable id without trapping",
        arguments: [Double.infinity, -.infinity, .nan, 1e19, -1e19]
    )
    func idTotalOverExtremeStart(start: Double) {
        let a = Chapter(title: "Edge", start: start)
        let b = Chapter(title: "Edge", start: start)
        #expect(!a.id.isEmpty)
        #expect(a.id == b.id)
    }
}
