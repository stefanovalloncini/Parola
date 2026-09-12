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
}
