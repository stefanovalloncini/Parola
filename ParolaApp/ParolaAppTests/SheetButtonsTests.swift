import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// One button style per sheet: the system's own, large in the footer.
@MainActor
@Suite("Sheet buttons")
struct SheetButtonsTests {
    nonisolated static let sheets = [
        "Views/BurnStyleSheet",
        "Views/DuplicateImportSheet",
        "Views/Export/ExportSheet",
        "Views/People/ManagePeopleSheet",
        "Views/PromptOutputSheet",
        "Views/Settings/AIServiceEditor",
        "Views/Settings/ObsidianDestinationEditor",
        "Views/Settings/RemoteAIAcknowledgementSheet",
        "Views/SpeakersSheet",
        "Views/Transcript/SegmentNoteSheet",
        "Views/YouTubeURLSheet",
    ]

    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/SheetButtonsTests.swift", with: "ParolaApp/\(name).swift")
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func size(_ button: some View) -> CGSize {
        NSHostingView(rootView: button).fittingSize
    }

    @Test("the footer's buttons are the system's, at the large size")
    func footerButtonsAreLargeSystemButtons() {
        let primary = size(Button("Save") {}.sheetPrimaryAction())
        let secondary = size(Button("Cancel") {}.sheetSecondaryAction())
        let largeProminent = size(Button("Save") {}.buttonStyle(.borderedProminent).controlSize(.large))
        let largeBordered = size(Button("Cancel") {}.buttonStyle(.bordered).controlSize(.large))
        let regularProminent = size(Button("Save") {}.buttonStyle(.borderedProminent))
        #expect(primary == largeProminent)
        #expect(secondary == largeBordered)
        #expect(primary != regularProminent)
    }

    @Test("every sheet's default button wears the shared footer style", arguments: sheets)
    func everyFooterSharesTheStyle(_ sheet: String) throws {
        let text = try source(sheet)
        #expect(text.contains(".sheetPrimaryAction()"))
    }

    @Test("a sheet's content buttons are the system's too, so the sheet has one button style", arguments: sheets)
    func contentButtonsAreSystemButtons(_ sheet: String) throws {
        let text = try source(sheet)
        #expect(!text.contains("DSPillButtonStyle"), "\(sheet) still draws the app's pills")
    }

    @Test("Speakers' Recent names show whole, each on one line")
    func recentNamesShowWhole() async throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("sheet-buttons-recent"))
        await model.addPerson(named: "Marco Bianchi")
        await model.addPerson(named: "Alessandra Ferraresi")
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Ciao.", speaker: "Speaker 1")],
            language: "it",
            modelName: "stub"
        )
        let hosted = HostedWindow(SpeakersSheet(transcript: transcript).environment(model), width: 480, height: 640)
        defer { hosted.close() }
        var chips: [HostedAccessibility.Element] = []
        for _ in 0..<100 where chips.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
            hosted.host.layoutSubtreeIfNeeded()
            chips = HostedAccessibility.elements(in: hosted.host).filter { $0.identifier?.hasSuffix("Speakers.Button.Suggestion") == true }
        }
        #expect(chips.count == 2)
        for chip in chips {
            let name = try #require(chip.name)
            let whole = size(Button(name) {}.buttonStyle(.bordered))
            #expect(chip.frame.width >= whole.width - 0.5, "\(name) is \(chip.frame.width) pt of \(whole.width)")
            #expect(chip.frame.height <= whole.height + 0.5, "\(name) wraps to \(chip.frame.height) pt")
        }
    }
}
