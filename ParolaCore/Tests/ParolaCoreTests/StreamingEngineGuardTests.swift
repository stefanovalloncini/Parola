import Foundation
import Testing
@testable import ParolaCore

@Suite("Streaming engine guard")
struct StreamingEngineGuardTests {
    @Test("start rejects a model whose engine can't stream, before any download")
    func startRejectsNonWhisperModel() async {
        let session = StreamingTranscriptionSession(
            modelStore: ModelStore(
                modelsDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("streaming-guard-tests-\(UUID().uuidString)")
            )
        )
        do {
            _ = try await session.start(
                options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2")
            )
            Issue.record("expected unsupportedForEngine")
        } catch let error as ParolaError {
            guard case .unsupportedForEngine = error else {
                Issue.record("expected unsupportedForEngine, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ParolaError, got \(error)")
        }
    }
}
