import Foundation

/// Accumulates confirmed speech segments into one running partial string, in spoken order.
///
/// Apple's `SpeechTranscriber` emits a final result per confirmed region; appending each one as it
/// arrives lets the UI grow the transcript sentence by sentence. Volatile (in-progress) results are
/// intentionally not accumulated here — they fire far more often and add no committed text.
struct SpeechPartialAssembler {
    private var joined = ""

    mutating func addFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if joined.isEmpty {
            joined = trimmed
        } else {
            joined += " " + trimmed
        }
    }

    var text: String {
        joined
    }

    /// The trailing `maxChars` of the partial, cut so it never starts mid-word.
    func tail(maxChars: Int = 2000) -> String {
        StreamingText.tail(of: joined, maxChars: maxChars)
    }
}
