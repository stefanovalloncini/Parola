import Foundation
import Testing
@testable import ParolaCore

@Suite("An engine that isn't loaded fails as a load, not as the file")
struct EngineLoadFailureTests {

    private func store() -> (ModelStore, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("parola-load-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (ModelStore(modelsDirectory: tmp), tmp)
    }

    private func expectLoadFailure(_ run: () async throws -> Transcript) async {
        do {
            _ = try await run()
            Issue.record("the run should have failed")
        } catch let error as ParolaError {
            guard case .engineLoadFailed = error else {
                Issue.record("expected engineLoadFailed, got \(error.logKind)")
                return
            }
        } catch {
            Issue.record("expected a ParolaError, got \(error)")
        }
    }

    @Test("every engine asked to transcribe before it loaded reports a load failure")
    func unloadedEnginesReportALoadFailure() async {
        let (models, tmp) = store()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("clip.wav")
        let options = TranscriptionOptions(model: "m", language: "en")

        await expectLoadFailure {
            try await WhisperKitTranscriber(modelStore: models).transcribe(
                url: file, options: options, handlers: TranscribeHandlers()
            )
        }
        await expectLoadFailure {
            try await ParakeetTranscriber(modelStore: models).transcribe(
                url: file, options: options, handlers: TranscribeHandlers()
            )
        }
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        await expectLoadFailure {
            try await AppleSpeechTranscriber(modelStore: models).transcribe(
                url: file, options: options, handlers: TranscribeHandlers()
            )
        }
    }

    @Test("a load failure reads like any transcription failure and logs no reason")
    func loadFailureMessageAndLogKind() {
        let error = ParolaError.engineLoadFailed("SpeakerKit init failed: /Users/someone/models")
        #expect(error.description == "Transcription failed: SpeakerKit init failed: /Users/someone/models")
        #expect(error.logKind == "ParolaError.engineLoadFailed")
    }
}
