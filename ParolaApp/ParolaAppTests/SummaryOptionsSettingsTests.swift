import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Summary options settings", .serialized)
struct SummaryOptionsSettingsTests {
    private func makeModel(_ defaults: UserDefaults = temporaryDefaults()) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("summary-options"))
    }

    private func makeTranscript(text: String = "hello") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("summaryOptions round-trips through defaults")
    func summaryOptionsRoundTrips() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        #expect(model.summaryOptions == .default)

        var options = SummaryOptions.default
        options.bulletPoints = true
        options.outputLanguage = "it"
        model.summaryOptions = options

        let reloaded = makeModel(defaults)
        #expect(reloaded.summaryOptions == options)
    }

    @Test("autostartSummary defaults to false")
    func autostartSummaryDefaultsFalse() {
        let model = makeModel()
        #expect(model.autostartSummary == false)
    }

    @Test("autostart summarises exactly once when activating a long enough transcript")
    func autostartSummarisesOnActivate() async {
        let model = makeModel()
        model.autostartSummary = true
        model.cardMetadataOperation = { _ in nil }
        let callCount = CallCounter()
        model.summariseOperation = { _, _ in
            await callCount.increment()
            return Summary(text: "auto summary")
        }

        let longText = String(repeating: "word ", count: 20)
        #expect(longText.count >= 40)
        model.transcript = makeTranscript(text: longText)
        model.persistToLibrary(makeTranscript(text: longText), audioSource: nil, source: .file, activate: true)

        await waitUntil(timeoutMs: 5000) { model.transcript?.summary != nil }
        #expect(callCount.value == 1)
    }

    @Test("autostart never runs when activate is false")
    func autostartSkipsWhenNotActivating() async {
        let model = makeModel()
        model.autostartSummary = true
        model.cardMetadataOperation = { _ in nil }
        let callCount = CallCounter()
        model.summariseOperation = { _, _ in
            await callCount.increment()
            return Summary(text: "auto summary")
        }

        let longText = String(repeating: "word ", count: 20)
        model.transcript = makeTranscript(text: longText)
        model.persistToLibrary(makeTranscript(text: longText), audioSource: nil, source: .file, activate: false)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(callCount.value == 0)
    }

    @Test("transcriptPaneMode defaults to transcript, can move to chat, and resets on clearLoadedEntry")
    func transcriptPaneModeLifecycle() {
        let model = makeModel()
        #expect(model.transcriptPaneMode == .transcript)

        model.transcript = makeTranscript()
        model.setTranscriptPaneMode(.chat)
        #expect(model.transcriptPaneMode == .chat)

        model.clearLoadedEntry()
        #expect(model.transcriptPaneMode == .transcript)
    }

    @Test("assigning selectedEntryID the same value it already holds does not reset the pane mode")
    func sameValueSelectionKeepsPaneMode() {
        let model = makeModel()
        model.transcript = makeTranscript()
        model.selectedEntryID = "entry-1"
        model.setTranscriptPaneMode(.summary)
        #expect(model.transcriptPaneMode == .summary)

        model.selectedEntryID = "entry-1"
        #expect(model.transcriptPaneMode == .summary, "re-assigning the same id (summarizeLatestEntry does this) must not bounce the user out of Summary")

        model.selectedEntryID = "entry-2"
        #expect(model.transcriptPaneMode == .transcript, "a real change of entry still resets the mode")
    }

    @Test("autostart starts when the entry lands, without waiting for its card")
    func autostartDoesNotWaitForTheCard() async {
        let model = makeModel()
        model.autostartSummary = true
        let (release, releaser) = AsyncStream<Void>.makeStream()
        model.cardMetadataOperation = { _ in
            for await _ in release { break }
            return CardMetadata(title: "Card", summary: "Written after the summary started.")
        }
        let callCount = CallCounter()
        model.summariseOperation = { _, _ in
            await callCount.increment()
            return Summary(text: "auto summary")
        }

        let longText = String(repeating: "word ", count: 20)
        model.transcript = makeTranscript(text: longText)
        model.persistToLibrary(makeTranscript(text: longText), audioSource: nil, source: .file, activate: true)

        await waitUntil(timeoutMs: 2000) { callCount.value == 1 }
        #expect(model.cardJobsPending == 1)
        releaser.finish()
        await model.awaitCardMetadataQueue()
    }

    @Test("autostart skips when the user moved on before the entry landed")
    func autostartSkipsOnNavigationAway() async {
        let model = makeModel()
        model.autostartSummary = true
        model.cardMetadataOperation = { _ in nil }
        let callCount = CallCounter()
        model.summariseOperation = { _, _ in
            await callCount.increment()
            return Summary(text: "auto summary")
        }

        let longText = String(repeating: "word ", count: 20)
        model.transcript = makeTranscript(text: longText)
        let adding = model.persistToLibrary(makeTranscript(text: longText), audioSource: nil, source: .file, activate: true)
        model.loadEntryGeneration &+= 1
        _ = try? await adding.value

        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.selectedEntryID == nil)
        #expect(callCount.value == 0)
    }

    @Test("summariseTranscript passes the saved options to the operation")
    func summariseUsesSavedOptions() async {
        let model = makeModel()
        var options = SummaryOptions.default
        options.bulletPoints = true
        options.outputLanguage = "fr"
        model.summaryOptions = options
        model.transcript = makeTranscript()

        let received = ReceivedOptions()
        model.summariseOperation = { _, receivedOptions in
            await received.set(receivedOptions)
            return Summary(text: "ok")
        }

        model.summariseTranscript()
        await waitUntil { !model.isSummarising }

        #expect(received.value == options)
    }
}

@MainActor
private final class CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
private final class ReceivedOptions {
    private(set) var value: SummaryOptions?
    func set(_ options: SummaryOptions) { value = options }
}
