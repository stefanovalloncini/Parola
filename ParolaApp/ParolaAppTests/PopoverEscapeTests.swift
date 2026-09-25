import AppKit
import Testing
@testable import Parola

@Suite("Popover Escape")
struct PopoverEscapeTests {
    @Test("a bare Escape closes the popover, whatever non-editable view holds focus")
    func bareEscapeCloses() {
        #expect(PopoverEscape.closes(keyCode: 53, modifiers: [], textInputActive: false, sheetInFront: false))
        #expect(PopoverEscape.closes(keyCode: 53, modifiers: [.function], textInputActive: false, sheetInFront: false))
    }

    @Test("other keys and modified Escapes pass through")
    func otherKeysPass() {
        #expect(!PopoverEscape.closes(keyCode: 49, modifiers: [], textInputActive: false, sheetInFront: false))
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [.command], textInputActive: false, sheetInFront: false))
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [.option], textInputActive: false, sheetInFront: false))
    }

    @Test("a field being typed in and a sheet in front keep their own Escape")
    func fieldsAndSheetsKeepEscape() {
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [], textInputActive: true, sheetInFront: false))
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [], textInputActive: false, sheetInFront: true))
    }
}
