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

    /// A warning sits right under the row it is about, as a footer or part of that row, never a box of its own.
    private func expectUnder(_ warning: String, row prefix: String, in found: [HostedAccessibility.Element],
                             sourceLocation: SourceLocation = #_sourceLocation) {
        guard let note = text(startingWith: warning, in: found) else {
            Issue.record("no warning starting \(warning)", sourceLocation: sourceLocation)
            return
        }
        guard let row = text(startingWith: prefix, in: found) else {
            Issue.record("no row note starting \(prefix)", sourceLocation: sourceLocation)
            return
        }
        let gap = row.frame.minY - note.frame.maxY
        #expect(gap >= 0, "\(warning) sits above its row", sourceLocation: sourceLocation)
        #expect(gap < 28, "\(warning) sits \(gap) pt under its row", sourceLocation: sourceLocation)
    }

    @Test("Transcription Defaults' warnings sit under its box, beside the note there")
    func transcriptionDefaultsWarnings() throws {
        let model = makeModel()
        model.diarize = true
        let warning = try #require(model.diarizeMismatchWarning)
        let found = elements(TranscriptionDefaultsPane(), model: model)
        expectUnder(warning, row: "Splits the transcript by speaker", in: found)
        expectUnder("The Library page shows these same settings", row: warning, in: found)
    }

    @Test("Translation's warning sits under the switch it is about")
    func translationWarning() {
        let model = makeModel()
        model.translate = true
        let warning = model.translateMismatchWarning ?? "missing"
        let found = elements(TranslationPane(), model: model)
        expectUnder(warning, row: "Applies to new file, mic, batch", in: found)
    }

    @Test("Live Captions' translate warning sits under its box with the intro")
    func liveCaptionsWarning() {
        let model = makeModel()
        model.translate = true
        let warning = model.translateMismatchWarning ?? "missing"
        let found = elements(LiveCaptionsPane(), model: model)
        expectUnder(warning, row: "Translate captions live as you speak", in: found)
    }

    @Test("Dictation's model warning is part of the Model row, beside Change…")
    func dictationModelWarning() throws {
        let model = makeModel()
        let warning = try #require(model.dictationModelWarnings.first)
        let found = elements(DictationPane(), model: model, height: 2400)
        expectUnder(warning, row: "Dictation uses the model set", in: found)
        expectRow(note: warning, button: "Dictation.Button.ChangeModel", in: found)
    }

    @Test("Local Models' error sits under the Storage box, with its Dismiss")
    func localModelsError() async throws {
        let model = makeModel()
        await model.awaitModelListRefresh()
        model.modelActionError = "Couldn't delete the model: the folder is locked."
        let found = elements(ModelsSettingsPane(), model: model, height: 2400)
        expectUnder("Couldn't delete the model", row: "Models folder:", in: found)
        #expect(leaf("Models.Button.DismissError", in: found) != nil)
    }

    @Test("Microphone access is a row of the pane's first box: the note at the leading edge, the fix at the trailing edge")
    func microphoneAccessRow() {
        let found = elements(SettingsForm { Section { MicrophoneAccessRow() } }, model: makeModel(), height: 300)
        expectRow(note: "Parola needs the microphone to record", button: "Microphone.Button.OpenAccessSettings", in: found)
    }

    @Test("General's Title and Summary instructions are full-width fields under their labels", arguments: [
        ("Title instructions", "General.TextField.CustomTitlePrompt"),
        ("Summary instructions", "General.TextField.CustomSummaryPrompt"),
    ])
    func instructionFieldsSpanTheRow(_ title: String, _ field: String) throws {
        let found = elements(GeneralPane(), model: makeModel(), height: 2000)
        let label = try #require(found.first { $0.words.contains(String(localized: String.LocalizationValue(title))) && $0.role == "AXStaticText" })
        let input = try #require(leaf(field, in: found))
        let toggle = try #require(leaf("General.Toggle.ShowAISummaries", in: found))
        #expect(input.frame.maxY <= label.frame.minY, "\(field) isn't under its label")
        #expect(abs(input.frame.minX - label.frame.minX) < 4, "\(field) doesn't start at its label's edge")
        #expect(input.frame.maxX >= toggle.frame.maxX - 4, "\(field) stops short of the row's trailing edge")
    }
}
