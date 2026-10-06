import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Export sheet layout", .serialized)
struct ExportSheetLayoutTests {
    private func makeModel() -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            filePicker: TestFilePicker(),
            libraryURL: makeTempLibraryURL("export-sheet-layout")
        )
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Goodbye.", speaker: "Grace"),
            ],
            language: "en",
            modelName: "stub"
        )
        model.openExportSheet()
        model.setExportSpec(ExportSpec(style: .transcript, format: .txt))
        return model
    }

    private func host(_ model: AppModel) -> HostedWindow {
        HostedWindow(ExportSheet().environment(model), width: 760, height: 620)
    }

    private func source() throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ExportSheetLayoutTests.swift",
            with: "ParolaApp/Views/Export/ExportSheet.swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("each option's checkbox sits beside its label, and a row that can't apply dims")
    func checkboxesSitBesideTheirLabels() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let firstStyle = elements.first { $0.identifier?.hasSuffix("Export.Button.Style.transcript") == true }
        let heading = try #require(firstStyle)
        for leaf in ["Timestamps", "EndTimestamps", "Milliseconds", "Speakers"] {
            let found = elements.first { $0.identifier?.hasSuffix("Export.Toggle.\(leaf)") == true }
            let toggle = try #require(found, "no \(leaf)")
            #expect(toggle.frame.minX - heading.frame.minX < 40, "\(leaf) sits \(toggle.frame.minX - heading.frame.minX) pt in")
        }
        let groupingDetail = elements.first { $0.words.contains("Merge a speaker's consecutive segments into one.") }
        let detail = try #require(groupingDetail)
        #expect(detail.frame.height < 20, "the picker's detail wraps to \(detail.frame.height) pt")
        let sheet = try source()
        #expect(sheet.contains(".toggleStyle(.checkbox)"))
        #expect(sheet.contains("@Environment(\\.isEnabled) private var isEnabled"))
        #expect(!sheet.contains(".frame(width: 180"))
    }

    @Test("Style and Format keep their pills, and VoiceOver hears which one is chosen")
    func chosenPillsReadAsSelected() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        func pill(_ leaf: String) throws -> HostedAccessibility.Element {
            let found = elements.first { $0.identifier?.hasSuffix(leaf) == true }
            return try #require(found, "no \(leaf)")
        }
        let chosenStyle = try pill("Export.Button.Style.transcript")
        let otherStyle = try pill("Export.Button.Style.subtitles")
        let chosenFormat = try pill("Export.Button.Format.txt")
        let otherFormat = try pill("Export.Button.Format.md")
        #expect(chosenStyle.isSelected)
        #expect(!otherStyle.isSelected)
        #expect(chosenFormat.isSelected)
        #expect(!otherFormat.isSelected)
    }

    @Test("Close sits beside Export on the trailing side, and Copy to Clipboard leads")
    func closeSitsBesideTheDefaultButton() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        func frame(_ leaf: String) throws -> CGRect {
            let found = elements.first { $0.identifier?.hasSuffix(leaf) == true }
            return try #require(found, "no \(leaf)").frame
        }
        let copy = try frame("Export.Button.Copy")
        let close = try frame("Export.Button.Close")
        let export = try frame("Export.Button.Export")
        #expect(copy.minX < close.minX)
        #expect(close.maxX <= export.minX)
        #expect(export.minX - close.maxX < 24)
    }

    @Test("Copy to Clipboard says Copied once the text is on the pasteboard")
    func copyConfirms() async throws {
        let model = makeModel()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("export-layout-\(UUID())"))
        let run = model.copyExportToPasteboard(pasteboard: pasteboard)
        let landed = await run?.value
        #expect(landed == true)
        #expect(pasteboard.string(forType: .string)?.isEmpty == false)
        let sheet = try source()
        #expect(sheet.contains(#"Text(copied ? "Copied" : "Copy to Clipboard")"#))
        #expect(sheet.contains("if await model.copyExportToPasteboard(pasteboard: .general)?.value == true { showCopied() }"))
    }
}
