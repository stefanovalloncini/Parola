import AppKit
import Testing
@testable import Parola

@MainActor
@Suite("Library list primary action")
struct LibraryOpenRequestTests {
    @Test("a double-click or Return on one row opens it in the main pane")
    func oneRowOpensInPlace() {
        #expect(LibraryListContent.openRequest(for: ["a"], modifiers: []) == .init(id: "a", inNewWindow: false))
    }

    @Test("Option opens the row in a window of its own, whatever else is held")
    func optionOpensAWindow() {
        #expect(LibraryListContent.openRequest(for: ["a"], modifiers: .option) == .init(id: "a", inNewWindow: true))
        #expect(LibraryListContent.openRequest(for: ["a"], modifiers: [.option, .shift]) == .init(id: "a", inNewWindow: true))
        #expect(LibraryListContent.openRequest(for: ["a"], modifiers: .command) == .init(id: "a", inNewWindow: false))
    }

    @Test("a selection of several rows, or none, opens nothing")
    func severalRowsOpenNothing() {
        #expect(LibraryListContent.openRequest(for: ["a", "b"], modifiers: []) == nil)
        #expect(LibraryListContent.openRequest(for: ["a", "b"], modifiers: .option) == nil)
        #expect(LibraryListContent.openRequest(for: [], modifiers: []) == nil)
    }
}
