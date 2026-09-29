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

@Suite("A file that isn't there fails as missing")
struct FileMissingTests {
    @Test("a file source for a path with nothing at it throws fileMissing, named without its folders")
    func missingFileIsTyped() async {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("parola-gone-\(UUID().uuidString).wav")
        do {
            _ = try await FileAudioSource(url: gone).prepare()
            Issue.record("a missing file should fail")
        } catch let error as ParolaError {
            guard case .fileMissing(let url) = error else {
                Issue.record("expected fileMissing, got \(error.logKind)")
                return
            }
            #expect(url == gone)
            #expect(error.description == "Parola couldn't find \(gone.lastPathComponent).")
            #expect(error.logKind == "ParolaError.fileMissing")
        } catch {
            Issue.record("expected a ParolaError, got \(error)")
        }
    }
}
