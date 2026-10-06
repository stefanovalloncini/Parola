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
    @Test("Rename Speakers… and Manage People… fit the inspector whole", arguments: ["en_US", "it_IT"])
    func peopleActionsFit(_ identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("inspector-people"))
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Ada")],
            language: "en",
            modelName: "stub"
        )
        let inspector = TranscriptInspector(mode: .constant(.format), inspectorVisible: .constant(true))
            .environment(model)
            .environment(\.locale, locale)
        let hosted = HostedWindow(inspector, width: MainWindowLayout.inspectorWidth, height: 900)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let rightEdge = hosted.window.frame.maxX - DS.Spacing.regular + 0.5
        let pills: [(leaf: String, title: LocalizedStringKey)] = [
            ("Inspector.Button.RenameSpeakers", "Rename Speakers…"),
            ("Inspector.Button.ManagePeople", "Manage People…"),
        ]
        for pill in pills {
            let found = elements.first { $0.identifier?.hasSuffix(pill.leaf) == true }
            let frame = try #require(found, "no \(pill.leaf)").frame
            let whole = naturalSize(pill.title, locale: locale)
            #expect(frame.width >= whole.width - 0.5, "\(pill.leaf) is \(frame.width) pt of \(whole.width)")
            #expect(frame.height <= whole.height + 0.5, "\(pill.leaf) wraps to \(frame.height) pt")
            #expect(frame.maxX <= rightEdge, "\(pill.leaf) ends \(frame.maxX - rightEdge) pt past the inspector's margin")
        }
    }

    private func naturalSize(_ title: LocalizedStringKey, locale: Locale) -> CGSize {
        let pill = Button(title) {}
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            .environment(\.locale, locale)
        return NSHostingView(rootView: pill).fittingSize
    }
}
