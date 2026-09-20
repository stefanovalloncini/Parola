import CoreML
import Foundation
import WhisperKit

/// Tokenizes a user-supplied prompt into the format WhisperKit's decoder expects.
/// Returns nil when there's no prompt to tokenize or when the tokenizer isn't ready.
func promptTokens(_ prompt: String?, tokenizer: WhisperTokenizer?) -> [Int]? {
    guard let prompt, let tokenizer else { return nil }
    let trimmed = prompt.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let tokens = tokenizer.encode(text: " " + trimmed)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    return tokens.isEmpty ? nil : tokens
}

/// Puts a user prompt on `decoding` and returns the logits filters the prompted run needs.
/// Assign the result to the decoder unconditionally: an empty array clears a previous run's.
func applyInitialPrompt(
    _ prompt: String?,
    to decoding: inout DecodingOptions,
    tokenizer: WhisperTokenizer?,
    isModelMultilingual: Bool
) -> [any LogitsFiltering] {
    guard let tokenizer, let tokens = promptTokens(prompt, tokenizer: tokenizer) else { return [] }
    decoding.promptTokens = tokens
    decoding.usePrefillPrompt = true

    let specialTokens = tokenizer.specialTokens
    let sampleBegin = unpromptedPrefillLength(isModelMultilingual: isModelMultilingual)
    var filters: [any LogitsFiltering] = [
        SuppressBlankFilter(specialTokens: specialTokens, sampleBegin: sampleBegin)
    ]
    // An English-only model prefills no language or task token, so WhisperKit's own timestamp
    // rules still find their footing behind a prompt and this would only duplicate them.
    if isModelMultilingual, !decoding.withoutTimestamps {
        filters.append(TimestampRulesFilter(
            specialTokens: specialTokens,
            sampleBegin: sampleBegin,
            maxInitialTimestampIndex: decoding.maxInitialTimestamp.map {
                Int($0 / WhisperKit.secondsPerTimeToken)
            },
            isModelMultilingual: true
        ))
    }
    return filters.map {
        PromptStrippedFilter(inner: $0, startOfTranscriptToken: specialTokens.startOfTranscriptToken)
    }
}

/// `<|startoftranscript|>`, the language and task tokens for a multilingual model, and the
/// timestamp token: what WhisperKit prefills when no prompt sits in front of it.
func unpromptedPrefillLength(isModelMultilingual: Bool) -> Int {
    isModelMultilingual ? 4 : 2
}

/// WhisperKit's own filters read the prefill from the front of the token array, so a prompt prefix
/// puts them out of reach; hands them the run from `<|startoftranscript|>` instead.
struct PromptStrippedFilter: LogitsFiltering {
    let inner: any LogitsFiltering
    let startOfTranscriptToken: Int

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard let start = tokens.firstIndex(of: startOfTranscriptToken) else { return logits }
        return inner.filterLogits(logits, withTokens: Array(tokens[start...]))
    }
}
