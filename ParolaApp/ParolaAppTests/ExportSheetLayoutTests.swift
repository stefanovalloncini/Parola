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
        let sheet = try source()
        #expect(sheet.contains(".toggleStyle(.checkbox)"))
        #expect(sheet.contains("@Environment(\\.isEnabled) private var isEnabled"))
        #expect(!sheet.contains(".frame(width: 180"))
    }
}
