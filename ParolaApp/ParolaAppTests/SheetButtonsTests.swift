import AppKit
import SwiftUI
import Testing
@testable import Parola

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
}
