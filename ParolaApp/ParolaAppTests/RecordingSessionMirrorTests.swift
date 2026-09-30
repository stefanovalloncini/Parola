import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// Waits are bound before they are expected: a closure inside #expect can share its symbol with a later closure.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording session mirror", .serialized)
    struct RecordingSessionMirrorTests {
        private func makeModel() -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test, library: makeTempLibraryURL("session-mirror"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
            ))
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func landedEntryID(_ model: AppModel) async -> LibraryEntry.ID? {
            var landed: LibraryEntry.ID?
            await waitUntil {
                if case .done(let id?) = model.recording?.state { landed = id }
                return landed != nil
            }
            return landed
        }

        private func startLiveTake(_ model: AppModel, _ response: MockTranscriberResponse) {
            MockStreamingTranscriberRegistry.shared.install(response)
            model.useStreaming = true
            model.selectedModel = "openai_whisper-tiny"
            model.startRecording(source: .microphone)
        }

        @Test("a file take arms, then records from its first buffer, then finishes on Stop")
        func fileTakeStages() async throws {
            let fixture = try makeTakeWAV("mirror-stages")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(gate: MockTranscriberGate()))
                let model = makeModel()
                model.startRecording(source: .microphone)
                #expect(model.recording?.isArming == true)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                #expect(model.recordingStartedAt == model.recording?.startedAt)
                model.stopRecordingAndTranscribe()
                let stopped = model.recording.map { $0.state == .finishing || !$0.isRunning }
                #expect(stopped == true)

                model.cancelCurrentWork()
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("the take's levels fill at ten a second from one sampler")
        func oneSampler() async throws {
            let fixture = try makeTakeWAV("mirror-levels", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.startRecording(source: .microphone)
                let filled = await waitUntil { (model.takeLevels?.sampleCount ?? 0) >= 10 }
                #expect(filled)
                model.cancelCurrentWork()
            }
        }

        @Test("a live take arms while its model loads, records from its first event, and lands on its entry")
        func liveTakeStages() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                let model = makeModel()
                startLiveTake(model, MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "live words")],
                    partials: ["live"], downloadFractions: [0.42], delayMs: 200, gate: gate
                ))
                let preparing = await waitUntil {
                    model.recording?.state == .arming(.preparingModel(name: "openai_whisper-tiny", download: 0.42))
                }
                #expect(preparing)
                #expect(model.recording?.isStreaming == true)

                await gate.open()
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                #expect(model.recording?.state == .finishing)

                let entryID = try #require(await landedEntryID(model))
                let saved = await model.library.list().map(\.id)
                #expect(saved == [entryID])
            }
        }

        @Test("a live take stopped while its model loads ends its session with the reason")
        func liveTakeStoppedWhileLoading() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                startLiveTake(model, MockTranscriberResponse(
                    partials: ["never"], downloadFractions: [0.5], gate: MockTranscriberGate()
                ))
                let preparing = await waitUntil {
                    if case .arming(.preparingModel) = model.recording?.state { return true }
                    return false
                }
                #expect(preparing)

                model.stopRecordingAndTranscribe()

                let reason = AppModel.nothingRecordedMessage(for: .preparingModel(name: "openai_whisper-tiny", download: nil))
                #expect(model.recording?.state == .failed(message: reason))
                let settled = await waitUntil { !model.recordingActive }
                #expect(settled)
            }
        }

        @Test("a count-in is the take's first arming, and it hands the same take to the capture")
        func countInHandsOver() async throws {
            let fixture = try makeTakeWAV("mirror-count-in", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.recordingCountInSeconds = 1
                model.startRecording(source: .microphone)
                #expect(model.recording?.state == .arming(.countIn(remaining: 1)))
                #expect(model.recordingCountdown == 1)
                let countIn = try #require(model.recording?.takeID)

                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                #expect(model.recording?.takeID == countIn)
                #expect(model.recordingCountdown == nil)
                model.cancelCurrentWork()
            }
        }

        @Test("cancelling a count-in leaves no take behind")
        func countInCancelled() {
            let model = makeModel()
            model.recordingCountInSeconds = 3
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 3)

            model.cancelRecordingCountdown()

            #expect(model.recording == nil)
            #expect(model.recordingCountdown == nil)
        }

        @Test("a take refused before it starts keeps the reason in its session")
        func refusedTakeFails() async {
            let model = makeModel()
            model.freeDiskSpaceProvider = { 100_000_000 }

            model.startRecording(source: .microphone)

            let refusal = AppModel.diskSpaceRefusalMessage()
            let refused = await waitUntil { model.recording?.state == .failed(message: refusal) }
            #expect(refused)
            #expect(model.phase == .failed(message: refusal))
        }

        @Test("a take cancelled while it records leaves no session")
        func cancelledTakeLeavesNoSession() async throws {
            let fixture = try makeTakeWAV("mirror-cancel", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)

                model.cancelCurrentWork()

                #expect(model.recording == nil)
                #expect(model.takeLevels == nil)
                #expect(model.recordingStartedAt == nil)
            }
        }

        @Test("a stopped take transcribes in its session, and its save lands it on the entry")
        func fileTakeLandsOnItsEntry() async throws {
            let fixture = try makeTakeWAV("mirror-lands")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                let gate = MockTranscriberGate()
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "kept words")], gate: gate
                ))
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)
                #expect(model.recordingStartedAt == nil, "a take transcribing no longer counts as recording")

                await gate.open()

                let entryID = try #require(await landedEntryID(model))
                let saved = await model.library.list().map(\.id)
                #expect(saved == [entryID])
            }
        }

        @Test("an older take's late save never touches the take recording now")
        func olderTakeLeavesTheNewSessionAlone() async throws {
            let fixture = try makeTakeWAV("mirror-two-takes", seconds: 2)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the first take")], gate: MockTranscriberGate()
                ))
                let model = makeModel()
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)
                let first = try #require(model.recording?.takeID)

                model.startRecording(source: .microphone)
                let second = try #require(model.recording?.takeID)
                #expect(second != first)
                let firstSaved = await waitUntil { await !model.library.list().isEmpty }
                #expect(firstSaved, "the first take is saved untranscribed")
                await settle()

                #expect(model.recording?.takeID == second)
                #expect(model.recording?.isRunning == true)
                model.cancelCurrentWork()
            }
        }
    }
}
