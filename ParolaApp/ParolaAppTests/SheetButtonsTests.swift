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

    /// Drawn as in a key window, where a tint shows; the test host's own windows are never key.
    private func keyWindowPixels(_ button: some View, tint: Color?) -> Data? {
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: button.tint(tint).environment(\.controlActiveState, .key).padding(8))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    @Test("in a key window the accent fills only the default button; the other buttons keep the system's grey")
    func onlyTheDefaultButtonTakesTheAccent() {
        let accent = Color(red: 0.2, green: 0.7, blue: 0.3)
        let cancel = keyWindowPixels(Button("Cancel") {}.sheetSecondaryAction(), tint: accent)
        let systemCancel = keyWindowPixels(Button("Cancel") {}.buttonStyle(.bordered).controlSize(.large), tint: nil)
        let test = keyWindowPixels(Button("Test") {}.sheetButton(), tint: accent)
        let systemTest = keyWindowPixels(Button("Test") {}.buttonStyle(.bordered), tint: nil)
        let save = keyWindowPixels(Button("Save") {}.sheetPrimaryAction(), tint: accent)
        let untintedSave = keyWindowPixels(Button("Save") {}.sheetPrimaryAction(), tint: nil)
        #expect(cancel != nil)
        #expect(cancel == systemCancel)
        #expect(test == systemTest)
        #expect(save != untintedSave)
    }

    @Test("a sheet's bordered buttons go through the shared style, so none takes the accent", arguments: sheets)
    func borderedButtonsShareTheStyle(_ sheet: String) throws {
        let text = try source(sheet)
        #expect(!text.contains(".buttonStyle(.bordered)"), "\(sheet) draws a bordered button the accent can tint")
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
