import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A capture whose file never comes back, so a Stop ends there instead of starting a transcription.
private struct LostFileSource: LiveAudioSource {
    func start() async throws {}
    func prepare() async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func cancel() async {}
}

@MainActor
@Suite("Recording predicates")
struct RecordingPredicateTests {
    private func makeModel() -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("recording-predicates"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
    }

    @Test("a paused take is still a take in progress")
    func pausedCounts() throws {
        let wav = try tempWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeModel()
        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
        #expect(model.takeIsRunning)
        #expect(model.pauseTake())
        #expect(model.takeIsRunning)
        #expect(model.takeInProgress)
    }

    @Test("the bridge still calls a running take \"recording\"")
    func bridgePhaseName() throws {
        let wav = try tempWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeModel()
        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
        #expect(ParolaAutomationServer.phaseName(for: model) == "recording")
    }

    @Test("a take holds on when something else moves the phase")
    func takeOutlivesThePhase() {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        model.phase = .failed(message: "The export failed.")

        #expect(model.takeIsRunning)
        #expect(model.recordingActive)
        #expect(ParolaAutomationServer.phaseName(for: model) == "recording")
        let arrival = URL(fileURLWithPath: "/tmp/parola-predicates-arrival.wav")
        model.transcribe(fileURL: arrival)
        #expect(model.deferredArrivals == [arrival])
    }

    @Test("an installed take lets go of everything when it ends")
    func endingTheTakeLetsGo() {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        #expect(model.recordingActive)

        model.endTestTake()

        #expect(!model.takeIsRunning)
        #expect(!model.recordingActive)
        #expect(model.recording == nil)
    }

    @Test("a Stop intent during a count-in cancels it and says so, even with a file transcribing behind it")
    func stopIntentDuringCountIn() async {
        let model = makeModel()
        model.fileTranscribeTask = Task { try? await Task.sleep(for: .seconds(30)) }
        defer {
            model.fileTranscribeTask?.cancel()
            model.fileTranscribeTask = nil
        }
        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == 60)
        #expect(model.takeIsRunning)

        let answer = await awaitGuarded("the Stop intent's answer", timeout: .seconds(2)) { () async -> IntentActionError? in
            do {
                _ = try await model.stopRecordingFromIntent()
                return nil
            } catch {
                return error as? IntentActionError
            }
        }
        // Frees a waiter the guard would have let through, so a failing run doesn't leave it hanging.
        model.resolveEveryRecordingOutcome(.failure(IntentActionError.cancelled))

        #expect(answer == .some(.cancelled))
        #expect(!model.takeIsRunning)
        #expect(model.recording == nil)
    }

    @Test("the mic hotkey stops a mic take by its session, whatever the phase says")
    func micHotkeyStopsTheTake() {
        let model = makeModel()
        model.installTestTake(source: .microphone, liveSource: LostFileSource())
        model.phase = .idle

        model.toggleMicRecording()

        #expect(model.liveSource == nil)
        #expect(model.recording?.state == .finishing)
    }

    @Test("the mic hotkey leaves a Mac-audio take alone")
    func micHotkeySparesAMacAudioTake() {
        let model = makeModel()
        model.installTestTake(source: .systemAudio, liveSource: LostFileSource())
        model.phase = .idle

        model.toggleMicRecording()

        #expect(model.liveSource != nil)
        #expect(model.recording?.isCapturing == true)
    }
}
