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

    @Test("Style and Format keep their chips, and VoiceOver hears which one is chosen")
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

    @Test("pressing a chip chooses it, and pressing the chosen one keeps it")
    func pressingAChipChoosesIt() {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let pressedMarkdown = HostedAccessibility.press(endingWith: "Export.Button.Format.md", in: hosted.host)
        #expect(pressedMarkdown)
        #expect(model.exportSheetSpec.format == .md)
        hosted.host.layoutSubtreeIfNeeded()
        let pressedAgain = HostedAccessibility.press(endingWith: "Export.Button.Format.md", in: hosted.host)
        #expect(pressedAgain)
        #expect(model.exportSheetSpec.format == .md)
        let pressedSubtitles = HostedAccessibility.press(endingWith: "Export.Button.Style.subtitles", in: hosted.host)
        #expect(pressedSubtitles)
        #expect(model.exportSheetSpec.style == .subtitles)
    }

    /// Where Tab stops for the control VoiceOver sees at this frame.
    private func keyView(at frame: CGRect, in hosted: HostedWindow) -> NSView? {
        var seen: Set<ObjectIdentifier> = []
        var next = hosted.host.nextKeyView
        while let view = next, seen.insert(ObjectIdentifier(view)).inserted {
            let onScreen = hosted.window.convertToScreen(view.convert(view.bounds, to: nil))
            if abs(onScreen.midX - frame.midX) < 1, abs(onScreen.midY - frame.midY) < 1 { return view }
            next = view.nextKeyView
        }
        return nil
    }

    @Test("choosing a chip leaves the keyboard and VoiceOver on it")
    func choosingAChipKeepsFocus() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let leaf = "Export.Button.Format.md"
        let before = HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(leaf) == true }
        let markdown = try #require(before, "no \(leaf)")
        let found = keyView(at: markdown.frame, in: hosted)
        let chip = try #require(found, "Tab never stops on \(leaf)")
        let focused = hosted.window.makeFirstResponder(chip)
        #expect(focused)
        let pressed = HostedAccessibility.press(endingWith: leaf, in: hosted.host)
        #expect(pressed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosted.host.layoutSubtreeIfNeeded()
        #expect(model.exportSheetSpec.format == .md)
        let responder = hosted.window.firstResponder
        #expect(responder === chip, "the keyboard moved to \(String(describing: responder))")
        let after = HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(leaf) == true }
        let sameElement = after?.object === markdown.object
        #expect(sameElement, "VoiceOver's element for \(leaf) was replaced")
        #expect(after?.isSelected == true)
        #expect(after?.role == NSAccessibility.Role.checkBox.rawValue)
    }

    @Test("the chosen Style and Format still stand out while the sheet's window isn't key")
    func chosenChipsShowInAnInactiveWindow() throws {
        let model = makeModel()
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let bitmap = try #require(hosted.host.bitmapImageRepForCachingDisplay(in: hosted.host.bounds))
        hosted.host.cacheDisplay(in: hosted.host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / hosted.host.bounds.width
        let window = hosted.window.frame
        func bezel(_ leaf: String) throws -> NSColor {
            let found = elements.first { $0.identifier?.hasSuffix(leaf) == true }
            let chip = try #require(found, "no \(leaf)").frame
            let x = Int((chip.minX - window.minX + 5) * scale)
            let y = Int((window.maxY - chip.midY) * scale)
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let chosenStyle = try bezel("Export.Button.Style.transcript")
        let otherStyle = try bezel("Export.Button.Style.subtitles")
        let chosenFormat = try bezel("Export.Button.Format.txt")
        let otherFormat = try bezel("Export.Button.Format.md")
        func apart(_ one: NSColor, _ other: NSColor) -> CGFloat {
            [
                one.redComponent - other.redComponent,
                one.greenComponent - other.greenComponent,
                one.blueComponent - other.blueComponent,
                one.alphaComponent - other.alphaComponent,
            ].map(abs).max() ?? 0
        }
        let styleGap = apart(chosenStyle, otherStyle)
        let formatGap = apart(chosenFormat, otherFormat)
        #expect(styleGap > 0.02, "\(chosenStyle) vs \(otherStyle)")
        #expect(formatGap > 0.02, "\(chosenFormat) vs \(otherFormat)")
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
