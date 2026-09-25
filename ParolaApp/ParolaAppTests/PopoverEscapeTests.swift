import AppKit
import Testing
@testable import Parola

@Suite("Popover Escape")
struct PopoverEscapeTests {
    @Test("a bare Escape in the popover's window or the one it hangs off closes it, whatever non-editable view has focus")
    func bareEscapeCloses() {
        #expect(PopoverEscape.closes(keyCode: 53, modifiers: [], targetsPopover: true, textInputActive: false))
        #expect(PopoverEscape.closes(keyCode: 53, modifiers: [.function], targetsPopover: true, textInputActive: false))
    }

    @Test("other keys and modified Escapes pass through")
    func otherKeysPass() {
        #expect(!PopoverEscape.closes(keyCode: 49, modifiers: [], targetsPopover: true, textInputActive: false))
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [.command], targetsPopover: true, textInputActive: false))
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [.option], targetsPopover: true, textInputActive: false))
    }

    @Test("Escape in another window, or in a field being typed in, keeps its own meaning")
    func otherWindowsAndFieldsKeepEscape() {
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [], targetsPopover: false, textInputActive: false))
        #expect(!PopoverEscape.closes(keyCode: 53, modifiers: [], targetsPopover: true, textInputActive: true))
    }
}
