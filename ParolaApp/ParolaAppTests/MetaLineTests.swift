import SwiftUI
import Testing
@testable import Parola

@Suite("Row meta line")
struct MetaLineTests {

    @Test("facts join with one middot and absent ones leave no gap")
    func joinsPresentFacts() {
        #expect(MetaLine.joined(["12 Sep 2026 at 21:35", "00:01", "English"]) == "12 Sep 2026 at 21:35 · 00:01 · English")
        #expect(MetaLine.joined(["12 Sep 2026", nil, "English"]) == "12 Sep 2026 · English")
        #expect(MetaLine.joined([nil, "", "English"]) == "English")
        #expect(MetaLine.joined(["Only"]) == "Only")
    }

    @Test("a row with nothing to say renders an empty line, not a stray separator")
    func nothingToSay() {
        #expect(MetaLine.joined([]) == "")
        #expect(MetaLine.joined([nil, nil]) == "")
        #expect(MetaLine.joined(["", ""]) == "")
    }

    @Test("the middots sit back from the facts they separate")
    func separatorsAreDimmed() {
        let line = MetaLine.attributed(["00:01", "English"], color: .black)
        let separators = line.runs.filter { String(line[$0.range].characters) == " · " }
        let facts = line.runs.filter { String(line[$0.range].characters) != " · " }
        #expect(separators.count == 1)
        #expect(facts.count == 2)
        #expect(separators.allSatisfy { $0.foregroundColor == Color.black.opacity(0.5) })
        #expect(facts.allSatisfy { $0.foregroundColor == Color.black })
        #expect(String(line.characters) == "00:01 · English")
    }
}
