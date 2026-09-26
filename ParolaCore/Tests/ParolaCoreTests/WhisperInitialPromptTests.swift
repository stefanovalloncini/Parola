import CoreML
import Foundation
import Testing
import WhisperKit
@testable import ParolaCore

/// A prompt prefix moves the prefill out from under WhisperKit's own logits filters, which read it
/// from the front of the token array. These pin both halves: that the filters really do go inert
/// behind a prompt, and that the wrapper hands them back the shape they expect.
@Suite("Whisper initial prompt")
struct WhisperInitialPromptTests {
    @Test("a prompt is encoded with a leading space and without special tokens")
    func promptIsEncodedForTheDecoder() {
        #expect(promptTokens("Parola", tokenizer: StubTokenizer()) == [32, 80, 97, 114, 111, 108, 97])
        #expect(promptTokens("Pa™", tokenizer: StubTokenizer()) == [32, 80, 97])
    }

    @Test("nothing to say leaves the prefill alone")
    func blankPromptsTokenizeToNothing() {
        #expect(promptTokens(nil, tokenizer: StubTokenizer()) == nil)
        #expect(promptTokens("   ", tokenizer: StubTokenizer()) == nil)
        #expect(promptTokens("Parola", tokenizer: nil) == nil)
    }

    @Test("a run without a prompt asks for no filters of its own")
    func noPromptInstallsNoFilters() {
        var decoding = DecodingOptions()
        let filters = applyInitialPrompt(nil, to: &decoding, tokenizer: StubTokenizer(), isModelMultilingual: true)
        #expect(filters.isEmpty)
        #expect(decoding.promptTokens == nil)
    }

    @Test("a multilingual model gets both filters back, an English-only one only the blank filter")
    func promptInstallsTheFiltersTheModelNeeds() {
        var multilingual = DecodingOptions()
        let forMultilingual = applyInitialPrompt(
            "Parola", to: &multilingual, tokenizer: StubTokenizer(), isModelMultilingual: true
        )
        #expect(forMultilingual.count == 2)
        #expect(multilingual.promptTokens == [32, 80, 97, 114, 111, 108, 97])
        #expect(multilingual.usePrefillPrompt)

        var englishOnly = DecodingOptions()
        let forEnglishOnly = applyInitialPrompt(
            "Parola", to: &englishOnly, tokenizer: StubTokenizer(), isModelMultilingual: false
        )
        #expect(forEnglishOnly.count == 1)
    }

