import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("AI panes offer the next step where they show a state")
struct AIPaneActionsTests {
    private func makeModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("ai-pane-actions"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
            language: "en",
            modelName: "stub"
        )
        return model
    }

    private func identifiers(in hosted: HostedWindow) -> [String] {
        HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
    }

    @Test("a failed summary offers Try Again where the error shows, and it runs the summary again")
    func failedSummaryOffersTryAgain() async {
        let model = makeModel()
        model.summaryError = "The model stopped answering."
        model.summariseOperation = { _, _ in Summary(text: "second try") }
        let hosted = HostedWindow(SummaryPane().environment(model))
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "Summary.Button.TryAgain", in: hosted.host))
        let landed = await waitUntil { model.transcript?.summary?.text == "second try" }
        #expect(landed)
        #expect(model.summaryError == nil)
    }

    private func blockedRun(_ kind: AIJobRegistry.Kind, on model: AppModel) {
        model.aiJobs.start(
            kind,
            for: model.selectedEntryID,
            work: { try await Task.sleep(for: .seconds(60)) },
            land: { _, _ in },
            fail: { _, _ in }
        )
    }

    @Test("a summary being written can be stopped where its progress shows, with or without an older summary")
    func summaryRunStops() async {
        let model = makeModel()
        model.summariseOperation = { _, _ in
            try await Task.sleep(for: .seconds(60))
            return Summary(text: "late")
        }
        let hosted = HostedWindow(SummaryPane().environment(model))
        defer { hosted.close() }

        model.summariseTranscript()
        #expect(model.isSummarising)
        let shownEmpty = await waitUntil { identifiers(in: hosted).contains { $0.hasSuffix("Summary.Button.Stop") } }
        #expect(shownEmpty)
        #expect(HostedAccessibility.press(endingWith: "Summary.Button.Stop", in: hosted.host))
        #expect(!model.isSummarising)

        model.transcript?.summary = Summary(text: "older")
        model.summariseTranscript()
        let shown = await waitUntil {
            identifiers(in: hosted).filter { $0.hasSuffix("Summary.Button.Stop") }.count == 1
        }
        #expect(shown)
        #expect(HostedAccessibility.press(endingWith: "Summary.Button.Stop", in: hosted.host))
        #expect(!model.isSummarising)
        #expect(model.transcript?.summary?.text == "older")
    }

    @Test("chapters and action items being found can be stopped beside their progress line")
    func inspectorRunsStop() async {
        let model = makeModel()
        let hosted = HostedWindow(VStack {
            ChaptersSection()
            ActionItemsSection()
        }.environment(model), width: 320)
        defer { hosted.close() }

        blockedRun(.chapters, on: model)
        blockedRun(.actionItems, on: model)
        let shown = await waitUntil {
            let ids = identifiers(in: hosted)
            return ids.contains { $0.hasSuffix("Chapters.Button.Stop") } && ids.contains { $0.hasSuffix("ActionItems.Button.Stop") }
        }
        #expect(shown)
        #expect(HostedAccessibility.press(endingWith: "Chapters.Button.Stop", in: hosted.host))
        #expect(!model.isExtractingChapters)
        #expect(model.isExtractingActionItems)
        #expect(HostedAccessibility.press(endingWith: "ActionItems.Button.Stop", in: hosted.host))
        #expect(!model.isExtractingActionItems)
    }

    @Test("a running prompt can be stopped from the Prompts menu, which stays open to it")
    func promptRunStops() throws {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/AIPaneActionsTests.swift",
            with: "ParolaApp/Views/PromptsMenu.swift"
        )
        let menu = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(menu.contains(#"Button("Stop Prompt") { model.stopAIRun(.prompt) }"#))
        let header = try String(contentsOfFile: path.replacingOccurrences(of: "PromptsMenu", with: "Transcript/TranscriptHeaderBar"), encoding: .utf8)
        #expect(!header.contains(".disabled(model.isRunningPrompt)"))
    }

    @Test("a chat reply can be stopped, and a new message waits until the reply ends")
    func chatReplyStopsAndWaits() throws {
        #expect(ChatPane.isSendDisabled(input: "next question", isReplying: true))
        #expect(!ChatPane.isSendDisabled(input: "next question", isReplying: false))
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/AIPaneActionsTests.swift",
            with: "ParolaApp/Views/Chat/ChatPane.swift"
        )
        let pane = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(pane.contains(#"composerGlyph("stop.fill", dimmed: false)"#))
        #expect(pane.contains(#".axLeaf("Composer.Button.Stop")"#))
        #expect(pane.contains("guard !text.isEmpty, let session, !isReplying else { return }"))
        #expect(!pane.contains("sendTask?.cancel() displayedHistory.append"))
    }

    @Test("every AI-unavailable state offers Open AI Settings…, and a plain failure note doesn't")
    func unavailableStatesOfferSettings() throws {
        let model = makeModel()
        let reason = "Apple Intelligence is turned off."
        let states: [(AnyView, String)] = [
            (AnyView(SummaryUnavailable(reason: reason)), "Summary.Button.OpenAISettings"),
            (AnyView(SummaryError(message: "The service refused the key.", offersSettings: true) {}), "Summary.Button.OpenAISettings"),
            (AnyView(ChatUnavailable(message: reason)), "Chat.Button.OpenAISettings"),
            (AnyView(AIStatusNote(message: reason)), "AIStatusNote.Button.OpenAISettings"),
        ]
        for (view, leaf) in states {
            let hosted = HostedWindow(view.environment(model), width: 480, height: 360)
            let ids = identifiers(in: hosted)
            hosted.close()
            let offered = ids.contains { $0.hasSuffix(leaf) }
            #expect(offered, "no \(leaf)")
        }
        let failure = HostedWindow(AIStatusNote(message: "Timed out.", kind: .failure).environment(model), width: 480, height: 200)
        let failureIDs = identifiers(in: failure)
        failure.close()
        let offeredOnFailure = failureIDs.contains { $0.hasSuffix("OpenAISettings") }
        #expect(!offeredOnFailure)

        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/AIPaneActionsTests.swift",
            with: "ParolaApp/Views/PromptsMenu.swift"
        )
        let menu = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(menu.contains(#"Text(verbatim: reason) OpenAISettingsButton(leaf: "HeaderBar.MenuItem.OpenAISettings")"#))
    }

    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/AIPaneActionsTests.swift", with: "ParolaApp/\(name).swift")
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("each AI action keeps one verb: the first run's, then Regenerate or Again, in the panes and the ✨ menu")
    func aiActionsShareOneVerb() throws {
        let empty = try source("Views/Summary/SummaryEmpty")
        #expect(!empty.contains("onGenerate"))
        #expect(empty.contains("Choose Summarize"))
        let column = try source("Views/Summary/SummaryOptionsColumn")
        #expect(column.contains(#"String(localized: "Summarize") : String(localized: "Regenerate")"#))
        let header = try source("Views/Transcript/TranscriptHeaderBar")
        #expect(header.contains(#"model.smartChapters.isEmpty ? String(localized: "Generate Chapters") : String(localized: "Regenerate Chapters")"#))
        #expect(header.contains(#"Button("Find Action Items") { runInInspector(model.extractActionItems) }"#))
        #expect(!header.contains(#"Button("Chapters")"#))
        #expect(!header.contains(#"Button("Action Items")"#))
        let chapters = try source("Views/Transcript/ChaptersSection")
        #expect(chapters.contains(#"Button("Generate Chapters")"#))
        #expect(chapters.contains(#"Button("Regenerate")"#))
        let items = try source("Views/Transcript/ActionItemsSection")
        #expect(items.contains(#"Button("Find Action Items")"#))
        #expect(items.contains(#"Button("Find Again")"#))
        #expect(items.contains(#"Text("Finding action items…")"#))
        #expect(!items.contains("Re-Extract"))
        #expect(!items.contains("Extracting…"))
    }

    @Test("the summary's meta line is plain words in the body font: no character count, no monospace")
    func summaryMetaReadsPlainly() throws {
        let model = makeModel()
        var summary = Summary(text: "We ship the patch on Friday.")
        summary.provider = "Apple Intelligence"
        model.transcript?.summary = summary
        let hosted = HostedWindow(SummaryPane().environment(model))
        let words = HostedAccessibility.words(in: hosted.host)
        hosted.close()
        let counted = words.contains("6 words")
        let abbreviated = words.contains { $0.contains("chars") || $0.contains("characters") }
        #expect(counted)
        #expect(!abbreviated)
        let pane = try source("Views/Summary/SummaryPane")
        #expect(!pane.contains("DS.Font.mono"))
        #expect(pane.contains("DS.Font.secondary.monospacedDigit()"))
    }
}
