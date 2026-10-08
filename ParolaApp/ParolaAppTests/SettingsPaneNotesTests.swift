import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Where a pane's explanations sit in its grouped form: under the box they explain, never a box of their own.
@MainActor
@Suite("Settings pane notes", .serialized)
struct SettingsPaneNotesTests {
    private func makeModel() -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("settings-notes"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        ))
    }

    private func elements(_ pane: some View, model: AppModel, height: CGFloat = 1600) -> [HostedAccessibility.Element] {
        let hosted = HostedWindow(
            pane.environment(model).environment(LiveCaptionsController(showsPanel: false)),
            width: 760, height: height
        )
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host)
    }

    private func text(startingWith prefix: String, in found: [HostedAccessibility.Element]) -> HostedAccessibility.Element? {
        found.first { $0.words.contains { $0.hasPrefix(prefix) } }
    }

    private func leaf(_ suffix: String, in found: [HostedAccessibility.Element]) -> HostedAccessibility.Element? {
        found.first { $0.identifier?.hasSuffix(suffix) == true }
    }

    @Test("Live Captions' intro is a note under its box, not a row of its own")
    func liveCaptionsIntroIsAFooter() throws {
        let found = elements(LiveCaptionsPane(), model: makeModel())
        let intro = try #require(text(startingWith: "Live captions transcribe the microphone", in: found))
        let lastRow = try #require(text(startingWith: "Translate captions live as you speak", in: found))
        let start = try #require(leaf("LiveCaptions.Button.StartStop", in: found))
        #expect(intro.frame.maxY <= lastRow.frame.minY, "the intro sits above the rows")
        #expect(lastRow.frame.minY - intro.frame.maxY < 28, "the intro sits \(lastRow.frame.minY - intro.frame.maxY) pt under the box")
        #expect(start.frame.minY > lastRow.frame.maxY)
    }
}
