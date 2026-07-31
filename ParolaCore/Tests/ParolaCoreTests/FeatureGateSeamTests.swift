import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Feature gate seams")
struct FeatureGateSeamTests {
    private let none = FeatureSet(enabled: [])
    private let stubTranscript = Transcript(
        segments: [], language: "en", modelName: "stub",
        sourceURL: URL(fileURLWithPath: "/tmp/stub.wav")
    )
    private var stubModel: MockLanguageModel {
        MockLanguageModel(scriptedResponses: ["stub"])
    }

    @Test func youtubeSourceRefusesWhenDisabled() {
        #expect(throws: ParolaError.self) {
            _ = try YouTubeAudioSource(url: URL(string: "https://youtu.be/x123")!, features: none)
        }
    }

    @Test func youtubeSourceAllowsWhenEnabled() throws {
        _ = try YouTubeAudioSource(
            url: URL(string: "https://youtu.be/x123")!,
            features: FeatureSet(enabled: [.youtube])
        )
    }

    @Test func batchQueueFailsEveryJobWhenDisabled() async {
        let queue = BatchQueue(features: none)
        let jobs = [
            BatchJob(url: URL(fileURLWithPath: "/tmp/a.wav")),
            BatchJob(url: URL(fileURLWithPath: "/tmp/b.wav")),
        ]
        var failed = 0
        var finished = false
        for await event in await queue.process(jobs: jobs, options: TranscriptionOptions()) {
            switch event {
            case .failed(_, let reason):
                failed += 1
                #expect(reason.contains("disabled in this deployment"))
            case .finished:
                finished = true
            default:
                Issue.record("unexpected event \(event)")
            }
        }
        #expect(failed == 2)
        #expect(finished)
    }

    @Test func summaryServiceRefusesWhenDisabled() async {
        let service = SummaryService(features: none)
        await #expect(throws: ParolaError.self) {
            _ = try await service.summarise(stubTranscript, model: stubModel)
        }
    }

    @Test func transcriptChatRefusesWhenDisabled() {
        #expect(throws: ParolaError.self) {
            _ = try TranscriptChat.makeSession(transcript: stubTranscript, features: none)
        }
    }

    @Test func promptRunnerRefusesWhenDisabled() async {
        let prompt = Prompt(name: "Test", instructions: "Echo")
        await #expect(throws: ParolaError.self) {
            _ = try await PromptRunner.run(prompt, on: "hello", model: stubModel, features: none)
        }
    }

    @Test func dictationCoordinatorIgnoresStartWhenDisabled() async {
        actor SpyHotkey: HotkeyMonitor {
            var started = false
            func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async { started = true }
            func stop() async {}
        }
        actor NoRecorder: DictationRecorder {
            func start() async throws {}
            func stopAndTranscribe() async throws -> String { "" }
            func stopAndDiscard() async {}
        }
        struct NoInserter: TextInserter {
            func insert(_ text: String) async throws {}
        }
        let hotkey = SpyHotkey()
        let coordinator = DictationCoordinator(
            hotkey: hotkey,
            recorder: NoRecorder(),
            inserter: NoInserter(),
            features: none
        )
        await coordinator.startMonitoring()
        #expect(await hotkey.started == false)
    }
}
