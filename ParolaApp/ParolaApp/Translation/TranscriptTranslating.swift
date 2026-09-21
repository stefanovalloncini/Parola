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
}

/// Drives one `TranslationSession`. The session is bound to the `.translationTask` that produced it,
/// so this lives only as long as that modifier's action.
final class AppleTranslator: TranscriptTranslating {
    let providerName = "apple"

    // The session's methods run off the caller's actor, and one run awaits each call, so nothing else touches it.
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
}

/// Test-mode translator. Never touches the Translation framework, so a sandbox run and the test
/// suite need no language pack installed.
struct MockTranslator: TranscriptTranslating, Sendable {
    enum Mode: String, Sendable, CaseIterable {
        case reverseWords
        case map
    }

    let mode: Mode
    let map: [String: String]

    var providerName: String { "mock" }

    init(mode: Mode, map: [String: String] = [:]) {
        self.mode = mode
        self.map = map
    }

    func translate(
        _ texts: [(id: Int, text: String)], from source: String?, to target: String
    ) async throws -> [Int: String] {
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
