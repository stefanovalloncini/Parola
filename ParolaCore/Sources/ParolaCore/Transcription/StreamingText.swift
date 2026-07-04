import Foundation

/// Helpers for rendering a growing partial transcript as it streams in.
public enum StreamingText {
    /// Splits the latest cumulative partial into the text already shown and the chunk that arrived
    /// since. When `latest` doesn't extend `shown` (a rewrite rather than an append) the whole
    /// string is treated as settled, so a display never dims text that isn't genuinely new.
    public static func split(shown: String, latest: String) -> (settled: String, fresh: String) {
        guard latest.hasPrefix(shown) else { return (latest, "") }
        return (shown, String(latest.dropFirst(shown.count)))
    }
}
