import CoreText
import Foundation

public enum Format {
    public static func timestampHHMMSS(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    public static func escapeXML(_ s: String) -> String {
        escapeHTML(s)
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
