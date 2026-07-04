import Foundation

/// Helpers for rendering a growing partial transcript as it streams in.
public enum StreamingText {
    /// Splits the latest cumulative partial into the text already shown and the chunk that arrived
    /// since. Handles both plain appends and a capped tail window that slides forward as it grows;
    /// when `latest` shares no substantial overlap with `shown` (a rewrite), the whole string is
    /// treated as settled, so a display never dims text that isn't genuinely new.
    public static func split(shown: String, latest: String) -> (settled: String, fresh: String) {
        if latest.hasPrefix(shown) {
            return (shown, String(latest.dropFirst(shown.count)))
        }
        if let overlap = slideOverlap(shown: shown, latest: latest) {
            return (String(latest.prefix(overlap)), String(latest.dropFirst(overlap)))
        }
        return (latest, "")
    }

    /// The longest suffix of `shown` that prefixes `latest`, accepted only when it covers at least
    /// half of `latest` — anything shorter is a rewrite, not a slid window.
    private static func slideOverlap(shown: String, latest: String) -> Int? {
        let minOverlap = (latest.count + 1) / 2
        guard minOverlap > 0 else { return nil }
        var k = min(shown.count, latest.count)
        while k >= minOverlap {
            if shown.suffix(k) == latest.prefix(k) { return k }
            k -= 1
        }
        return nil
    }

    /// The trailing `maxChars` of `text`, advanced past a leading half word so the cut never
    /// starts mid-word. A single unbreakable word longer than the cap is returned cut as-is.
    static func tail(of text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard let cutStart = text.index(text.endIndex, offsetBy: -maxChars, limitedBy: text.startIndex),
              cutStart > text.startIndex else { return text }
        var start = cutStart
        if !text[text.index(before: start)].isWhitespace {
            while start < text.endIndex, !text[start].isWhitespace {
                start = text.index(after: start)
            }
        }
        while start < text.endIndex, text[start].isWhitespace {
            start = text.index(after: start)
        }
        guard start < text.endIndex else { return String(text[cutStart...]) }
        return String(text[start...])
    }
}
