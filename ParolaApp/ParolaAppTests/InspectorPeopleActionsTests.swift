import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Inspector People actions")
struct InspectorPeopleActionsTests {
    private func makeModel() -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("inspector-people"))
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Ada")],
            language: "en",
            modelName: "stub"
        )
        return model
    }

    @Test("the People menu holds Rename Speakers… and Manage People…, and each opens its sheet")
    func peopleMenuOpensBothSheets() {
        let model = makeModel()
        let hosted = HostedWindow(VStack(alignment: .leading) { PeopleActions() }.environment(model), width: 320, height: 200)
        defer { hosted.close() }
        let names = HostedAccessibility.elements(in: hosted.host)
            .filter { $0.identifier?.hasPrefix("Inspector.Button.") == true }
            .compactMap(\.name)
        #expect(names == ["Rename Speakers…", "Manage People…"])

        #expect(HostedAccessibility.press(endingWith: "Inspector.Button.RenameSpeakers", in: hosted.host))
        #expect(model.showingSpeakersSheet)
        #expect(HostedAccessibility.press(endingWith: "Inspector.Button.ManagePeople", in: hosted.host))
        #expect(model.showingPeopleSheet)
    }

    @Test("Assign… stays whole beside a long speaker label, inside the inspector's margin", arguments: ["en_US", "it_IT"])
    func assignFitsBesideALongLabel(_ identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let model = makeModel()
        let label = "SPEAKER_WITH_A_LABEL_FAR_TOO_LONG_FOR_THE_COLUMN"
        let row = SpeakerPersonRow(label: label, segmentCount: 171)
            .padding(.horizontal, DS.Spacing.regular)
            .environment(model)
            .environment(\.locale, locale)
        let hosted = HostedWindow(row, width: MainWindowLayout.inspectorWidth, height: 60)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let assignMenu = elements.first { $0.identifier?.hasSuffix("Inspector.Menu.Assign") == true }
        let assign = try #require(assignMenu)
        let whole = NSHostingView(rootView: Text("Assign…").font(DS.Font.secondary).environment(\.locale, locale)).fittingSize
        let rightEdge = hosted.window.frame.maxX - DS.Spacing.regular + 0.5
        #expect(assign.frame.width >= whole.width - 0.5, "Assign… is \(assign.frame.width) pt of \(whole.width)")
        #expect(assign.frame.maxX <= rightEdge, "Assign… ends \(assign.frame.maxX - rightEdge) pt past the inspector's margin")
        let spokenCount = elements.first { $0.words.contains("171 segments") || $0.words.contains("171 segmenti") }
        let count = try #require(spokenCount, "the count reads as segments")
        #expect(count.frame.minX >= assign.frame.maxX, "the count sits after Assign…")
        #expect(count.frame.maxX <= rightEdge)
    }
}
