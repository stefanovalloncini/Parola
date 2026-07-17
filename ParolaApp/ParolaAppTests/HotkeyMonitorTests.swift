import AppKit
import Testing
@testable import Parola
import ParolaDictation

@Suite("Hotkey transitions")
struct HotkeyMonitorTests {
    @Test("keyUp releases even after the modifier was let go first")
    func keyUpWithoutModifierStillReleases() {
        let out = GlobalHotkeyMonitor.transition(type: .keyUp, flags: [], required: .option, isPressed: true)
        #expect(out.event == .release)
        #expect(out.isPressed == false)
    }

    @Test("keyDown without the required modifier is ignored")
    func keyDownRequiresModifier() {
        let out = GlobalHotkeyMonitor.transition(type: .keyDown, flags: [], required: .option, isPressed: false)
        #expect(out.event == nil)
        #expect(out.isPressed == false)
    }

    @Test("keyDown with extra modifiers held still presses")
    func keyDownAcceptsSuperset() {
        let out = GlobalHotkeyMonitor.transition(
            type: .keyDown,
            flags: [.option, .shift, .function],
            required: .option,
            isPressed: false
        )
        #expect(out.event == .press)
        #expect(out.isPressed == true)
    }

    @Test("auto-repeat keyDown while pressed emits nothing")
    func repeatKeyDownIgnored() {
        let out = GlobalHotkeyMonitor.transition(type: .keyDown, flags: [.option], required: .option, isPressed: true)
        #expect(out.event == nil)
        #expect(out.isPressed == true)
    }

    @Test("keyUp while not pressed emits nothing")
    func keyUpWhileIdleIgnored() {
        let out = GlobalHotkeyMonitor.transition(type: .keyUp, flags: [], required: [], isPressed: false)
        #expect(out.event == nil)
        #expect(out.isPressed == false)
    }
}
