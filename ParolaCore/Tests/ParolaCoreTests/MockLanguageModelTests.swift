import Foundation
import Testing
import Clocks
@testable import ParolaCore

@Suite("ParolaCore.MockLanguageModel + MockLanguageModelStore")
struct MockLanguageModelTests {

    @Test("respond returns the canned text")
    func respondReturnsCannedText() async throws {
        let response = MockLanguageModelResponse(text: "ciao Stefano")
        let model = ParolaCore.MockLanguageModel.make(response: response, clock: ImmediateClock())

        let answer = try await model.respond(history: [ChatTurn(role: .user, text: "hi")])
        #expect(answer == "ciao Stefano")
    }

    @Test("stream yields each chunk in declared order")
    func streamYieldsChunks() async throws {
        let response = MockLanguageModelResponse(
            text: "one two three",
            streamChunks: ["one ", "two ", "three"]
        )
        let model = ParolaCore.MockLanguageModel.make(response: response, clock: ImmediateClock())

        var collected: [String] = []
        for try await chunk in model.stream(history: []) {
            collected.append(chunk)
        }
        #expect(collected == ["one ", "two ", "three"])
    }

    @Test("respond throws the configured failure error")
    func respondFailureThrows() async {
        let response = MockLanguageModelResponse(
            failure: MockLanguageModelFailure(code: .missingAPIKey, message: "")
        )
        let model = ParolaCore.MockLanguageModel.make(response: response, clock: ImmediateClock())

        do {
            _ = try await model.respond(history: [])
            Issue.record("expected throw")
        } catch let error as CloudLLMError {
            guard case .missingAPIKey = error else {
                Issue.record("unexpected CloudLLMError: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("MockLanguageModelStore.install + resolve scope to a single provider")
    func storeResolvesPerProvider() async {
        let store = MockLanguageModelStore()
        let response = MockLanguageModelResponse(text: "from openai")
        await store.install(provider: .openAI, response: response)

        let resolved = await store.resolve(for: .openAI)
        let missing = await store.resolve(for: .anthropic)

        #expect(resolved?.text == "from openai")
        #expect(missing == nil)
    }

    @Test("clear() empties the store entirely")
    func storeClearWipes() async {
        let store = MockLanguageModelStore()
        await store.install(provider: .openAI, response: MockLanguageModelResponse(text: "a"))
        await store.install(provider: nil, response: MockLanguageModelResponse(text: "global"))

        await store.clear()

        #expect(await store.resolve(for: .openAI) == nil)
        #expect(await store.resolve(for: .anthropic) == nil)
        #expect(await store.list().isEmpty)
    }

    @Test("a lease keeps two callers from overlapping")
    func leaseSerialisesCallers() async throws {
        let store = MockLanguageModelStore()
        let log = LeaseLog()
        let first = Task {
            await store.withLease {
                await log.record("first in")
                try? await Task.sleep(for: .milliseconds(60))
                await log.record("first out")
            }
        }
        // Give the first lessee time to take the lease before the second asks for it.
        try await Task.sleep(for: .milliseconds(20))
        let second = Task {
            await store.withLease {
                await log.record("second in")
                await log.record("second out")
            }
        }
        await first.value
        await second.value

        #expect(await log.entries == ["first in", "first out", "second in", "second out"])
    }

    @Test("a throwing body still releases the lease")
    func leaseReleasesOnThrow() async throws {
        let store = MockLanguageModelStore()
        struct Boom: Error {}

        await #expect(throws: Boom.self) {
            try await store.withLease { throw Boom() }
        }

        let ran = await store.withLease { true }
        #expect(ran)
    }

}

/// Records what each lessee did, in order.
private actor LeaseLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}
