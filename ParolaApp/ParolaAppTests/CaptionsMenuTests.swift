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
}
