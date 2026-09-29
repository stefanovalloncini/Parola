import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private struct StubLiveSource: LiveAudioSource {
    let url: URL
    func start() async throws {}
    func prepare() async throws -> URL { url }
    func cancel() async {}
}

private func makeTakeWAV(label: String) throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * 0.3)
    let dataBytes = frames * channels * bytesPerSample
    var data = Data()
    func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
    ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
    le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
    le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
    ascii("data"); le32(UInt32(dataBytes))
    data.append(Data(count: dataBytes))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-take-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording safety", .serialized)
    struct RecordingSafetyTests {

        private func makeModel(libraryURL: URL = makeTempLibraryURL("recording-safety")) -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: libraryURL,
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock()
            )
            return AppModel(bootstrap: bootstrap)
        }

        private func waitUntil(timeoutMs: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        private func entries(_ model: AppModel, count: Int, timeoutMs: Int = 5000) async -> [LibraryEntry] {
            var listed: [LibraryEntry] = []
            var elapsed = 0
            while elapsed < timeoutMs {
                listed = await model.library.list()
                if listed.count >= count { return listed }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return listed
        }

        @Test("a failed take is saved to the library, and Retry transcribes that entry instead of adding another")
        func failedTakeSavesAudioAndRetryWorks() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeModel()
                let wav = try makeTakeWAV(label: "failed")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.liveSource = StubLiveSource(url: wav)
                model.stopRecordingAndTranscribe()

                let failed = await waitUntil {
                    if case .failed(let message) = model.phase { return message.contains("saved to your library") }
                    return false
                }
                #expect(failed)
                #expect(model.failedTakeAudioURL == wav)

                let saved = await entries(model, count: 1)
                #expect(saved.count == 1)
                #expect(saved.first?.title.hasSuffix("(transcription failed)") == true)
                #expect(saved.first?.manifest.originalAudioName.isEmpty == false)

                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "recovered text")]
                ))
                await model.unloadTranscriptionSession()

                model.retryFailedTake()

                let ready = await waitUntil { model.phase == .ready && model.transcript?.text == "recovered text" }
                #expect(ready)
                #expect(model.failedTakeAudioURL == nil)
                #expect(model.selectedEntryID == saved.first?.id, "Retry opens the take's entry")
                let after = await model.library.list()
                #expect(after.count == 1, "the entry is filled in, not joined by a twin")
                #expect(after.first?.title.hasSuffix("(transcription failed)") == false)
            }
        }

        @Test("a streaming failure persists the confirmed segments as an interrupted take")
        func streamingFailurePersistsInterruptedTake() async {
            let model = makeModel()
            model.liveSegments = [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "kept before the crash"),
            ]

            await model.handleStreamingEvent(.failed("stream boom"))

            let failed: Bool
            if case .failed(let message) = model.phase {
                failed = message.contains("saved to your library")
            } else {
                failed = false
            }
            #expect(failed)
            #expect(model.liveSegments.isEmpty)
            let saved = await entries(model, count: 1)
            #expect(saved.count == 1)
            #expect(saved.first?.title.hasSuffix("(interrupted)") == true)
        }

        @Test("a take stopped before capture came up saves nothing and says so")
        func emptyTakeWithoutAudioIsNotSaved() async {
            let model = makeModel()
            model.phase = .recording(source: .microphone)

            await model.handleStreamingEvent(.finished(Transcript(
                segments: [], language: "en", modelName: "openai_whisper-tiny"
            )))

            #expect(model.phase == .failed(message: AppModel.nothingRecordedMessage()))
            #expect(model.transcript == nil)
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await model.library.list().isEmpty)
        }

        @Test("a short take with audio but no words is still saved")
        func silentTakeWithAudioIsSaved() async throws {
            let model = makeModel()
            let wav = try makeTakeWAV(label: "silent-take")
            defer { try? FileManager.default.removeItem(at: wav) }

            await model.handleStreamingEvent(.finished(Transcript(
                segments: [], language: "en", modelName: "openai_whisper-tiny", sourceURL: wav
            )))

            #expect(model.phase == .ready)
            let saved = await entries(model, count: 1)
            #expect(saved.count == 1)
        }

        @Test("an interrupted take is saved finished and post-processed, like a stopped one")
        func interruptedTakeIsFinished() async throws {
            let model = makeModel()
            model.findReplaceRules = [FindReplaceRule(find: "magazzino", replace: "deposito")]
            model.liveSegments = [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "Non so perchè il magazzino"),
                TranscriptSegment(id: 1, start: 2.2, end: 4, text: "è rimasto vuoto."),
                TranscriptSegment(id: 2, start: 5, end: 7, text: "Sottotitoli creati dalla comunità Amara.org"),
            ]

            await model.handleStreamingEvent(.failed("stream boom"))

            let saved = await entries(model, count: 1)
            let entry = try #require(saved.first)
            let stored = try await model.library.load(entry.id).document.transcript
            #expect(stored.segments.map(\.text) == ["Non so perché il deposito è rimasto vuoto."])
            #expect(stored.language == "it")
        }

        @Test("recording checkpoints carry the in-flight audio URL even without segments")
        func recordingCheckpointCarriesAudioURL() async throws {
            let model = makeModel()
            let audio = URL(fileURLWithPath: "/tmp/parola-inflight-test.wav")
            model.beginRecordingRecovery()
            model.liveRecordingAudioURL = audio
            model.liveSegments = []

            model.writeRecordingCheckpoint()

            await model.pendingRecoveryWrite?.value
            let data = try Data(contentsOf: try #require(model.activeRecoveryFileURL))
            let checkpoint = try JSONDecoder().decode(RecoveryCheckpoint.self, from: data)
            #expect(checkpoint.kind == .recording)
            #expect(checkpoint.audioURL == audio)
            #expect(checkpoint.segments.isEmpty)
            model.endActiveRecovery()
        }

        @Test("accepting a recording recovery attaches the audio when the file still opens")
        func acceptAttachesRecoveredAudio() async throws {
            let lib = makeTempLibraryURL("recovery-audio")
            let wav = try makeTakeWAV(label: "recovered")
            defer { try? FileManager.default.removeItem(at: wav) }
            let checkpoint = RecoveryCheckpoint(
                kind: .recording,
                startedAt: Date(),
                modelName: "m",
                language: "en",
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "salvato")],
                audioURL: wav
            )
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try JSONEncoder().encode(checkpoint).write(to: lib.appendingPathComponent("recovery.json"))
            let model = makeModel(libraryURL: lib)
            #expect(model.pendingRecovery != nil)

            model.acceptPendingRecovery()

            let restored = await waitUntil { model.transcript?.segments.first?.text == "salvato" && model.sourceFileURL != nil }
            #expect(restored)
            let saved = await entries(model, count: 1)
            #expect(saved.first?.manifest.originalAudioName.isEmpty == false)
            // Playback follows the take into its entry once the library holds the audio.
            let followed = await waitUntil {
                model.sourceFileURL?.deletingLastPathComponent().lastPathComponent == saved.first?.bundleURL.lastPathComponent
            }
            #expect(followed)
        }

        @Test("accepting a take's transcription recovery keeps its title")
        func acceptResumesTakeWithTitle() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ripresa")]
                ))
                let lib = makeTempLibraryURL("recovery-take-title")
                let wav = try makeTakeWAV(label: "take-title")
                defer { try? FileManager.default.removeItem(at: wav) }
                let checkpoint = RecoveryCheckpoint(
                    kind: .fileTranscription,
                    startedAt: Date(),
                    modelName: "m",
                    sourceURL: wav,
                    title: "Meeting 21 Aug 2026"
                )
                try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
                try JSONEncoder().encode(checkpoint).write(to: lib.appendingPathComponent("recovery.json"))
                let model = makeModel(libraryURL: lib)

                model.acceptPendingRecovery()

                let ready = await waitUntil { model.phase == .ready }
                #expect(ready)
                let saved = await entries(model, count: 1)
                #expect(saved.first?.title == "Meeting 21 Aug 2026")
            }
        }

        @Test("a stale .finished after a streaming failure cannot resurrect the take")
        func staleFinishedAfterFailureStaysDead() async {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                failure: MockTranscriberFailure(code: .transcriptionFailed, message: "instant boom")
            ))
            defer { MockStreamingTranscriberRegistry.shared.clear() }
            let model = makeModel()
            model.useStreaming = true

            model.startRecording(source: .microphone)

            let failed = await waitUntil {
                if case .failed = model.phase { return true }
                return false
            }
            #expect(failed)
            // The mock's stop() yields .finished after the failure; give it time to land wrongly.
            try? await Task.sleep(for: .milliseconds(300))
            let stillFailed: Bool
            if case .failed = model.phase { stillFailed = true } else { stillFailed = false }
            #expect(stillFailed)
            #expect(model.transcript == nil)
            let saved = await model.library.list()
            #expect(saved.isEmpty)
        }

        @Test("stale unreferenced inflight files are selected for deletion")
        func staleInflightSelection() {
            let now = Date()
            let old = now.addingTimeInterval(-3 * 24 * 3600)
            let stale = URL(fileURLWithPath: "/tmp/inflight/stale.wav")
            let referenced = URL(fileURLWithPath: "/tmp/inflight/referenced.wav")
            let young = URL(fileURLWithPath: "/tmp/inflight/young.wav")
            let picked = AppModel.staleInflightFiles(
                in: [(stale, old), (referenced, old), (young, now)],
                keeping: [referenced.resolvingSymlinksInPath().path],
                now: now
            )
            #expect(picked == [stale])
        }

        @Test("launch sweeps stale orphans out of the inflight directory")
        func sweepRemovesStaleOrphans() async throws {
            let lib = makeTempLibraryURL("sweep")
            let inflight = lib.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let stale = inflight.appendingPathComponent("stale.wav")
            let fresh = inflight.appendingPathComponent("fresh.wav")
            try Data([0x01]).write(to: stale)
            try Data([0x01]).write(to: fresh)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)],
                ofItemAtPath: stale.path
            )

            _ = makeModel(libraryURL: lib)

            let swept = await waitUntil { !FileManager.default.fileExists(atPath: stale.path) }
            #expect(swept)
            #expect(FileManager.default.fileExists(atPath: fresh.path))
        }
    }
}
