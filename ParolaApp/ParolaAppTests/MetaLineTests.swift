import SwiftUI
import Testing
@testable import Parola

@Suite("Row meta line")
struct MetaLineTests {

    @Test("absent facts leave no gap in the line")
    func presentFactsOnly() {
        #expect(MetaLine.present(["12 Sep 2026", nil, "English"]) == ["12 Sep 2026", "English"])
        #expect(MetaLine.present([nil, "", "English"]) == ["English"])
        #expect(MetaLine.present([nil, nil]).isEmpty)
        #expect(MetaLine.present(["", ""]).isEmpty)
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
