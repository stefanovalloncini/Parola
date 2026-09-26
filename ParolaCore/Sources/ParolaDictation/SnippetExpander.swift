import Foundation
import ParolaCore

public protocol ClipboardReader: Sendable {
    func currentText() -> String?
}

struct EmptyClipboardReader: ClipboardReader {
    init() {}
    func currentText() -> String? { nil }
}

/// Reads the current text selection from the frontmost app. Implemented in the macOS app
/// using the Accessibility API; ParolaCore only knows the protocol.
public protocol SelectionReader: Sendable {
    func currentSelection() -> String?
}

struct EmptySelectionReader: SelectionReader {
    init() {}
    func currentSelection() -> String? { nil }
}

/// Reads the frontmost app's display name or bundle id. The macOS app wires this with
/// `NSWorkspace`; ParolaCore stays UI-free.
public protocol AppContextReader: Sendable {
    func frontmostAppName() -> String?
}

struct EmptyAppContextReader: AppContextReader {
    init() {}
    func frontmostAppName() -> String? { nil }
}

/// Sentinel inserted in place of `{{CURSOR}}` during expansion. No inserter repositions the
/// caret yet, so the insert path strips it via ``stripped(_:)``; keeping the sentinel reserves
/// the spot for a future split-and-reposition inserter.
enum SnippetMarker {
    static let cursor = "\u{E000}__PAROLA_CURSOR__\u{E001}"

    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: cursor, with: "")
    }
}

public struct SnippetExpander: TextPostProcessor {
    public let snippets: [Snippet]
    public let clipboard: any ClipboardReader
    public let selection: any SelectionReader
    public let appContext: any AppContextReader
    public let now: @Sendable () -> Date
    public let expandDeferred: Bool
    /// One per snippet, nil where it can't fire: compiled here so an utterance never compiles a trigger.
    private let triggers: [CompiledReplacement?]

    public init(
        snippets: [Snippet],
        clipboard: (any ClipboardReader)? = nil,
        selection: (any SelectionReader)? = nil,
        appContext: (any AppContextReader)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        expandDeferred: Bool = false
    ) {
        self.snippets = snippets
        self.clipboard = clipboard ?? EmptyClipboardReader()
        self.selection = selection ?? EmptySelectionReader()
        self.appContext = appContext ?? EmptyAppContextReader()
        self.now = now
        self.expandDeferred = expandDeferred
        // A whitespace-only trigger compiles to nothing, matching the pane, which shows it as disabled.
        self.triggers = snippets.map { $0.enabled ? $0.triggerRule.compiled() : nil }
    }

    public func process(_ text: String) async -> String {
        let active = zip(snippets, triggers).compactMap { snippet, trigger -> (Snippet, CompiledReplacement)? in
            guard let trigger, snippet.expandAtInsert == expandDeferred else { return nil }
            return (snippet, trigger)
        }
        guard !active.isEmpty else { return text }
        let timestamp = now()
        var result = text
        for (snippet, trigger) in active {
            let expanded = Self.expand(
                snippet.replacement,
                clipboard: clipboard,
                selection: selection,
                appContext: appContext,
                now: timestamp
            )
            result = trigger.apply(to: result, replacement: expanded)
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

    static func expand(
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

extension Snippet {
    /// Literal, word-bounded where `_` is a word character, and always case-insensitive.
    var triggerRule: ReplacementRule {
        ReplacementRule(find: trigger, replace: replacement, match: .literalWord(underscoreIsWordCharacter: true), caseSensitive: false)
    }
}
