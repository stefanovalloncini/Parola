import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("AI panes offer the next step where they show a state")
struct AIPaneActionsTests {
    private func makeModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("ai-pane-actions"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
            language: "en",
            modelName: "stub"
        )
        return model
    }

    private func identifiers(in hosted: HostedWindow) -> [String] {
        HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
    }

    @Test("a failed summary offers Try Again where the error shows, and it runs the summary again")
    func failedSummaryOffersTryAgain() async {
        let model = makeModel()
        model.summaryError = "The model stopped answering."
        model.summariseOperation = { _, _ in Summary(text: "second try") }
        let hosted = HostedWindow(SummaryPane().environment(model))
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "Summary.Button.TryAgain", in: hosted.host))
        let landed = await waitUntil { model.transcript?.summary?.text == "second try" }
        #expect(landed)
        #expect(model.summaryError == nil)
    }
}
