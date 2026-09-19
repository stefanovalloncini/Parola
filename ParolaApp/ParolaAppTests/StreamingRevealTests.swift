import SwiftUI
import Testing
@testable import Parola

@Suite("Streaming reveal")
struct StreamingRevealTests {

    @Test("the words that just arrived are dimmed, the rest are not")
    func freshTailIsDimmed() {
        let text = StreamingReveal.attributed(settled: "already there ", fresh: "just now")
        #expect(String(text.characters) == "already there just now")
        let runs = Array(text.runs)
        #expect(runs.count == 2)
        #expect(runs[0].foregroundColor == DS.Color.primaryText)
        #expect(runs[1].foregroundColor == DS.Color.primaryText.opacity(0.5))
    }

    @Test("settled text on its own is one run")
    func emptyFreshIsOneRun() {
        let text = StreamingReveal.attributed(settled: "already there", fresh: "")
        #expect(String(text.characters) == "already there")
        let runs = Array(text.runs)
        #expect(runs.count == 1)
        #expect(runs[0].foregroundColor == DS.Color.primaryText)
    }

    @Test("a reveal that has not started yet is empty")
    func emptyReveal() {
        let text = StreamingReveal.attributed(settled: "", fresh: "")
        #expect(String(text.characters).isEmpty)
    }
}
