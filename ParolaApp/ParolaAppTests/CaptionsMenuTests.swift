import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Captions menu")
struct CaptionsMenuTests {
    /// The items AppKit builds from the menu's content, as the menu bar shows them.
    private func titles(features: Set<ParolaFeature>) -> [String] {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("captions-menu"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: features
        ))
        let menu = NSHostingMenu(rootView: CaptionsCommands(
            model: model, scratchpad: ScratchpadController(), liveCaptions: LiveCaptionsController()
        ))
        menu.update()
        return menu.items.map(\.title)
    }

    @Test("Start Dictation sits in the menu with Start Live Captions, where the build has dictation")
    func startDictation() {
        let everything = titles(features: Set(ParolaFeature.allCases))
        #expect(everything.contains("Start Dictation"), "\(everything)")
        #expect(everything.contains("Start Live Captions"), "\(everything)")

        let noDictation = titles(features: Set(ParolaFeature.allCases).subtracting([.dictation]))
        #expect(!noDictation.contains("Start Dictation"), "\(noDictation)")
    }

    private func makeModel() -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("captions-menu-state"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), enabledFeaturesOverride: Set(ParolaFeature.allCases)
        ))
    }

    private func menuItems(_ model: AppModel) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: CaptionsCommands(
            model: model, scratchpad: ScratchpadController(), liveCaptions: LiveCaptionsController()
        ))
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
