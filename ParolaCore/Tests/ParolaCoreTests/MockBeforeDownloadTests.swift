import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("A mocked engine never downloads its model")
struct MockBeforeDownloadTests {
    private static let model = "openai_whisper-tiny"

    private actor DownloadLog {
        private(set) var variants: [String] = []

        func record(_ variant: String) { variants.append(variant) }
    }

    private struct DownloadRefused: Error {}

    private struct Setup {
        let session: TranscriptionSession
        let store: ModelStore
        let mocks: MockTranscriberRegistry
        let downloads: DownloadLog
        let audioURL: URL
        let folder: URL
    }

    private static let served = MockTranscriberResponse(
        segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "from the mock")],
        language: "en",
        modelName: "served-by-mock"
    )

    private func makeSetup() async throws -> Setup {
        let mocks = MockTranscriberRegistry()
        let registry = EngineRegistry(clock: ImmediateClock(), mocks: mocks)
        let downloads = DownloadLog()
        let registered = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "from the engine")],
            language: "en",
            modelName: "registered-engine"
        )
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { _ in MockTranscriber.make(response: registered, clock: ImmediateClock()) },
            downloader: { variant, _, _ in
                await downloads.record(variant)
                throw DownloadRefused()
            }
        )

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "parola-mock-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appending(path: "input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let store = ModelStore(modelsDirectory: folder.appending(path: "Models", directoryHint: .isDirectory))
        let session = TranscriptionSession(modelStore: store, registry: registry)
        return Setup(
            session: session, store: store, mocks: mocks, downloads: downloads, audioURL: audioURL, folder: folder
        )
    }

    @Test(
        "a mock answers a model that isn't on disk without downloading it",
        arguments: [EngineID?.some(.whisperKit), nil]
    )
    func mockSkipsTheDownload(mockedEngine: EngineID?) async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        await setup.mocks.install(engineID: mockedEngine, response: Self.served)
        let installedBefore = setup.store.isInstalled(Self.model)
        #expect(!installedBefore)

        let plan = await setup.session.modelPlan(for: TranscriptionOptions(model: Self.model))
        let transcript = try await setup.session.transcribe(
            source: FileAudioSource(url: setup.audioURL),
            options: TranscriptionOptions(model: Self.model)
        )
        await setup.session.unloadModel()

        let downloaded = await setup.downloads.variants
        #expect(transcript.modelName == "served-by-mock")
        #expect(transcript.segments.map(\.text) == ["from the mock"])
        #expect(downloaded.isEmpty)
        #expect(!plan.needsDownload)
        #expect(!setup.store.isInstalled(Self.model))
    }

    @Test(
        "without a mock for its engine, a model that isn't on disk is downloaded first",
        arguments: [EngineID?.none, .some(.parakeet)]
    )
    func unmockedEngineDownloads(mockedEngine: EngineID?) async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        if let mockedEngine {
            await setup.mocks.install(engineID: mockedEngine, response: Self.served)
        }

        let plan = await setup.session.modelPlan(for: TranscriptionOptions(model: Self.model))
        var refused = false
        do {
            _ = try await setup.session.transcribe(
                source: FileAudioSource(url: setup.audioURL),
                options: TranscriptionOptions(model: Self.model)
            )
            Issue.record("the run should have failed on the refused download")
        } catch is DownloadRefused {
            refused = true
        } catch {
            Issue.record("expected the downloader's own error, got \(error)")
        }
        await setup.session.unloadModel()

        let downloaded = await setup.downloads.variants
        #expect(refused)
        #expect(downloaded == [Self.model])
        #expect(plan.needsDownload)
    }

    @Test("prewarm never downloads a model that isn't on disk, mocked or not", arguments: [false, true])
    func prewarmNeverDownloads(mocked: Bool) async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        if mocked {
            await setup.mocks.install(engineID: .whisperKit, response: Self.served)
        }

        await setup.session.prewarm(modelName: Self.model)

        let downloaded = await setup.downloads.variants
        let loaded = await setup.session.currentModel()
        #expect(downloaded.isEmpty)
        #expect(loaded == nil)
        #expect(!setup.store.isInstalled(Self.model))
    }
}
