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
}
