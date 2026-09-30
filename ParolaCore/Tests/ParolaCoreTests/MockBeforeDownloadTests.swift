import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("A mocked engine never downloads its model")
struct MockBeforeDownloadTests {
    private static let model = "openai_whisper-tiny"
    private static let installedModel = "openai_whisper-base"

    private actor DownloadLog {
        private(set) var variants: [String] = []

        func record(_ variant: String) { variants.append(variant) }
    }

    private actor LoadLog {
        private(set) var missing: [String] = []

        func recordMissing(_ model: String) { missing.append(model) }
    }

    private struct DownloadRefused: Error {}

    /// Stands in for WhisperKit: it loads only what is on disk and never fetches a model itself.
    private actor DiskEngine: Transcriber {
        static let engineID: EngineID = .whisperKit
        static let capabilities: EngineCapabilities = .whisperKitDefaults

        private let store: ModelStore
        private let loads: LoadLog
        private let voice: MockTranscriber
        private var loaded: String?

        init(store: ModelStore, loads: LoadLog) {
            self.store = store
            self.loads = loads
            voice = MockTranscriber.make(
                response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "from the engine")],
                    language: "en",
                    modelName: "real-engine"
                ),
                clock: ImmediateClock()
            )
        }

        func load(model: String) async throws {
            guard store.isInstalled(model) else {
                await loads.recordMissing(model)
                throw ParolaError.engineLoadFailed("\(model) is not on disk")
            }
            loaded = model
        }

        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            try await voice.transcribe(url: url, options: options, handlers: handlers)
        }

        func unload() { loaded = nil }

        func loadedModelName() -> String? { loaded }
    }

    private struct Setup {
        let session: TranscriptionSession
        let store: ModelStore
        let mocks: MockTranscriberRegistry
        let downloads: DownloadLog
        let loads: LoadLog
        let audioURL: URL
        let folder: URL

        func transcribe(_ model: String) async throws -> Transcript {
            try await session.transcribe(source: FileAudioSource(url: audioURL), options: TranscriptionOptions(model: model))
        }
    }

    private static let served = MockTranscriberResponse(
        segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "from the mock")],
        language: "en",
        modelName: "served-by-mock"
    )

    private func makeSetup() async throws -> Setup {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "parola-mock-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appending(path: "input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let store = ModelStore(modelsDirectory: folder.appending(path: "Models", directoryHint: .isDirectory))

        let mocks = MockTranscriberRegistry()
        let registry = EngineRegistry(clock: ImmediateClock(), mocks: mocks)
        let downloads = DownloadLog()
        let loads = LoadLog()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { store in DiskEngine(store: store, loads: loads) },
            downloader: { variant, _, _ in
                await downloads.record(variant)
                throw DownloadRefused()
            }
        )
        let session = TranscriptionSession(modelStore: store, registry: registry)
        return Setup(
            session: session, store: store, mocks: mocks, downloads: downloads, loads: loads,
            audioURL: audioURL, folder: folder
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
        let transcript = try await setup.transcribe(Self.model)
        await setup.session.unloadModel()

        let downloaded = await setup.downloads.variants
        let missingLoads = await setup.loads.missing
        #expect(transcript.modelName == "served-by-mock")
        #expect(transcript.segments.map(\.text) == ["from the mock"])
        #expect(downloaded.isEmpty)
        #expect(missingLoads.isEmpty)
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
        let refused = await refusesTheDownload(setup)
        await setup.session.unloadModel()

        let downloaded = await setup.downloads.variants
        let missingLoads = await setup.loads.missing
        #expect(refused)
        #expect(downloaded == [Self.model])
        #expect(missingLoads.isEmpty)
        #expect(plan.needsDownload)
    }

    @Test("a mock installed after the real engine ran answers, rather than that engine loading a missing model")
    func mockReplacesACachedEngine() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        try setup.store.seedInstalledModel(Self.installedModel)
        let first = try await setup.transcribe(Self.installedModel)
        #expect(first.modelName == "real-engine")

        await setup.mocks.install(engineID: .whisperKit, response: Self.served)
        let second = try await setup.transcribe(Self.model)
        await setup.session.unloadModel()

        let downloaded = await setup.downloads.variants
        let missingLoads = await setup.loads.missing
        #expect(second.modelName == "served-by-mock")
        #expect(downloaded.isEmpty)
        #expect(missingLoads.isEmpty)
    }

    @Test("a mock cleared after it ran leaves the missing model to the download, not to the cached mock")
    func clearedMockDownloads() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.folder) }
        await setup.mocks.install(engineID: .whisperKit, response: Self.served)
        let first = try await setup.transcribe(Self.model)
        #expect(first.modelName == "served-by-mock")

        await setup.mocks.clear()
        let refused = await refusesTheDownload(setup)
        await setup.session.unloadModel()

        let downloaded = await setup.downloads.variants
        let missingLoads = await setup.loads.missing
        #expect(refused)
        #expect(downloaded == [Self.model])
        #expect(missingLoads.isEmpty)
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
        let missingLoads = await setup.loads.missing
        let loaded = await setup.session.currentModel()
        #expect(downloaded.isEmpty)
        #expect(missingLoads.isEmpty)
        #expect(loaded == nil)
        #expect(!setup.store.isInstalled(Self.model))
    }

    private func refusesTheDownload(_ setup: Setup) async -> Bool {
        do {
            _ = try await setup.transcribe(Self.model)
            Issue.record("the run should have failed on the refused download")
        } catch is DownloadRefused {
            return true
        } catch {
            Issue.record("expected the downloader's own error, got \(error)")
        }
        return false
    }
}
