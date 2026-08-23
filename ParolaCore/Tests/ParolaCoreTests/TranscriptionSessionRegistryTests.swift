import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription session engine registry")
struct TranscriptionSessionRegistryTests {
    private actor DownloadLog {
        private(set) var variants: [String] = []

        func record(_ variant: String) { variants.append(variant) }
    }

    private func makeSetup(
        _ downloads: DownloadLog
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            language: "en",
            modelName: "mock-whisper"
        )
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) },
            downloader: { variant, store, _ in
                await downloads.record(variant)
                let url = store.installedURL(for: variant)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: url.appendingPathComponent("model.bin"))
                return url
            }
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-registry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let session = TranscriptionSession(
            modelStore: ModelStore(modelsDirectory: dir),
            registry: registry
        )
        return (session, audioURL)
    }

    @Test("an on-demand download resolves through the session's registry, not the shared one")
    func downloadUsesInjectedRegistry() async throws {
        let downloads = DownloadLog()
        let (session, audioURL) = try await makeSetup(downloads)

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        await session.unloadModel()

        #expect(transcript.modelName == "mock-whisper")
        #expect(
            await downloads.variants == ["openai_whisper-tiny"],
            "the injected registry's downloader must run; falling back to .shared fetches the real model"
        )
    }

    @Test("a failed download leaves the caller's own engine registration intact")
    func downloadLeavesRegisteredEnginesAlone() async throws {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            language: "en",
            modelName: "mock-parakeet"
        )
        // Parakeet's real capabilities say supportsTranslate == false, so seeing true afterwards
        // proves the built-in bootstrap did not overwrite this entry.
        await registry.register(
            engineID: .parakeet,
            capabilities: .whisperKitDefaults
        ) { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-registry-clobber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)

        await #expect(throws: ParolaError.self) {
            _ = try await store.download(
                variant: "nvidia_parakeet-tdt-0.6b-v2", registry: registry
            )
        }
        #expect(await registry.capabilities(for: .parakeet)?.supportsTranslate == true)
    }
}
