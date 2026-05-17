import Foundation

public protocol ClipboardReader: Sendable {
    func currentText() -> String?
}

public struct EmptyClipboardReader: ClipboardReader {
    public init() {}
    public func currentText() -> String? { nil }
}

/// Reads the current text selection from the frontmost app. Implemented in the macOS app
/// using the Accessibility API; ParolaCore only knows the protocol.
public protocol SelectionReader: Sendable {
    func currentSelection() -> String?
}

public struct EmptySelectionReader: SelectionReader {
    public init() {}
    public func currentSelection() -> String? { nil }
}

/// Reads the frontmost app's display name or bundle id. The macOS app wires this with
/// `NSWorkspace`; ParolaCore stays UI-free.
public protocol AppContextReader: Sendable {
    func frontmostAppName() -> String?
}

public struct EmptyAppContextReader: AppContextReader {
    public init() {}
    public func frontmostAppName() -> String? { nil }
}

/// Sentinel inserted in place of `{{CURSOR}}` during expansion. The inserter splits the
/// final string on this marker and positions the cursor between the two halves.
public enum SnippetMarker {
    public static let cursor = "\u{E000}__PAROLA_CURSOR__\u{E001}"
}

public struct SnippetExpander: TextPostProcessor {
    public let snippets: [Snippet]
    public let clipboard: any ClipboardReader
    public let selection: any SelectionReader
    public let appContext: any AppContextReader
    public let now: @Sendable () -> Date
    public let expandDeferred: Bool

    public init(
        snippets: [Snippet],
        clipboard: any ClipboardReader = EmptyClipboardReader(),
        selection: any SelectionReader = EmptySelectionReader(),
        appContext: any AppContextReader = EmptyAppContextReader(),
        now: @escaping @Sendable () -> Date = { Date() },
        expandDeferred: Bool = false
    ) {
        self.snippets = snippets
        self.clipboard = clipboard
        self.selection = selection
        self.appContext = appContext
        self.now = now
        self.expandDeferred = expandDeferred
    }

    public func process(_ text: String) async -> String {
        let active = snippets.filter { snippet in
            guard snippet.enabled, !snippet.trigger.isEmpty else { return false }
            return expandDeferred ? snippet.expandAtInsert : !snippet.expandAtInsert
        }
        guard !active.isEmpty else { return text }
        let timestamp = now()
        var result = text
        for snippet in active {
            let expanded = Self.expand(
                snippet.replacement,
                clipboard: clipboard,
                selection: selection,
                appContext: appContext,
                now: timestamp
            )
            result = Self.replace(trigger: snippet.trigger, in: result, with: expanded)
        }
        return result
    }

    /// Returns a processor that expands only `expandAtInsert == true` snippets. Use this
    /// after transcription but before paste so live placeholders read current state.
    public func deferredOnly() -> SnippetExpander {
        SnippetExpander(
            snippets: snippets,
            clipboard: clipboard,
            selection: selection,
            appContext: appContext,
            now: now,
            expandDeferred: true
        )
    }

    static func replace(trigger: String, in text: String, with replacement: String) -> String {
        guard let pattern = wordBoundedPattern(for: trigger) else { return text }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
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

    public static func expand(
        _ replacement: String,
        clipboard: any ClipboardReader,
        selection: any SelectionReader = EmptySelectionReader(),
        appContext: any AppContextReader = EmptyAppContextReader(),
        now: Date
    ) -> String {
        var out = replacement
        if out.contains("{{DATE}}") {
            out = out.replacingOccurrences(of: "{{DATE}}", with: longDateFormatter.string(from: now))
        }
        if out.contains("{{TIME}}") {
            out = out.replacingOccurrences(of: "{{TIME}}", with: shortTimeFormatter.string(from: now))
        }
        if out.contains("{{ISODATE}}") {
            out = out.replacingOccurrences(of: "{{ISODATE}}", with: isoDateFormatter.string(from: now))
        }
        if out.contains("{{CLIPBOARD}}") {
            out = out.replacingOccurrences(of: "{{CLIPBOARD}}", with: clipboard.currentText() ?? "")
        }
        if out.contains("{{SELECTION}}") {
            out = out.replacingOccurrences(of: "{{SELECTION}}", with: selection.currentSelection() ?? "")
        }
        if out.contains("{{APP}}") {
            out = out.replacingOccurrences(of: "{{APP}}", with: appContext.frontmostAppName() ?? "")
        }
        if out.contains("{{CURSOR}}") {
            out = out.replacingOccurrences(of: "{{CURSOR}}", with: SnippetMarker.cursor)
        }
        return out
    }

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
