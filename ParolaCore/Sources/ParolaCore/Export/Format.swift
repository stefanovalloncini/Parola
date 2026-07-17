import CoreText
import Foundation

public enum Format {
    /// Zero-length and inverted cues never display (and strict parsers reject them);
    /// every caption exporter floors a cue to at least one frame.
    public static let minCaptionSeconds = 1.0 / 30.0

    public static func timestampHHMMSS(_ seconds: Double) -> String {
        let total = Int(exactly: max(0, seconds).rounded(.towardZero)) ?? .max
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Formats seconds as `HH:MM:SS<sep>mmm`. SRT uses `,` as separator, VTT uses `.`.
    public static func subtitleTimestamp(_ seconds: Double, msSeparator: Character) -> String {
        let total = Int(exactly: (max(0, seconds) * 1000).rounded()) ?? .max
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d\(msSeparator)%03d", h, m, s, ms)
    }

    /// Renders a seconds value for CSV/TSV numeric columns. `%f` is locale-independent and never
    /// uses scientific notation (unlike a bare Double interpolation, which prints e.g. "1e-05").
    /// Non-finite input renders as `"0.0"` so the column stays numeric for downstream parsers.
    public static func decimalSeconds(_ v: Double) -> String {
        guard v.isFinite else { return "0.0" }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    /// Parses `HH:MM:SS.mmm` or `MM:SS.mmm` style timestamps. Treats `,` as equivalent to `.`.
    public static func parseClockTimestamp(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.components(separatedBy: ":")
        let seconds: Double
        if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let sec = plainSeconds(parts[2]) {
            seconds = Double(h) * 3600 + Double(m) * 60 + sec
        } else if parts.count == 2, let m = Int(parts[0]), let sec = plainSeconds(parts[1]) {
            seconds = Double(m) * 60 + sec
        } else {
            return nil
        }
        // Past this a cue's time is corrupt (e.g. a malformed hours field); no real recording is this long.
        return (0...maxClockSeconds).contains(seconds) ? seconds : nil
    }

    private static let maxClockSeconds: Double = 1000 * 3600

    // Double.init over-accepts nan/inf/scientific/hex/signs; subtitle seconds are always plain SS[.mmm].
    private static func plainSeconds(_ field: String) -> Double? {
        guard !field.isEmpty,
              field.allSatisfy({ $0 == "." || ($0.isASCII && $0.isNumber) }),
              let value = Double(field), value.isFinite
        else { return nil }
        return value
    }

    // A speaker rendered inline (SRT/VTT cue, HTML span, DOCX run, MD bold) must stay on one line,
    // so a newline would split the cue or break the tag; a whitespace-only label renders blank.
    static func presentationSpeakerLabel(_ speaker: String?) -> String? {
        guard let speaker else { return nil }
        let flattened = speaker
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }

    static func documentTitle(for transcript: Transcript) -> String {
        let derived = transcript.sourceURL?
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let derived, !derived.isEmpty { return derived }
        return "Transcript"
    }

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Like ``escapeHTML(_:)`` but also drops scalars outside XML 1.0's `Char` production
    /// (NUL and other C0 controls except tab/newline/CR, plus noncharacters). Such bytes can't
    /// appear in XML even as numeric references, so leaving one in a segment yields a `.docx`
    /// Word refuses to open.
    public static func escapeXML(_ s: String) -> String {
        let valid = s.unicodeScalars.filter(isXMLChar)
        return escapeHTML(String(String.UnicodeScalarView(valid)))
    }

    private static func isXMLChar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
            return true
        default:
            return false
        }
    }

    /// WebVTT cue text only decodes `&amp;`, `&lt;`, `&gt;` (and a few named entities), not numeric
    /// references — so escaping quotes/apostrophes the HTML way would surface literal `&#39;` in players.
    public static func escapeWebVTT(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Builds a CTFont with a language-aware fallback cascade so non-Latin scripts don't render as `.notdef`.
    public static func cascadingFont(name: String, size: CGFloat, language: String) -> CTFont {
        let base = CTFontCreateWithName(name as CFString, size, nil)
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return base }
        let fallback = CTFontCreateUIFontForLanguage(.system, size, trimmed as CFString) ?? base
        let descriptor = CTFontCopyFontDescriptor(base)
        let cascadeDescriptors = [CTFontCopyFontDescriptor(fallback)] as CFArray
        let attributes = [kCTFontCascadeListAttribute: cascadeDescriptors] as CFDictionary
        guard let cascaded = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes) as CTFontDescriptor? else {
            return base
        }
        return CTFontCreateWithFontDescriptor(cascaded, size, nil)
    }
}
