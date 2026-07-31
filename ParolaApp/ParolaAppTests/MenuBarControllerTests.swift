import Foundation
import Testing
@testable import Parola
import ParolaDictation

@MainActor
@Suite("Menu bar dictation item")
struct MenuBarControllerTests {
    @Test("the item stops only a listening session and starts otherwise")
    func dictationMenuItemStates() {
        let listening = MenuBarController.dictationMenuItem(for: .listening)
        #expect(listening.title == "Stop Dictation")
        #expect(listening.stops)

        let idle = MenuBarController.dictationMenuItem(for: .idle)
        #expect(idle.title == "Start Dictation")
        #expect(idle.stops == false)

        let transcribing = MenuBarController.dictationMenuItem(for: .transcribing)
        #expect(transcribing.title == "Start Dictation")
        #expect(transcribing.stops == false)

        let failed = MenuBarController.dictationMenuItem(for: .failed("x"))
        #expect(failed.title == "Start Dictation")
        #expect(failed.stops == false)
    }
}

@MainActor
@Suite("Menu bar mode")
struct MenuBarModeTests {
    @Test("visibility mode follows the extra toggle and dictation enablement", arguments: [
        (false, false, MenuBarController.Mode.hidden),
        (true, false, .full),
        (true, true, .full),
        (false, true, .dictationOnly),
    ] as [(Bool, Bool, MenuBarController.Mode)])
    func modeMatrix(showExtra: Bool, dictationEnabled: Bool, expected: MenuBarController.Mode) {
        #expect(MenuBarController.Mode(showExtra: showExtra, dictationEnabled: dictationEnabled) == expected)
    }

    @Test("icon reflects dictation state only while dictation is enabled")
    func iconMapping() {
        #expect(MenuBarController.symbolName(dictationEnabled: false, state: .listening) == "waveform")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .idle) == "mic")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .listening) == "mic.fill")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .transcribing) == "waveform")
        #expect(MenuBarController.symbolName(dictationEnabled: true, state: .failed("boom")) == "mic.slash")
    }
}
