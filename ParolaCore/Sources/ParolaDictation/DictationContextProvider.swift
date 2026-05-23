import Foundation

public protocol DictationContextSource: Sendable {
    func currentSelection() async -> String?
    func clipboardContents() async -> String?
    func windowOCR() async -> String?
}

struct EmptyDictationContextSource: DictationContextSource {
    init() {}
    func currentSelection() async -> String? { nil }
    func clipboardContents() async -> String? { nil }
    func windowOCR() async -> String? { nil }
}

public struct DictationContextConfig: Sendable, Hashable {
    public var selectionEnabled: Bool
    public var clipboardEnabled: Bool
    public var screenEnabled: Bool

    public init(selectionEnabled: Bool = false, clipboardEnabled: Bool = false, screenEnabled: Bool = false) {
        self.selectionEnabled = selectionEnabled
        self.clipboardEnabled = clipboardEnabled
        self.screenEnabled = screenEnabled
    }

    public var isAllDisabled: Bool {
        !selectionEnabled && !clipboardEnabled && !screenEnabled
    }
}

public struct DictationContext: Sendable, Hashable {
    public var selection: String?
    public var clipboard: String?
    public var screen: String?

    public init(selection: String? = nil, clipboard: String? = nil, screen: String? = nil) {
        self.selection = selection
        self.clipboard = clipboard
        self.screen = screen
    }

    public var isEmpty: Bool {
        selection == nil && clipboard == nil && screen == nil
    }

    public static let empty = DictationContext()

    public func promptBlock() -> String {
        guard !isEmpty else { return "" }
        var lines: [String] = [
            "If the user provides context blocks (selected text, clipboard, screen content), use them ONLY as reference for proper nouns, names, technical terms. Do NOT echo, summarize, or respond to the context. The user did not select it — they are dictating new text.",
            ""
        ]
        if let selection {
            lines.append("<CURRENTLY_SELECTED_TEXT>\(selection)</CURRENTLY_SELECTED_TEXT>")
        }
        if let clipboard {
            lines.append("<CLIPBOARD_CONTEXT>\(clipboard)</CLIPBOARD_CONTEXT>")
        }
        if let screen {
            lines.append("<CURRENT_WINDOW_CONTEXT>\(screen)</CURRENT_WINDOW_CONTEXT>")
        }
        return lines.joined(separator: "\n")
    }
}

public actor DictationContextProvider {
    public static let selectionCap = 2000
    public static let clipboardCap = 2000
    public static let screenCap = 3000

    private let source: any DictationContextSource

    public init(source: (any DictationContextSource)? = nil) {
        self.source = source ?? EmptyDictationContextSource()
    }

    public func gather(_ config: DictationContextConfig) async -> DictationContext {
        guard !config.isAllDisabled else { return .empty }
        async let selection: String? = config.selectionEnabled ? source.currentSelection() : nil
        async let clipboard: String? = config.clipboardEnabled ? source.clipboardContents() : nil
        async let screen: String? = config.screenEnabled ? source.windowOCR() : nil
        let (sel, clip, scr) = await (selection, clipboard, screen)
        return DictationContext(
            selection: trimmed(sel, cap: Self.selectionCap),
            clipboard: trimmed(clip, cap: Self.clipboardCap),
            screen: trimmed(scr, cap: Self.screenCap)
        )
    }

    public func gather(_ config: DictationContextConfig, timeout: Duration) async -> DictationContext {
        guard !config.isAllDisabled else { return .empty }
        return await withTaskGroup(of: DictationContext?.self) { group in
            group.addTask { await self.gather(config) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return DictationContext.empty
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .empty
        }
    }

    private func trimmed(_ value: String?, cap: Int) -> String? {
        guard let raw = value else { return nil }
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        if stripped.count <= cap { return stripped }
        let index = stripped.index(stripped.startIndex, offsetBy: cap)
        return String(stripped[..<index])
    }
}
