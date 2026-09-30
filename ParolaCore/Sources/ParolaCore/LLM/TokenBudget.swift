import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// How much one call to a model can carry. `contextTokens` is the model's whole window, instructions,
/// input and answer together; `tokens` is what instructions and input may use once the answer's
/// share is set aside.
public struct TokenBudget: Sendable, Hashable {
    public let contextTokens: Int
    public let answerTokens: Int
    /// The longest answer the model returns in one call, whatever room the window leaves.
    public let maxAnswerTokens: Int
    /// What a chat reply is kept: a cloud model refuses a request that leaves less than its whole answer share.
    let chatReplyTokens: Int
    let counting: Counting

    enum Counting: Sendable, Hashable {
        case bytes(perToken: Int)
        /// Apple's tokenizer where the OS has one, else 3 bytes a token (bytes/4 undercounts timestamped lines by up to a third).
        case onDevice
    }

    public var tokens: Int { max(1, contextTokens - answerTokens) }

    /// A budget for a model whose window the caller knows, counted at four bytes a token.
    public init(tokens: Int, answerTokens: Int = 1024) {
        self.init(contextTokens: tokens + answerTokens, answerTokens: answerTokens, counting: .bytes(perToken: 4))
    }

    init(
        contextTokens: Int,
        answerTokens: Int,
        counting: Counting,
        maxAnswerTokens: Int? = nil,
        chatReplyTokens: Int? = nil
    ) {
        self.contextTokens = contextTokens
        self.answerTokens = answerTokens
        self.maxAnswerTokens = maxAnswerTokens ?? contextTokens
        self.chatReplyTokens = chatReplyTokens ?? min(1024, answerTokens / 2)
        self.counting = counting
    }

    public init(for choice: LanguageModelProviderChoice) {
        switch choice {
        case .onDevice:
            self = .onDevice
        case .cloud(let provider, _):
            self = .cloud(provider)
        case .ollama:
            self.init(
                contextTokens: OllamaLanguageModel.defaultContextTokens, answerTokens: 4096,
                counting: .bytes(perToken: 4), maxAnswerTokens: 4096
            )
        case .custom:
            self.init(contextTokens: 8192, answerTokens: 4096, counting: .bytes(perToken: 4), maxAnswerTokens: 4096)
        }
    }

    /// What instructions and input may take in one call on `choice`.
    public static func tokens(for choice: LanguageModelProviderChoice) -> Int {
        TokenBudget(for: choice).tokens
    }

    /// Apple's on-device model: the window the OS reports (4,096 before macOS 27), a quarter kept for the answer.
    public static var onDevice: TokenBudget {
        let context = ReportedContextSize.onDevice.value(orElse: 4096)
        return TokenBudget(contextTokens: context, answerTokens: context / 4, counting: .onDevice)
    }

    static func cloud(_ provider: CloudLLMProviderID) -> TokenBudget {
        let context = CloudLLMProviderInfo.info(for: provider)?.contextWindowTokens ?? 8192
        return TokenBudget(
            contextTokens: context,
            answerTokens: cloudMaxAnswerTokens,
            counting: .bytes(perToken: 4),
            maxAnswerTokens: cloudMaxAnswerTokens,
            chatReplyTokens: cloudMaxAnswerTokens
        )
    }

    /// Anthropic's calls ask for at most this many tokens, and OpenAI-compatible models stop near it or later.
    static let cloudMaxAnswerTokens = 4096

    /// What a condensed chat leaves unfilled in its instructions, so the most recent turns still fit.
    var condensedTurnTokens: Int {
        min(2048, tokens / 8)
    }

    // MARK: - Counting

    private var bytesPerToken: Int {
        switch counting {
        case .bytes(let perToken): return max(1, perToken)
        case .onDevice: return 3
        }
    }

    func estimate(_ text: String) -> Int {
        estimate(utf8Count: text.utf8.count)
    }

    func estimate(utf8Count: Int) -> Int {
        max(1, (utf8Count + bytesPerToken - 1) / bytesPerToken)
    }

    func characters(forTokens tokens: Int) -> Int {
        max(0, tokens) * bytesPerToken
    }

    /// The model's own count where it can give one, the estimate otherwise.
    func count(_ text: String) async -> Int {
        if case .onDevice = counting, let exact = await Self.onDeviceTokenCount(text) {
            return exact
        }
        return estimate(text)
    }

    /// Whether `text` fits in `limit` tokens. A token is at least one byte, so a short text never needs counting.
    func fits(_ text: String, within limit: Int) async -> Bool {
        if text.utf8.count <= limit { return true }
        return await count(text) <= limit
    }

    fileprivate static func readOnDeviceContextSize() -> Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            let size = SystemLanguageModel.default.contextSize
            if size > 0 { return size }
        }
        #endif
        return nil
    }

    private static func onDeviceTokenCount(_ text: String) async -> Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            return try? await SystemLanguageModel.default.tokenCount(for: text)
        }
        #endif
        return nil
    }

    // MARK: - Cloud guardrail

    static func estimateTokens(_ text: String) -> Int {
        estimateTokens(utf8Count: text.utf8.count)
    }

    static func estimateTokens(utf8Count: Int) -> Int {
        max(1, (utf8Count + 3) / 4)
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

/// Reading the OS's window size blocks, so an answer is kept for the process; a failed read is not, as Apple Intelligence can turn on later.
final class ReportedContextSize: Sendable {
    static let onDevice = ReportedContextSize(read: TokenBudget.readOnDeviceContextSize)

    private let read: @Sendable () -> Int?
    private let reported = OSAllocatedUnfairLock<Int?>(initialState: nil)

    init(read: @escaping @Sendable () -> Int?) {
        self.read = read
    }

    func value(orElse fallback: Int) -> Int {
        if let size = reported.withLock({ $0 }) { return size }
        guard let size = read() else { return fallback }
        reported.withLock { $0 = size }
        return size
    }
}
