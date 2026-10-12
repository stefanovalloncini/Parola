import Foundation
import os
import ParolaCore
import Translation

/// One pass of translation over a transcript's segments. `TranslationCoordinator` only ever talks
/// to this, so the on-device framework and the test mock are interchangeable.
protocol TranscriptTranslating: Sendable {
    /// What goes into the translation's `provider` field.
    var providerName: String { get }

    /// The translated text of every segment the provider could translate, keyed by segment id.
    /// A segment the provider skipped is simply absent.
    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String]

    /// Stops the call in flight for a provider that doesn't answer task cancellation.
    func cancel()
}

extension TranscriptTranslating {
    func cancel() {}
}

/// Drives one `TranslationSession`. The session is bound to the `.translationTask` that produced it,
/// so this lives only as long as that modifier's action.
final class AppleTranslator: TranscriptTranslating {
    static let provider = "apple"

    let providerName = AppleTranslator.provider

    // Non-Sendable session handed from the main actor to `session.translations`; one translator per run, calls awaited in sequence, and `cancel()` is the framework's own way to stop one mid-call.
    nonisolated(unsafe) private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        let responses = try await session.translations(from: TranslationBatcher.requests(for: texts))
        return TranslationBatcher.reassemble(responses)
    }

    func cancel() {
        session.cancel()
    }
}

/// Test-mode translator. Never touches the Translation framework, so a sandbox run and the test
/// suite need no language pack installed.
struct MockTranslator: TranscriptTranslating {
    enum Mode: String, Sendable, CaseIterable {
        case reverseWords
        case map
    }

    let mode: Mode
    let map: [String: String]
    /// Holds each batch back, so a scripted run can be watched making progress.
    let delayMs: Int

    var providerName: String { "mock" }

    init(mode: Mode, map: [String: String] = [:], delayMs: Int = 0) {
        self.mode = mode
        self.map = map
        self.delayMs = delayMs
    }

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
        if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
        var out: [Int: String] = [:]
        for unit in texts {
            switch mode {
            case .reverseWords:
                out[unit.id] = unit.text.split(separator: " ").reversed().joined(separator: " ")
            case .map:
                if let translated = map[unit.text] { out[unit.id] = translated }
            }
        }
        return out
    }
}

final class MockTranslatorRegistry: Sendable {
    static let shared = MockTranslatorRegistry()
    private let state = OSAllocatedUnfairLock<MockTranslator?>(initialState: nil)
    init() {}
    func install(_ translator: MockTranslator) { state.withLock { $0 = translator } }
    func clear() { state.withLock { $0 = nil } }
    func resolve() -> MockTranslator? { state.withLock { $0 } }
}
