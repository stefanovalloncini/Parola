import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Token budget guardrail")
struct TokenBudgetTests {
    @Test("estimateTokens returns at least one token for non-empty text")
    func minimumTokens() {
        #expect(TokenBudget.estimateTokens("hi") >= 1)
        #expect(TokenBudget.estimateTokens("") == 1)
    }

    @Test("estimateTokens grows roughly with byte count")
    func growsWithText() {
        let small = TokenBudget.estimateTokens(String(repeating: "x", count: 8))
        let big = TokenBudget.estimateTokens(String(repeating: "x", count: 16))
        #expect(big > small)
    }

    @Test("estimateTokens counts UTF-8 bytes, not grapheme clusters")
    func countsBytes() {
        #expect(TokenBudget.estimateTokens("abcd") == 1)
        #expect(TokenBudget.estimateTokens("però") == 2)
        #expect(TokenBudget.estimateTokens("👩‍👩‍👧") == 5)
    }

    @Test("check passes when transcript fits in the context window")
    func smallFits() throws {
        let history = [ChatTurn(role: .user, text: "hi")]
        try TokenBudget.check(history: history, system: "system", provider: .openAI)
    }

    @Test("check throws tokenBudgetExceeded when transcript overflows")
    func budgetExceeded() {
        let huge = String(repeating: "x", count: 1_000_000)
        let history = [ChatTurn(role: .user, text: huge)]
        var thrown: CloudLLMError?
        do {
            try TokenBudget.check(history: history, system: "system", provider: .openAI)
        } catch let e as CloudLLMError {
            thrown = e
        } catch {}
        switch thrown {
        case .tokenBudgetExceeded(let provider, _, _):
            #expect(provider == .openAI)
        default:
            Issue.record("expected tokenBudgetExceeded, got \(String(describing: thrown))")
        }
    }

    @Test("a window size the OS reports is read once; a failed read is tried again")
    func reportedContextSizeKeepsOnlyAnAnswer() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let answers: [Int?] = [nil, 8192, 16_384]
        let size = ReportedContextSize {
            reads.withLock { count in
                defer { count += 1 }
                return answers[min(count, answers.count - 1)]
            }
        }

        #expect(size.value(orElse: 4096) == 4096)
        #expect(size.value(orElse: 4096) == 8192)
        #expect(size.value(orElse: 4096) == 8192)
        #expect(reads.withLock { $0 } == 2)
    }
}
