import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Dictation HUD stop", .serialized)
struct DictationHUDStopTests {
    @Test("every HUD style offers Stop while listening, and a click on it stops dictation", arguments: DictationIndicatorStyle.allCases)
    func stopInEveryStyle(style: DictationIndicatorStyle) {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("hudstop"))
        model.dictationIndicatorStyleRaw = style.rawValue
        let controller = DictationController()
        controller.handleStateChange(.listening, generation: controller.coordinatorGeneration)
        var stops = 0
        let hosted = HostedWindow(
            DictationView(model: model, controller: controller, onStop: { stops += 1 }).frame(width: 400, height: 120)
        )
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "HUD.Button.Stop", in: hosted.host))
        #expect(stops == 1)
    }
}
