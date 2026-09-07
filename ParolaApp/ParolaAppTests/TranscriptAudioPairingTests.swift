import Foundation
import Testing
import AVFoundation
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func makeSilentWAV(label: String) throws -> URL {
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
        .appendingPathComponent("parola-pairing-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Transcript audio pairing", .serialized)
    struct TranscriptAudioPairingTests {

        private func makeModel() -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("pairing"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock()
            )
            return AppModel(bootstrap: bootstrap)
        }

        private func clearMocks() async {
            await MockTranscriberRegistry.shared.clear()
            await MockAudioSourceRegistry.shared.clear()
            MockMediaFetcherRegistry.shared.clear()
        }

        /// Awaited teardown on every exit: a fire-and-forget clear can land after the next test installed its mock.
        private func withMocksCleared(_ body: @MainActor () async throws -> Void) async throws {
            do {
                try await body()
            } catch {
                await clearMocks()
                throw error
            }
            await clearMocks()
        }

        private func waitUntil(timeoutMs: Int = 15_000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        private func playerURL(_ model: AppModel) -> URL? {
            (model.player?.currentItem?.asset as? AVURLAsset)?.url
        }

        private func heldMock(_ gate: MockTranscriberGate) -> MockTranscriberResponse {
            MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")],
                gate: gate
            )
        }

        /// Opens a library entry with its own audio while the run under test is still transcribing.
        private func openOtherEntry(in model: AppModel) async throws -> URL {
            let audio = try makeSilentWAV(label: "entry")
            let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
            let entry = try await seed.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                    language: "en",
                    modelName: "stub"
                ),
                audioSource: audio,
                category: .transcription
            )
            model.loadEntry(entry.id)
            let opened = await waitUntil { model.selectedEntryID == entry.id && model.player != nil }
            #expect(opened, "the entry should be open before the transcription lands")
            return try #require(model.sourceFileURL)
        }

        @Test("a file transcription that lands after the user opened an entry keeps its own audio")
        func fileTranscribePairsWithItsSource() async throws {
            try await withMocksCleared {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                let wav = try makeSilentWAV(label: "file")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                let entryAudio = try await openOtherEntry(in: model)
                #expect(model.sourceFileURL == entryAudio)
                try #require(model.transcript?.text.contains("own words") != true, "the run must still be in flight")

                await gate.open()
                let finished = await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
                #expect(finished)
                #expect(model.sourceFileURL == wav)
                #expect(playerURL(model) == wav, "the transcript would play the entry's audio instead of the file it describes")
            }
        }

        @Test("a recording's transcript lands with the recording's audio, not the entry opened meanwhile")
        func recordingPairsWithItsSource() async throws {
            try await withMocksCleared {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                let fixture = try makeSilentWAV(label: "take")
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                model.recordingCountInSeconds = 0

                model.startRecording(source: .microphone)
                let recording = await waitUntil {
                    if case .recording = model.phase { return true }
                    return false
                }
                #expect(recording)

                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.sourceFileURL == fixture }
                #expect(transcribing)

                let entryAudio = try await openOtherEntry(in: model)
                #expect(model.sourceFileURL == entryAudio)
                try #require(model.transcript?.text.contains("own words") != true, "the take must still be transcribing")

                await gate.open()
                let finished = await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
                #expect(finished)
                #expect(model.sourceFileURL == fixture)
                #expect(playerURL(model) == fixture, "the take's transcript would play the entry's audio")
            }
        }

        @Test("a YouTube transcription that lands after a navigation keeps its own audio")
        func youtubePairsWithItsSource() async throws {
            try await withMocksCleared {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                let fixture = try makeSilentWAV(label: "youtube")
                MockMediaFetcherRegistry.shared.install(fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                model.transcribeYouTube(urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
                let fetched = await waitUntil { model.sourceFileURL == fixture }
                #expect(fetched)

                let entryAudio = try await openOtherEntry(in: model)
                #expect(model.sourceFileURL == entryAudio)
                try #require(model.transcript?.text.contains("own words") != true, "the fetch's run must still be in flight")

                await gate.open()
                let finished = await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
                #expect(finished)
                #expect(model.sourceFileURL == fixture)
                #expect(playerURL(model) == fixture, "the fetched audio would be replaced by the entry's")
            }
        }
    }
}
