import AppKit
import Foundation
import ParolaCore
import ParolaDictation

struct DictationOverrideEntry: Sendable {
    let prompt: Prompt
    let urlPattern: String?
}

struct PromptDictationProcessor: TextPostProcessor {
    let defaultPrompt: Prompt?
    let overrides: [String: [DictationOverrideEntry]]
    let triggerPrompts: [Prompt]
    var contextProvider: DictationContextProvider?
    let contextConfig: DictationContextConfig
    let language: String?
    let urlResolver: (@Sendable @MainActor (String) async -> URL?)?
    let cleanupTimeout: Duration
    let cleanupRunner: @Sendable (Prompt, String) async -> String?
    var target: DictationTarget?
    var scopedContext: (@Sendable (Int32) -> DictationContextProvider)?

    func targeting(_ target: DictationTarget?) -> PromptDictationProcessor {
        var copy = self
        copy.target = target
        if contextProvider != nil, let target, let scopedContext {
            copy.contextProvider = scopedContext(target.processID)
        }
        return copy
    }

    init(
        defaultPrompt: Prompt?,
        overrides: [String: [DictationOverrideEntry]],
        triggerPrompts: [Prompt] = [],
        contextProvider: DictationContextProvider? = nil,
        contextConfig: DictationContextConfig = DictationContextConfig(),
        language: String? = nil,
        urlResolver: (@Sendable @MainActor (String) async -> URL?)? = nil,
        cleanupTimeout: Duration = .seconds(20),
        cleanupRunner: (@Sendable (Prompt, String) async -> String?)? = nil
    ) {
        self.defaultPrompt = defaultPrompt
        self.overrides = overrides
        self.triggerPrompts = triggerPrompts
        self.contextProvider = contextProvider
        self.contextConfig = contextConfig
        self.language = language
        self.urlResolver = urlResolver ?? { bundleID in await BrowserURLResolver.shared.currentURL(for: bundleID) }
        self.cleanupTimeout = cleanupTimeout
        self.cleanupRunner = cleanupRunner ?? Self.onDeviceCleanup
    }

    private static let onDeviceCleanup: @Sendable (Prompt, String) async -> String? = { prompt, input in
        guard let model = try? await LanguageModelFactory.makeOnDevice(instructions: prompt.instructions) else { return nil }
        return try? await PromptRunner.run(prompt, on: input, model: model)
    }

    /// Spoken-punctuation and capitalization cleanup that feeds the LLM. Never applied on
    /// the promptless "Voice" path, which inserts the transcript exactly as spoken.
    static func rewritten(_ text: String, language: String?) -> String {
        SentenceCapitalizer.applyTo(PronounCapitalizer.applyTo(VoiceCommands.applyTo(text, language: language), language: language))
    }

    func process(_ text: String) async -> String {
        let frontmost: (bundleID: String?, name: String?)
        if let target {
            frontmost = (target.bundleID, target.appName)
        } else {
            frontmost = await frontmostAppContext()
        }
        let basePrompt: Prompt? = await selectOverridePrompt(bundleID: frontmost.bundleID) ?? defaultPrompt

        let detector = TriggerWordDetector()
        let triggered = detector.detect(text, against: triggerPrompts)
        let triggerMatch = triggered.flatMap { match in
            triggerPrompts.first(where: { $0.id == match.promptID }).map { (prompt: $0, cleaned: match.cleanedText) }
        }

        let prompt: Prompt? = triggerMatch?.prompt ?? basePrompt
        guard let prompt else { return text }
        // Just the trigger word and nothing else: there is no content to clean up, and
        // an LLM handed empty input replies with chatter that would get inserted.
        if let match = triggerMatch,
           match.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        let input = Self.rewritten(triggerMatch?.cleaned ?? text, language: language)
        let context = await gatheredContext()
        let situated = contextualizing(prompt, with: frontmost.name, context: context)
        let runner = cleanupRunner
        let result = await AsyncTimeout.run(cleanupTimeout) { await runner(situated, input) }
        if let cleaned = result ?? nil {
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return input
    }

    func selectOverridePrompt(bundleID: String?) async -> Prompt? {
        guard let bundleID, let entries = overrides[bundleID], !entries.isEmpty else { return nil }
        let hasURLRule = entries.contains { !($0.urlPattern ?? "").isEmpty }
        let url: URL? = hasURLRule ? (target != nil ? target?.url : await resolveURL(bundleID: bundleID)) : nil
        if let url, let match = entries.first(where: { entry in
            guard let pattern = entry.urlPattern, !pattern.isEmpty else { return false }
            return matches(pattern: pattern, url: url)
        }) {
            return match.prompt
        }
        return entries.first(where: { ($0.urlPattern ?? "").isEmpty })?.prompt
    }

    @MainActor
    private func resolveURL(bundleID: String) async -> URL? {
        await urlResolver?(bundleID)
    }

    private func matches(pattern: String, url: URL) -> Bool {
        let needle = pattern.lowercased()
        if let host = url.host?.lowercased(), host.contains(needle) { return true }
        return url.absoluteString.lowercased().contains(needle)
    }

    private func gatheredContext() async -> DictationContext {
        guard let contextProvider, !contextConfig.isAllDisabled else { return .empty }
        return await contextProvider.gather(contextConfig, timeout: .milliseconds(1500))
    }

    func contextualizing(_ prompt: Prompt, with appName: String?, context: DictationContext) -> Prompt {
        guard prompt.useSystemInstructions else { return prompt }
        var copy = prompt
        var prefixLines: [String] = []
        if let appName, !appName.isEmpty {
            prefixLines.append("Context: the user is dictating into \(appName).")
        }
        let block = context.promptBlock()
        if !block.isEmpty {
            prefixLines.append(block)
        }
        if prefixLines.isEmpty { return prompt }
        copy.instructions = prefixLines.joined(separator: "\n\n") + "\n\n" + prompt.instructions
        return copy
    }

    @MainActor
    private func frontmostAppContext() async -> (bundleID: String?, name: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        return (app.bundleIdentifier, app.localizedName)
    }
}
