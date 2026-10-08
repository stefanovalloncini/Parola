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

    @Test("a failed summary offers Retry, the app's word for it, where the error shows, and it runs the summary again")
    func failedSummaryOffersRetry() async {
        let model = makeModel()
        model.summaryError = "The model stopped answering."
        model.summariseOperation = { _, _ in Summary(text: "second try") }
        let hosted = HostedWindow(SummaryPane().environment(model))
        defer { hosted.close() }

        let words = HostedAccessibility.words(in: hosted.host)
        #expect(words.contains("Retry"))
        #expect(!words.contains("Try Again"))
        #expect(HostedAccessibility.press(endingWith: "Summary.Button.Retry", in: hosted.host))
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

    @Test("the inspector's Summary offers Summarize, then Stop while one is written, Retry after a failure, and Show Summary once there is one")
    func overviewSummaryStates() async {
        let model = makeModel()
        model.aiUnavailableReason = nil
        let hosted = HostedWindow(OverviewSummary().environment(model), width: MainWindowLayout.inspectorWidth, height: 300)
        defer { hosted.close() }
        #expect(item("Overview.Button.Summarize", in: hosted)?.name == "Summarize")

        blockedRun(.summary, on: model)
        let stoppable = await waitUntil { item("Overview.Button.StopSummary", in: hosted) != nil }
        #expect(stoppable)
        #expect(item("Overview.Button.Summarize", in: hosted) == nil)
        #expect(HostedAccessibility.press(endingWith: "Overview.Button.StopSummary", in: hosted.host))
        #expect(!model.isSummarising)

        model.summaryError = "The model stopped answering."
        let failed = await waitUntil { item("Overview.Button.RetrySummary", in: hosted)?.name == "Retry" }
        #expect(failed)
        #expect(HostedAccessibility.words(in: hosted.host).contains("The model stopped answering."))

        model.summaryError = nil
        model.transcript?.summary = Summary(text: "We ship the patch on Friday.")
        let summarised = await waitUntil { item("Overview.Button.ShowSummary", in: hosted)?.name == "Show Summary" }
        #expect(summarised)
        #expect(HostedAccessibility.words(in: hosted.host).contains("We ship the patch on Friday."))

        blockedRun(.summary, on: model)
        let regenerating = await waitUntil { item("Overview.Button.StopSummary", in: hosted) != nil }
        #expect(regenerating, "a summary being written again shows its progress, not the one it replaces")
        model.stopAIRun(.summary)

        model.aiUnavailableReason = "Apple Intelligence is turned off."
        model.transcript?.summary = nil
        let unavailable = await waitUntil { HostedAccessibility.words(in: hosted.host).contains("Apple Intelligence is turned off.") }
        #expect(unavailable)
        #expect(item("Overview.Button.Summarize", in: hosted) == nil)
    }

    @Test("chapters and action items being found can be stopped beside their progress line")
    func inspectorRunsStop() async {
        let model = makeModel()
        let hosted = HostedWindow(VStack {
            OverviewChapters()
            OverviewActionItems()
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

    private func askAI(_ model: AppModel, userPrompts: [Prompt] = [Prompt(name: "Shorter", instructions: "Make it shorter.")]) -> HostedWindow {
        HostedWindow(VStack(alignment: .leading) { AskAIItems(userPrompts: userPrompts) }.environment(model), width: 420, height: 900)
    }

    private func item(_ leaf: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(leaf) == true }
    }

    /// Ask AI's items top to bottom, each once.
    private func askAIItems(in hosted: HostedWindow) -> [HostedAccessibility.Element] {
        var seen: Set<String> = []
        return HostedAccessibility.elements(in: hosted.host)
            .filter { $0.identifier?.contains("Toolbar.Transcript.MenuItem.") == true }
            .sorted { $0.frame.midY > $1.frame.midY }
            .filter { seen.insert($0.identifier ?? "").inserted }
    }

    /// The items that run a prompt: the built-ins, YouTube Chapters and the user's own.
    private func promptItems(in hosted: HostedWindow) -> [HostedAccessibility.Element] {
        askAIItems(in: hosted).filter { element in
            let id = element.identifier ?? ""
            return id.contains("MenuItem.BuiltinPrompt.") || id.contains("MenuItem.UserPrompt.") || id.hasSuffix("MenuItem.YouTubeChapters")
        }
    }

    @Test("while a prompt runs, Ask AI offers Stop Prompt and holds every prompt back until it stops")
    func promptRunStops() async {
        let model = makeModel()
        model.aiUnavailableReason = nil
        let hosted = askAI(model)
        defer { hosted.close() }
        let idle = promptItems(in: hosted)
        let idleOn = idle.allSatisfy(\.isEnabled)
        #expect(item("MenuItem.StopPrompt", in: hosted) == nil)
        #expect(idle.count == Prompt.builtIns.count - ChatPane.excludedBuiltInIDs.count + 2)
        #expect(idleOn)

        blockedRun(.prompt, on: model)
        #expect(model.isRunningPrompt)
        let stoppable = await waitUntil { item("MenuItem.StopPrompt", in: hosted)?.isEnabled == true }
        #expect(stoppable)
        let held = promptItems(in: hosted)
        let stillOn = held.filter(\.isEnabled).compactMap(\.name)
        #expect(held.count == idle.count)
        #expect(stillOn.isEmpty, "still on while a prompt runs: \(stillOn)")
        #expect(item("MenuItem.ManagePrompts", in: hosted)?.isEnabled == true)

        #expect(HostedAccessibility.press(endingWith: "MenuItem.StopPrompt", in: hosted.host))
        #expect(!model.isRunningPrompt)
        let released = await waitUntil {
            item("MenuItem.StopPrompt", in: hosted) == nil && promptItems(in: hosted).allSatisfy(\.isEnabled)
        }
        #expect(released)
    }

    @Test("with AI unavailable, Ask AI says why above Open AI Settings… and holds back everything that needs a model")
    func unavailableAskAISaysWhy() {
        let model = makeModel()
        let reason = "Apple Intelligence is turned off."
        model.aiUnavailableReason = reason
        let hosted = askAI(model)
        let words = HostedAccessibility.words(in: hosted.host)
        let items = askAIItems(in: hosted)
        hosted.close()
        let names = items.compactMap(\.name)
        let settings = items.first { $0.identifier?.hasSuffix("MenuItem.OpenAISettings") == true }
        let alwaysOn = ["MenuItem.OpenAISettings", "MenuItem.ManagePrompts"]
        let needModel = items.filter { item in !alwaysOn.contains { item.identifier?.hasSuffix($0) == true } }
        let stillOn = needModel.filter(\.isEnabled).compactMap(\.name)
        #expect(words.contains(reason))
        #expect(settings?.isEnabled == true, "no Open AI Settings… in \(names)")
        #expect(needModel.count == Prompt.builtIns.count - ChatPane.excludedBuiltInIDs.count + 4, "\(names)")
        #expect(stillOn.isEmpty, "on with no model to run them: \(stillOn)")
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

    @Test("a stopped reply keeps the words it had said, and one stopped before a word gives its question back")
    func stoppedReplyKeepsItsWords() throws {
        let question = ChatMessage(role: .user, text: "What was decided?")
        let replyID = UUID()
        let live = ChatPane.LiveTurn(question: question, replyID: replyID)
        let started = [question, ChatMessage(id: replyID, role: .assistant, text: "We ship on Fri ")]
        guard case .keep(let reply) = ChatPane.stoppedTurn(live, in: started) else {
            Issue.record("a reply with words wasn't kept")
            return
        }
        #expect(reply.id == replyID)
        #expect(reply.role == .assistant)
        #expect(reply.text == "We ship on Fri")
        let unanswered = ChatPane.stoppedTurn(live, in: [question])
        #expect(unanswered == .unanswered)

        let pane = try source("Views/Chat/ChatPane")
        #expect(pane.contains("await session.keepStopped(question: live.question, reply: reply)"))
        #expect(pane.contains("for try await event in session.stream(text, id: question.id)"))
        #expect(pane.contains("await keeping?.value"))
    }

    @Test("every AI-unavailable state offers Open AI Settings…, and a plain failure note doesn't")
    func unavailableStatesOfferSettings() {
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
    }

    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/AIPaneActionsTests.swift", with: "ParolaApp/\(name).swift")
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Ask AI lists the prompts that read a transcript, then the user's own, and ends with Manage Prompts…")
    func askAIListsTranscriptPrompts() {
        let model = makeModel()
        model.aiUnavailableReason = nil
        let hosted = askAI(model)
        let names = askAIItems(in: hosted).compactMap(\.name)
        hosted.close()
        let transcriptPrompts = Prompt.builtIns.filter { !ChatPane.excludedBuiltInIDs.contains($0.id) }.map(\.name)
        let expected = ["Generate Chapters", "Find Action Items"] + transcriptPrompts + ["YouTube Chapters", "Shorter", "Manage Prompts…"]
        #expect(names == expected)
    }

    @Test("each AI action keeps one verb: the first run's, then Regenerate or Again, in the panes and Ask AI")
    func aiActionsShareOneVerb() throws {
        let empty = try source("Views/Summary/SummaryEmpty")
        #expect(!empty.contains("onGenerate"))
        #expect(empty.contains("Choose Summarize"))
        let column = try source("Views/Summary/SummaryOptionsColumn")
        #expect(column.contains(#"String(localized: "Summarize") : String(localized: "Regenerate")"#))
        let model = makeModel()
        model.aiUnavailableReason = nil
        let fresh = askAI(model)
        let firstRun = item("MenuItem.Chapters", in: fresh)?.name
        let findItems = item("MenuItem.ActionItems", in: fresh)?.name
        fresh.close()
        model.smartChapters = [Chapter(title: "The budget", start: 0)]
        let again = askAI(model)
        let rerun = item("MenuItem.Chapters", in: again)?.name
        again.close()
        #expect(firstRun == "Generate Chapters")
        #expect(rerun == "Regenerate Chapters")
        #expect(findItems == "Find Action Items")
    }

    @Test("the inspector's chapters and action items keep the same verbs: Generate and Find first, then Regenerate and Find Again")
    func inspectorActionsShareOneVerb() async {
        let model = makeModel()
        model.aiUnavailableReason = nil
        model.transcript?.summary = Summary(text: "We ship the patch on Friday.")
        let empty = HostedWindow(OverviewSections().environment(model), width: MainWindowLayout.inspectorWidth, height: 900)
        let generate = item("Chapters.Button.Generate", in: empty)?.name
        let find = item("ActionItems.Button.Find", in: empty)?.name
        empty.close()
        #expect(generate == "Generate Chapters")
        #expect(find == "Find Action Items")

        model.smartChapters = [Chapter(title: "The budget", start: 0)]
        model.actionItems = [ActionItem(task: "Ship the patch")]
        let menus = HostedWindow(VStack(alignment: .leading) {
            ChapterActions()
            ActionItemActions()
        }.environment(model), width: 320, height: 400)
        let regenerate = item("Chapters.Button.Regenerate", in: menus)?.name
        let again = item("ActionItems.Button.Reextract", in: menus)?.name
        menus.close()
        #expect(regenerate == "Regenerate")
        #expect(again == "Find Again")

        blockedRun(.actionItems, on: model)
        let running = HostedWindow(OverviewActionItems().environment(model), width: 320, height: 300)
        defer { running.close() }
        let finding = await waitUntil { HostedAccessibility.words(in: running.host).contains("Finding action items…") }
        #expect(finding)
        let words = HostedAccessibility.words(in: running.host)
        let jargon = words.filter { $0.contains("Re-Extract") || $0.contains("Extracting…") }
        #expect(jargon.isEmpty)
        model.stopAIRun(.actionItems)
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
