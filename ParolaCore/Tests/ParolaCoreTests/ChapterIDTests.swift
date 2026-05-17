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
}
