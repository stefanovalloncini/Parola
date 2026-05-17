import Foundation

public protocol ClipboardReader: Sendable {
    func currentText() -> String?
}

public struct EmptyClipboardReader: ClipboardReader {
    public init() {}
    public func currentText() -> String? { nil }
}

public struct SnippetExpander: TextPostProcessor {
    public let snippets: [Snippet]
    public let clipboard: any ClipboardReader
    public let now: @Sendable () -> Date

    public init(
        snippets: [Snippet],
        clipboard: any ClipboardReader = EmptyClipboardReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.snippets = snippets
        self.clipboard = clipboard
        self.now = now
    }

    public func process(_ text: String) async -> String {
        let active = snippets.filter { $0.enabled && !$0.trigger.isEmpty }
        guard !active.isEmpty else { return text }
        var result = text
        for snippet in active {
            let expanded = Self.expand(snippet.replacement, clipboard: clipboard, now: now())
            result = Self.replace(trigger: snippet.trigger, in: result, with: expanded)
        }
        return result
    }

    static func replace(trigger: String, in text: String, with replacement: String) -> String {
        guard let pattern = wordBoundedPattern(for: trigger) else {
            return text.replacingOccurrences(of: trigger, with: replacement, options: .caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.replacingOccurrences(of: trigger, with: replacement, options: .caseInsensitive)
        }
        let range = NSRange(text.startIndex..., in: text)
        let escaped = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: escaped)
    }

    private static func wordBoundedPattern(for trigger: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        guard !escaped.isEmpty else { return nil }
        return "\\b\(escaped)\\b"
    }

    public static func expand(_ replacement: String, clipboard: any ClipboardReader, now: Date) -> String {
        var out = replacement
        if out.contains("{{DATE}}") {
            out = out.replacingOccurrences(of: "{{DATE}}", with: localizedDate(now))
        }
        if out.contains("{{TIME}}") {
            out = out.replacingOccurrences(of: "{{TIME}}", with: localizedTime(now))
        }
        if out.contains("{{ISODATE}}") {
            out = out.replacingOccurrences(of: "{{ISODATE}}", with: isoDate(now))
        }
        if out.contains("{{CLIPBOARD}}") {
            let pasted = clipboard.currentText() ?? ""
            out = out.replacingOccurrences(of: "{{CLIPBOARD}}", with: pasted)
        }
        return out
    }

    private static func localizedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    private static func localizedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
