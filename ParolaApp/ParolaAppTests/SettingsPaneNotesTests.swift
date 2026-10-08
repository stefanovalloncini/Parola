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

    /// A row's note sits at the leading edge and its buttons at the trailing edge, on the same row.
    private func expectRow(note prefix: String, button suffix: String, in found: [HostedAccessibility.Element],
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let note = text(startingWith: prefix, in: found) else {
            Issue.record("no note starting \(prefix)", sourceLocation: sourceLocation)
            return
        }
        guard let button = leaf(suffix, in: found) else {
            Issue.record("no \(suffix)", sourceLocation: sourceLocation)
            return
        }
        #expect(note.frame.maxX <= button.frame.minX, "\(suffix) isn't at the trailing edge of its note", sourceLocation: sourceLocation)
        #expect(button.frame.maxY > note.frame.minY, "\(suffix) sits under its note", sourceLocation: sourceLocation)
    }

    @Test("Advanced: each block is a row, its note at the leading edge and its buttons at the trailing edge")
    func advancedBlocksAreRows() {
        let found = elements(AdvancedPane(), model: makeModel())
        expectRow(note: "Save your settings to a", button: "Advanced.Button.ExportSettings", in: found)
        expectRow(note: "Save your settings to a", button: "Advanced.Button.ImportSettings", in: found)
        expectRow(note: "Kept for 7 days", button: "Advanced.Button.ExportDiagnostics", in: found)
        expectRow(note: "Kept for 7 days", button: "Advanced.Button.DeleteDiagnostics", in: found)
        expectRow(note: "Returns every setting to its default", button: "Advanced.Button.ResetAll", in: found)
    }

    @Test("MCP & Automation: buttons sit at the trailing edge of their rows, and the snippet is plain text in its box")
    func automationBlocksAreRows() throws {
        let found = elements(AutomationPane(), model: makeModel())
        expectRow(note: "Drop this into your MCP client", button: "Automation.Button.CopySnippet", in: found)
        let path = try #require(found.first { $0.words.contains { $0.hasSuffix("parola-mcp") && $0.hasPrefix("/") } },
                                "this build should find parola-mcp")
        let reveal = try #require(leaf("Automation.Button.RevealMcpBinary", in: found))
        #expect(path.frame.maxX <= reveal.frame.minX)
        #expect(reveal.frame.maxY > path.frame.minY)
        let snippet = try #require(found.first { $0.words.contains { $0.contains("mcpServers") } })
        let scrollers = found.filter { $0.role == NSAccessibility.Role.scrollArea.rawValue && $0.frame.contains(snippet.frame) }
        #expect(scrollers.count <= 1, "the snippet scrolls in a box of its own")
    }

    @Test("Dictation's preview is a section with its own heading, not a label inside a box")
    func dictationPreviewHasAHeading() throws {
        let found = elements(DictationPane(), model: makeModel(), height: 2400)
        let preview = try #require(found.first { $0.words.contains(String(localized: "Preview")) })
        #expect(preview.role == "AXHeading", "Preview reads as \(preview.role ?? "nothing")")
    }
}
