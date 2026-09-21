import Foundation
import Testing
@testable import ParolaCore

@Suite("Summary options", .serialized)
struct SummaryOptionsTests {
    @Test("defaults match the design")
    func defaults() {
        let o = SummaryOptions.default
        #expect(o.includeTimestamps && !o.includeSpeakers && o.sections && !o.bulletPoints && o.actionItems && !o.keyPointsOnly)
        #expect(o.outputLanguage == nil && o.customPrompt == nil)
    }

    @Test("instructions follow the flags and never drop the format contract")
    func instructionsFollowFlags() {
        var o = SummaryOptions.default
        o.bulletPoints = true; o.keyPointsOnly = true; o.outputLanguage = "it"; o.customPrompt = "Mention prices."
        let text = SummaryService.textInstructions(for: o)
        #expect(text.contains("SUMMARY:") && text.contains("CHAPTERS:") && text.contains("ACTION ITEMS:"))
        #expect(text.contains("bullet") && text.contains("key points") && text.contains("Italian"))
        #expect(text.contains("Additional instructions: Mention prices."))
        o.actionItems = false
        #expect(!SummaryService.textInstructions(for: o).contains("ACTION ITEMS:"))
        #expect(SummaryService.structuredInstructions(for: o).contains("Italian"))
    }

    @Test("structuredInstructions tells the model to leave action items empty when the flag is off")
    func structuredInstructionsDropsActionItems() {
        var o = SummaryOptions.default
        #expect(!SummaryService.structuredInstructions(for: o).contains("Leave actionItems empty."))
        o.actionItems = false
        #expect(SummaryService.structuredInstructions(for: o).contains("Leave actionItems empty."))
    }

    @Test("segment lines honour timestamps and speakers")
    func lines() {
        let s = TranscriptSegment(id: 0, start: 65, end: 70, text: "Ciao a tutti", speaker: "Anna")
        #expect(SummaryService.line(for: s, options: .default) == "\(Timecode.format(65))  Ciao a tutti\n")
        var o = SummaryOptions.default; o.includeSpeakers = true
        #expect(SummaryService.line(for: s, options: o) == "\(Timecode.format(65))  Anna: Ciao a tutti\n")
        o.includeTimestamps = false
        #expect(SummaryService.line(for: s, options: o) == "Anna: Ciao a tutti\n")
        o.includeSpeakers = false
        #expect(SummaryService.line(for: s, options: o) == "Ciao a tutti\n")
    }

    @Test("mergeActionItems dedupes case-insensitively after trimming, keeping first-seen order")
    func mergeActionItemsDedup() {
        let merged = SummaryService.mergeActionItems(["Send the deck", "Book the room", "book the room", " Send the deck "])
        #expect(merged == ["Send the deck", "Book the room"])
    }

    @Test("parse reads an ACTION ITEMS section and Summary decodes without it")
    func parseAndDecode() throws {
        let parsed = SummaryService.parse("SUMMARY:\nA short summary.\n\nCHAPTERS:\n00:00  Start\n\nACTION ITEMS:\n- Send the deck\n- Book the room\n")
        #expect(parsed.text == "A short summary.")
        #expect(parsed.chapters.count == 1)
        #expect(parsed.actionItems == ["Send the deck", "Book the room"])
        let legacy = try JSONDecoder().decode(Summary.self, from: Data(#"{"text":"t","chapters":[]}"#.utf8))
        #expect(legacy.actionItems.isEmpty)
    }

    @Test("the mock text path receives the options' instructions")
    func mockPathUsesOptions() async throws {
        // The store is process-global and swift-testing runs suites in parallel: hold the lease
        // for the whole install → run → clear, or another suite resolves this slot.
        try await MockLanguageModelStore.shared.withLease {
            await MockLanguageModelStore.shared.clear()
            await MockLanguageModelStore.shared.install(provider: .foundation, response: MockLanguageModelResponse(text: "SUMMARY:\nOk.\n\nCHAPTERS:\n00:00  A\n"))
            do {
                let t = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 3, text: "Ciao a tutti, benvenuti.")], language: "it", modelName: "m", sourceURL: URL(fileURLWithPath: "/tmp/a.wav"))
                var o = SummaryOptions.default; o.outputLanguage = "en"
                let s = try await SummaryService(features: FeatureSet(enabled: [.ai])).summarise(t, options: o)
                #expect(s.text == "Ok.")
                let instructions = await MockLanguageModelStore.shared.lastInstructions(for: .foundation)
                #expect(instructions?.contains("English") == true)
            } catch {
                await MockLanguageModelStore.shared.clear()
                throw error
            }
            await MockLanguageModelStore.shared.clear()
        }
    }
}
