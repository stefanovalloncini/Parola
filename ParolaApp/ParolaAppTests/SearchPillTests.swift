import SwiftUI
import Testing
@testable import Parola

@MainActor
@Suite("Search pill")
struct SearchPillTests {
    /// Esc clears only where a screen asked for it: everywhere else it has to keep reaching the sheet or window.
    @Test("clearing on Esc is off unless the call site asks for it")
    func escapeClearingIsOptIn() {
        #expect(SearchPill(text: .constant("lancio")).clearsOnEscape == false)
        #expect(SearchPill(text: .constant("lancio"), placeholder: "Search files…").clearsOnEscape == false)
        #expect(SearchPill(text: .constant("lancio"), clearsOnEscape: true).clearsOnEscape)
    }

    @Test(
        "Esc clears only when the screen asked for it and there is something to clear",
        arguments: [
            (clears: true, empty: false, outcome: SearchPill.EscapeOutcome.clear),
            (clears: true, empty: true, outcome: SearchPill.EscapeOutcome.ignore),
            (clears: false, empty: false, outcome: SearchPill.EscapeOutcome.ignore),
            (clears: false, empty: true, outcome: SearchPill.EscapeOutcome.ignore),
        ]
    )
    func escapeGuardTable(clears: Bool, empty: Bool, outcome: SearchPill.EscapeOutcome) {
        #expect(SearchPill.escapeOutcome(clearsOnEscape: clears, isEmpty: empty) == outcome)
    }
}
