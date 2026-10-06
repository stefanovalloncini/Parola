import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Dictation menu")
struct DictationMenuTests {
    @Test("the Dictation menu leads with Start Dictation, then the Scratchpad")
    func dictationMenu() {
        let titles = menuItems(makeModel()).map(\.title)
        #expect(titles == ["Start Dictation", "Show Scratchpad"], "\(titles)")
    }

    private func makeModel() -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("captions-menu-state"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), enabledFeaturesOverride: Set(ParolaFeature.allCases)
        ))
    }

    private func menuItems(_ model: AppModel) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: DictationCommands(model: model, scratchpad: ScratchpadController()))
        menu.update()
        return menu.items
    }

    private func dictationItem(in items: [NSMenuItem]) -> NSMenuItem? {
        items.first { $0.title == "Start Dictation" || $0.title == "Stop Dictation" }
    }

    @Test("Start Dictation flips to Stop Dictation while dictation is listening, as the menu bar item does")
    func dictationTitleFollowsState() {
        let model = makeModel()
        #expect(dictationItem(in: menuItems(model))?.title == "Start Dictation")

        model.dictationState = .listening
        #expect(dictationItem(in: menuItems(model))?.title == "Stop Dictation")
    }

    @Test("Start Dictation is disabled during the introduction, like Show Scratchpad")
    func dictationDisabledDuringIntroduction() {
        let model = makeModel()
        model.introduction.restart()
        #expect(model.introduction.isPresented)

        let items = menuItems(model)
        #expect(items.first { $0.title == "Show Scratchpad" }?.isEnabled == false)
        #expect(dictationItem(in: items)?.isEnabled == false)
    }
}
