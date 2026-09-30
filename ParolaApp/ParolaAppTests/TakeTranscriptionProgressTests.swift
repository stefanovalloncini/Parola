import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Every label a Dock badge showed, in order.
@MainActor
private final class ShownBadges {
    var labels: [String?] = []
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Take transcription progress", .serialized)
    struct TakeTranscriptionProgressTests {
        private static let pinnedModel = "openai_whisper-tiny"

        private func makeModel(_ label: String) -> AppModel {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            model.selectedModel = Self.pinnedModel
            return model
        }

        private func progress(_ model: AppModel) -> Double? {
            guard case .transcribing(let progress) = model.recording?.state else { return nil }
            return progress
        }

        private func isDone(_ model: AppModel) -> Bool {
            guard case .done = model.recording?.state else { return false }
            return true
        }

        @Test("a stopped take's transcription moves its session's progress and leaves the phase alone")
        func progressMovesTheSession() async throws {
            let audio = try makeTakeWAV("take-progress", seconds: 10)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "words at last")], progressSeconds: [2, 5], gate: gate)
                let model = makeModel("take-progress")

                recordAndStop(model, audio: audio, seconds: 10)

                let halfway = await waitUntil { abs((self.progress(model) ?? 0) - 0.5) < 0.01 }
                #expect(halfway)
                #expect(model.phase == .idle, "the take's run never writes the phase")
                #expect(model.fileTranscribeFraction == nil)
                await gate.open()
                let landed = await waitUntil { model.transcript?.text == "words at last" }
                #expect(landed)
                #expect(model.phase == .ready)
                let done = await waitUntil { self.isDone(model) }
                #expect(done)
            }
        }

        @Test("a take's words and stage reach its Stage, even stopped from another page, and clear once it lands")
        func partialsReachTheStage() async throws {
            let audio = try makeTakeWAV("take-partials", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "hello there")], partials: ["hello", "hello there"], gate: gate)
                let model = makeModel("take-partials")
                model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
                model.goHome()

                model.stopRecordingAndTranscribe()

                let streamed = await waitUntil { model.takePartialText == "hello there" && model.takeTranscribeStage == .transcribing }
                #expect(streamed)
                #expect(model.filePartialText.isEmpty, "the file pane's words belong to a file's run")
                #expect(model.phase == .idle)
                #expect(model.showStage())
                let shown = ContentRoutes.stageTranscription(for: model)
                #expect(shown?.file == audio)
                #expect(shown?.takeID == model.recording?.takeID)

                await gate.open()
                let landed = await waitUntil { model.transcript?.text == "hello there" }
                #expect(landed)
                #expect(model.takePartialText.isEmpty)
                #expect(model.takeTranscribeStage == nil)
                #expect(model.takeTranscription == nil)
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("Stop Transcribing mid-run takes the pane down at once, ignores the run's late callbacks and saves the audio")
        func stopTranscribingIgnoresLateCallbacks() async throws {
            let audio = try makeTakeWAV("take-stop", seconds: 10)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(
                    segments: [(0, 1, "never landed")], partials: ["first words"], progressSeconds: [2], gate: gate
                )
                let model = makeModel("take-stop")
                let (held, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                model.beforeLandingSave = { for await _ in held { break } }
                recordAndStop(model, audio: audio, seconds: 10)
                let streaming = await waitUntil { model.takePartialText == "first words" && self.progress(model) != nil }
                #expect(streaming)
                let takeID = try #require(model.recording?.takeID)
                let run = try #require(model.takeRun)
                let late = model.makeTakeHandlers(run: run, takeID: takeID)
                let before = progress(model)

                model.stopTranscribingTake()

                #expect(ContentRoutes.stageTranscription(for: model) == nil, "the pane comes down at once")
                #expect(model.takePartialText.isEmpty)
                let unwound = await waitUntil { model.takeRun == nil }
                #expect(unwound)
                late.onPartial?("late words")
                late.onProgress?(9)
                late.onStage?(.preparingAudio)
                await settle()
                #expect(model.takePartialText.isEmpty, "a stopped run's late words land nowhere")
                #expect(model.takeTranscribeStage == nil)
                #expect(progress(model) == before, "a stopped run's late progress moves nothing")
                #expect(model.recording?.isTranscribing == true, "the take lands only when its save does")

                release.finish()
                let saved = try #require(await landedEntry(model))
                #expect(saved.title.hasSuffix("(not transcribed)"))
                let done = await waitUntil { model.recording?.state == .done(entryID: saved.id) }
                #expect(done)
                #expect(model.phase == .idle)
            }
        }

        @Test("a batch job that starts while a take transcribes on its Stage leaves the Stage on the take")
        func batchLeavesTheTakeOnTheStage() async throws {
            let audio = try makeTakeWAV("take-batch", seconds: 3)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "held")], gate: gate)
                let model = makeModel("take-batch")
                recordAndStop(model, audio: audio, seconds: 3)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                let job = BatchJob(url: URL(fileURLWithPath: "/tmp/TakeTranscriptionProgressTests/queued.m4a"))
                model.batchJobs = [job]

                await model.handleBatchEvent(.started(jobID: job.id))

                #expect(model.phase == .transcribing(file: job.url), "the batch's job has the phase")
                #expect(model.route == .recording)
                #expect(ContentRoutes.routeID(for: model) == .stage)
                #expect(ContentRoutes.stageTranscription(for: model)?.file == audio, "the Stage still shows the take")
                await gate.open()
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("new work stops a take's transcription, takes its pane down at once and keeps the take untranscribed")
        func newWorkTakesThePaneDown() async throws {
            let audio = try makeTakeWAV("take-new-work", seconds: 3)
            let file = try makeTakeWAV("take-new-work-file")
            defer {
                try? FileManager.default.removeItem(at: audio)
                try? FileManager.default.removeItem(at: file)
            }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "the file's words")], partials: ["the take's words"], gate: gate)
                let model = makeModel("take-new-work")
                recordAndStop(model, audio: audio, seconds: 3)
                let streaming = await waitUntil { model.takePartialText == "the take's words" }
                #expect(streaming)

                model.beginFileTranscription(fileURL: file, translateOverride: nil)

                #expect(ContentRoutes.stageTranscription(for: model) == nil, "the take's pane comes down at once")
                #expect(model.takePartialText.isEmpty)
                let kept = try #require(await landedEntry(model))
                #expect(kept.title.hasSuffix("(not transcribed)"))
                let notice = try #require(await waitForNotice(model))
                #expect(notice.message == "Saved the previous recording without transcribing it.")
                await gate.open()
                let landed = await waitUntil { model.transcript?.text == "the file's words" }
                #expect(landed)
            }
        }

        @Test("a Retry from the error card while a take transcribes stops that take's run as new work does")
        func retryStopsATranscribingTake() async throws {
            let audio = try makeTakeWAV("take-retry-over", seconds: 2)
            let earlier = try makeTakeWAV("take-retry-earlier")
            defer {
                try? FileManager.default.removeItem(at: audio)
                try? FileManager.default.removeItem(at: earlier)
            }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "the earlier take")], partials: ["the take's words"], gate: gate)
                let model = makeModel("take-retry-over")
                recordAndStop(model, audio: audio, seconds: 2)
                let streaming = await waitUntil { model.takePartialText == "the take's words" }
                #expect(streaming)
                model.failedTakeRetry = RecordingSession.Failure(
                    audioURL: earlier, save: nil, recovery: nil, title: "Earlier take", category: .transcription,
                    source: .microphone, annotations: AppModel.TakeAnnotations()
                )

                model.retryFailedTranscription()

                let replaced = await waitUntil { model.phase == .transcribing(file: earlier) }
                #expect(replaced)
                #expect(ContentRoutes.stageTranscription(for: model) == nil)
                let kept = try #require(await landedEntry(model))
                #expect(kept.title.hasSuffix("(not transcribed)"))
                let notice = try #require(await waitForNotice(model))
                #expect(notice.message == "Saved the previous recording without transcribing it.")
                await gate.open()
                let landed = await waitUntil { model.transcript?.text == "the earlier take" }
                #expect(landed)
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("the mic hotkey starts a take while one transcribes, whatever holds the phase")
        func hotkeyStartsATakeWhileOneTranscribes() async throws {
            let audio = try makeTakeWAV("take-hotkey", seconds: 2)
            let fixture = try makeTakeWAV("take-hotkey-mic")
            defer {
                try? FileManager.default.removeItem(at: audio)
                try? FileManager.default.removeItem(at: fixture)
            }
            try await withMocksCleared([.transcriber, .audioSource]) {
                await installMockTranscriber(segments: [(0, 1, "held")], gate: MockTranscriberGate())
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel("take-hotkey")
                recordAndStop(model, audio: audio, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                let first = model.recording?.takeID
                model.phase = .downloadingModel(name: Self.pinnedModel, progress: 0.3)

                model.toggleMicRecording()

                let started = await waitUntil { model.recording?.takeID != first && model.recording?.isCapturing == true }
                #expect(started)
                let kept = try #require(await landedEntry(model))
                #expect(kept.title.hasSuffix("(not transcribed)"))
                model.cancelCurrentWork()
            }
        }

        @Test("a model download waits while a take transcribes, as it waits for a file's run")
        func downloadsWaitForTheTakesRun() async throws {
            let audio = try makeTakeWAV("take-download", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "held")], gate: gate)
                let model = makeModel("take-download")
                recordAndStop(model, audio: audio, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                #expect(model.phase == .idle)

                #expect(model.downloadBlockedReason == "Wait for the current job to finish before downloading a model.")

                await gate.open()
                let landed = await waitUntil { model.takeTranscription == nil && self.isDone(model) }
                #expect(landed)
                #expect(model.downloadBlockedReason == nil)
            }
        }

        @Test("the Dock badge marks a take transcribing as it marks a file's run, and lets go once it lands")
        func dockBadgeMarksATakeTranscribing() async throws {
            #expect(DockBadge.badge(for: .idle, takeTranscribing: true, burnProgress: 0.4) == "•")
            #expect(DockBadge.badge(for: .ready, takeTranscribing: false, burnProgress: 0.4) == "40%")
            let audio = try makeTakeWAV("take-dock", seconds: 2)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "docked")], gate: gate)
                let model = makeModel("take-dock")
                let shown = ShownBadges()
                let badge = DockBadge { shown.labels.append($0) }
                badge.bind(model)

                recordAndStop(model, audio: audio, seconds: 2)

                let marked = await waitUntil { shown.labels.last == .some("•") }
                #expect(marked)
                await gate.open()
                let cleared = await waitUntil { self.isDone(model) && shown.labels.last == .some(nil) }
                #expect(cleared)
                withExtendedLifetime(badge) {}
            }
        }
    }
}
