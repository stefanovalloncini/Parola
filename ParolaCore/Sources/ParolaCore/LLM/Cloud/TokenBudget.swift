import Foundation

enum TokenBudget {
    static func estimateTokens(_ text: String) -> Int {
        let charCount = text.count
        return max(1, Int((Double(charCount) / 4.0).rounded(.up)))
    }

    static func estimateTokens(forHistory turns: [ChatTurn], system: String) -> Int {
        var total = estimateTokens(system)
        for turn in turns {
            total += estimateTokens(turn.text) + 4
        }
        return total
    }

    static func check(
        history: [ChatTurn],
        system: String,
        provider: CloudLLMProviderID,
        responseHeadroom: Int = 4096
    ) throws {
        guard let info = CloudLLMProviderInfo.info(for: provider) else { return }
        let used = estimateTokens(forHistory: history, system: system)
        let limit = info.contextWindowTokens - responseHeadroom
        if used > limit {
            throw CloudLLMError.tokenBudgetExceeded(provider: provider, used: used, limit: limit)
        }
    }
}
