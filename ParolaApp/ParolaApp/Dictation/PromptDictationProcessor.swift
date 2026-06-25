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
    let contextProvider: DictationContextProvider?
    let contextConfig: DictationContextConfig
    let language: String?
    let urlResolver: (@Sendable @MainActor (String) -> URL?)?

    init(
        defaultPrompt: Prompt?,
        overrides: [String: [DictationOverrideEntry]],
        triggerPrompts: [Prompt] = [],
        contextProvider: DictationContextProvider? = nil,
        contextConfig: DictationContextConfig = DictationContextConfig(),
        language: String? = nil,
        urlResolver: (@Sendable @MainActor (String) -> URL?)? = nil
    ) {
        self.defaultPrompt = defaultPrompt
        self.overrides = overrides
        self.triggerPrompts = triggerPrompts
        self.contextProvider = contextProvider
        self.contextConfig = contextConfig
        self.language = language
        self.urlResolver = urlResolver ?? { bundleID in BrowserURLResolver.shared.currentURL(for: bundleID) }
    }

    func process(_ text: String) async -> String {
        let preprocessed = SentenceCapitalizer.applyTo(PronounCapitalizer.applyTo(VoiceCommands.applyTo(text), language: language))
        let frontmost = await frontmostAppContext()
        let basePrompt: Prompt? = await selectOverridePrompt(bundleID: frontmost.bundleID) ?? defaultPrompt

        let detector = TriggerWordDetector()
        let triggered = detector.detect(preprocessed, against: triggerPrompts)
        let triggerMatch = triggered.flatMap { match in
            triggerPrompts.first(where: { $0.id == match.promptID }).map { (prompt: $0, cleaned: match.cleanedText) }
        }

        let prompt: Prompt? = triggerMatch?.prompt ?? basePrompt
        let input = triggerMatch?.cleaned ?? preprocessed
        guard let prompt else { return input }
        let context = await gatheredContext()
        do {
            let situated = contextualizing(prompt, with: frontmost.name, context: context)
            let model = try await LanguageModelFactory.makeOnDevice(instructions: situated.instructions)
            let result = try await PromptRunner.run(situated, on: input, model: model)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? input : trimmed
        } catch {
            return input
        }
    }

    func selectOverridePrompt(bundleID: String?) async -> Prompt? {
        guard let bundleID, let entries = overrides[bundleID], !entries.isEmpty else { return nil }
        let url: URL? = await resolveURL(bundleID: bundleID)
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
        urlResolver?(bundleID)
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

    private func contextualizing(_ prompt: Prompt, with appName: String?, context: DictationContext) -> Prompt {
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