    @Test("WhisperKit's own filters go inert behind a prompt prefix")
    func theBuiltInFiltersStopSeeingThePrefill() throws {
        let logits = try makeLogits()
        let untouched = readValues(logits)
        _ = timestampRules().filterLogits(logits, withTokens: promptedPrefill)
        _ = SuppressBlankFilter(specialTokens: .stub, sampleBegin: 0)
            .filterLogits(logits, withTokens: promptedPrefill)
        #expect(
            readValues(logits) == untouched,
            "WhisperKit's filters now react to a prompt-prefixed array — the bug is fixed upstream, drop PromptStrippedFilter."
        )
    }

    @Test("the wrapper masks what a prompt-free run masks")
    func theWrapperRestoresThePromptFreeMask() throws {
        for tail in [[], [96, 97], [96, 97, SpecialTokens.stub.timeTokenBegin + 5]] as [[Int]] {
            let promptFree = try makeLogits()
            _ = timestampRules().filterLogits(promptFree, withTokens: unpromptedPrefill + tail)

            let prompted = try makeLogits()
            _ = PromptStrippedFilter(
                inner: timestampRules(),
                startOfTranscriptToken: SpecialTokens.stub.startOfTranscriptToken
            ).filterLogits(prompted, withTokens: promptedPrefill + tail)

            #expect(readValues(prompted) == readValues(promptFree))
        }
    }

    @Test("the blank filter reaches the first sampled token behind a prompt")
    func theWrapperSuppressesTheOpeningBlank() throws {
        let logits = try makeLogits()
        _ = PromptStrippedFilter(
            inner: SuppressBlankFilter(specialTokens: .stub, sampleBegin: unpromptedPrefillLength(isModelMultilingual: true)),
            startOfTranscriptToken: SpecialTokens.stub.startOfTranscriptToken
        ).filterLogits(logits, withTokens: promptedPrefill)

        let values = readValues(logits)
        #expect(values[SpecialTokens.stub.endToken] == -.infinity)
        #expect(values[SpecialTokens.stub.whitespaceToken] == -.infinity)
    }

    @Test("a streaming session installs its filters on a decoder of its own")
    func theStreamingSessionLeavesTheCachedDecoderAlone() throws {
        let shared = TextDecoder()
        shared.isModelMultilingual = true
        var own = StreamingTranscriptionSession.ownDecoder(borrowing: shared, tokenizer: StubTokenizer())
        var decoding = DecodingOptions()
        own.logitsFilters = applyInitialPrompt(
            "Parola", to: &decoding, tokenizer: StubTokenizer(), isModelMultilingual: own.isModelMultilingual
        )

        #expect(own.logitsFilters?.count == 2)
        #expect(shared.logitsFilters?.isEmpty == true)
        #expect(own.isModelMultilingual)
        #expect(try #require(own as? TextDecoder) !== shared)
    }

    @Test("a run that transcribed nothing but the prompt back returns nothing")
    func thePromptEchoIsDropped() {
        let echo = [segment("  parola ")]
        #expect(TranscriptFinisher.droppingPromptEcho(echo, prompt: "Parola").isEmpty)
        #expect(TranscriptFinisher.droppingPromptEcho(echo, prompt: nil).count == 1)
        #expect(TranscriptFinisher.droppingPromptEcho([segment("Parola is an app.")], prompt: "Parola").count == 1)
        #expect(
            TranscriptFinisher.droppingPromptEcho(
                [segment("Parola"), segment("Parola")], prompt: "Parola"
            ).count == 2
        )
    }

    @Test("the prefill a prompt-free run samples after is four tokens, or two without language and task")
    func prefillLengthFollowsTheModel() {
        #expect(unpromptedPrefillLength(isModelMultilingual: true) == 4)
        #expect(unpromptedPrefillLength(isModelMultilingual: false) == 2)
    }

    // MARK: - Fixtures

    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: 0, start: 0, end: 1, text: text)
    }

    /// Mirrors `TextDecoder.prefillDecoderInputs`: start token, language and task for a
    /// multilingual model, then one timestamp token.
    private var unpromptedPrefill: [Int] {
        let tokens = SpecialTokens.stub
        return [tokens.startOfTranscriptToken, tokens.englishToken, tokens.transcribeToken, tokens.timeTokenBegin]
    }

    private var promptedPrefill: [Int] {
        [SpecialTokens.stub.startOfPreviousToken, 80, 97] + unpromptedPrefill
    }

    private func timestampRules() -> TimestampRulesFilter {
        TimestampRulesFilter(
            specialTokens: .stub,
            sampleBegin: unpromptedPrefillLength(isModelMultilingual: true),
            maxInitialTimestampIndex: nil,
            isModelMultilingual: true
        )
    }

    private func makeLogits() throws -> MLMultiArray {
        let count = SpecialTokens.stub.timeTokenBegin + 20
        let logits = try MLMultiArray(shape: [1, 1, NSNumber(value: count)], dataType: .float16)
        logits.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
            for index in 0..<count {
                buffer[index] = Float16(Float(index % 11) * 0.25 - 1.5)
            }
        }
        return logits
    }

    private func readValues(_ logits: MLMultiArray) -> [Float] {
        logits.withUnsafeBufferPointer(ofType: Float16.self) { buffer in buffer.map { Float($0) } }
    }
}

extension SpecialTokens {
    /// Whisper's real ids are five digits apart; these keep the same ordering in a vocabulary
    /// small enough to build a logits vector for.
    static let stub = SpecialTokens(
        endToken: 200,
        englishToken: 202,
        noSpeechToken: 207,
        noTimestampsToken: 205,
        specialTokenBegin: 200,
        startOfPreviousToken: 206,
        startOfTranscriptToken: 201,
        timeTokenBegin: 210,
        transcribeToken: 204,
        translateToken: 203,
        whitespaceToken: 32
    )
}

private struct StubTokenizer: WhisperTokenizer {
    let specialTokens = SpecialTokens.stub
    let allLanguageTokens: Set<Int> = []

    /// One token per Unicode scalar, so a character above `specialTokenBegin` stands in for the
    /// special token a prompt must not carry into the prefill.
    func encode(text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func decode(tokens: [Int]) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}
