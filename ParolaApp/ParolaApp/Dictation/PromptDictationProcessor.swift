import AppKit
import Foundation
import ParolaCore

struct PromptDictationProcessor: TextPostProcessor {
    let defaultPrompt: Prompt?
    let overrides: [String: Prompt]
    let triggerPrompts: [Prompt]
    let contextProvider: DictationContextProvider?
    let contextConfig: DictationContextConfig

    init(
        defaultPrompt: Prompt?,
        overrides: [String: Prompt],
        triggerPrompts: [Prompt] = [],
        contextProvider: DictationContextProvider? = nil,
        contextConfig: DictationContextConfig = DictationContextConfig()
    ) {
        self.defaultPrompt = defaultPrompt
        self.overrides = overrides
        self.triggerPrompts = triggerPrompts
        self.contextProvider = contextProvider
        self.contextConfig = contextConfig
    }

    func process(_ text: String) async -> String {
        let preprocessed = SentenceCapitalizer.applyTo(PronounCapitalizer.applyTo(VoiceCommands.applyTo(text)))
        let frontmost = await frontmostAppContext()
        let basePrompt: Prompt? = (frontmost.bundleID.flatMap { overrides[$0] }) ?? defaultPrompt

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
            let model = try LanguageModelFactory.makeOnDevice(instructions: situated.instructions)
            let result = try await PromptRunner.run(situated, on: input, model: model)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? input : trimmed
        } catch {
            return input
        }
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
