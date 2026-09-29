import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Retranscribe in place", .serialized)
    struct RetranscribeInPlaceTests {

        /// The engine the re-run must reach. The mock is installed for this engine alone, so a run
        /// that ignored the chosen model would look for a real engine and find no mock. Apple Speech
        /// also reads as installed everywhere, so nothing downloads.
        private static let appleSpeech = "apple-speech-analyzer"

        @MainActor
        private final class SoundCounter {
            var plays = 0
        }

        private func makeModel(_ label: String) -> AppModel {
            let model = AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults(),
                libraryURL: makeTempLibraryURL(label),
                features: Set(ParolaFeature.allCases)
            )
            // Without it the card-metadata call reaches the shared mock LLM store outside any lease,
            // and the "the re-run cleared aiTitle" assertions would only hold while the fixture text
            // stays under CardMetadataService.minimumCharacters.
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func makeWAV(_ label: String) throws -> URL {
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
                .appendingPathComponent("parola-retranscribe-\(label)-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        /// A library entry with audio, a title, a label, a favorite, a note, a translation and a
        /// speaker map — everything a re-run has to keep or drop.
        @discardableResult
        private func seed(_ model: AppModel, audio: URL, personID: UUID = UUID()) async throws -> LibraryEntry {
            var transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the old take", speaker: "Speaker 1")],
                language: "en",
                modelName: "openai_whisper-tiny"
            )
            transcript.translation = TranscriptTranslation(
                targetLanguage: "it", segments: [0: "la vecchia presa"], createdAt: Date(), provider: "mock"
            )
            transcript.summary = Summary(text: "old recap")
            let entry = try await model.library.add(
                transcript: transcript, audioSource: audio, category: .transcription, title: "Board meeting"
            )
            try await model.library.setLabels(["keep me"], for: entry.id)
            try await model.library.setSegmentFavorite(true, segmentID: 0, for: entry.id)
            try await model.library.setSegmentNote("old note", segmentID: 0, for: entry.id)
            try await model.library.setSpeakerAssignments(["Speaker 1": personID], for: entry.id)
            try await model.library.setCardMetadata(aiTitle: "Old AI title", shortSummary: "Old summary", for: entry.id)
            model.refreshLibrary()
            _ = await waitUntil(timeoutMs: 10_000) { model.libraryEntry(id: entry.id) != nil }
            return entry
        }

        /// True once the run has reached the engine — the point past which the file is open and
        /// the only thing left is the gate.
        private func waitForEngine(_ model: AppModel) async -> Bool {
            await waitUntil(timeoutMs: 10_000) {
                if case .transcribing = model.phase { return true }
                return false
            }
        }

        private func load(_ model: AppModel, _ entryID: LibraryEntry.ID) async -> Bool {
            model.loadEntry(entryID)
            return await waitUntil(timeoutMs: 10_000) { model.selectedEntryID == entryID && model.transcript != nil }
        }

        @Test("the run carries the chosen model and language and keeps the entry it was asked about")
        func requestCarriesTheChoice() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")],
                    language: "it", gate: gate
                ))
                let model = makeModel("retranscribe-request")
                let wav = try makeWAV("request")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")

                let request = try #require(model.retranscribeRequest)
                #expect(request.entryID == entry.id)
                #expect(request.modelName == Self.appleSpeech)
                #expect(request.language == "it")

                await gate.open()
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { model.transcript?.segments.first?.text == "the new take" })
            }
        }

        @Test("a re-run of a link's entry keeps the page it came from")
        func webEntryKeepsItsPage() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")]
                ))
                let model = makeModel("retranscribe-web")
                let wav = try makeWAV("web")
                defer { try? FileManager.default.removeItem(at: wav) }
                let page = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
                let entry = try await model.library.add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the old take")],
                        language: "en", modelName: "openai_whisper-tiny", sourceURL: page
                    ),
                    audioSource: wav, title: "A talk", source: .web
                )
                model.refreshLibrary()
                _ = await waitUntil(timeoutMs: 10_000) { model.libraryEntry(id: entry.id) != nil }
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "en")

                #expect(await waitUntil(timeoutMs: 10_000) { model.transcript?.segments.first?.text == "the new take" })
                #expect(model.transcript?.sourceURL == page)
                let stored = try await model.library.load(entry.id).document.transcript
                #expect(stored.segments.first?.text == "the new take")
                #expect(stored.sourceURL == page)
            }
        }

        @Test("the entry keeps its id, title and labels and loses what the old take derived")
        func entryIsReplacedInPlace() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")],
                    language: "it", modelName: Self.appleSpeech
                ))
                let model = makeModel("retranscribe-inplace")
                let wav = try makeWAV("inplace")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { model.libraryEntry(id: entry.id)?.aiTitle == nil })

                let reloaded = try #require(model.libraryEntry(id: entry.id))
                #expect(model.libraryEntries.count == 1)
                #expect(reloaded.id == entry.id)
                #expect(reloaded.title == "Board meeting")
                #expect(reloaded.labels == ["keep me"])
                #expect(reloaded.category == .transcription)
                #expect(reloaded.createdAt == entry.createdAt)
                #expect(reloaded.modelName == Self.appleSpeech)
                #expect(reloaded.language == "it")
                #expect(reloaded.favoriteSegments.isEmpty)
                #expect(reloaded.segmentNotes.isEmpty)
                #expect(reloaded.speakerAssignments.isEmpty)
                #expect(reloaded.shortSummary == nil)

                let stored = try await model.library.load(entry.id).document.transcript
                #expect(stored.segments.map(\.text) == ["the new take"])
                #expect(stored.translation == nil)
                #expect(stored.summary == nil)
            }
        }

        @Test("a summary of the old text still running when the re-run lands is dropped, on screen and on disk")
        func rerunDropsTheOldTextsSummary() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")]
                ))
                let model = makeModel("retranscribe-summary")
                let wav = try makeWAV("summary")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))
                let (release, releaser) = AsyncStream<Void>.makeStream()
                model.summariseOperation = { _, _ in
                    for await _ in release { break }
                    return Summary(text: "recap of the old take")
                }
                model.summariseTranscript()
                #expect(model.isSummarising)

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")
                #expect(await waitUntil(timeoutMs: 10_000) { model.transcript?.segments.first?.text == "the new take" })
                #expect(!model.isSummarising)
                releaser.finish()
                await settle()

                #expect(model.transcript?.summary == nil)
                #expect(try await model.library.load(entry.id).document.transcript.summary == nil)
            }
        }

        @Test("a finished re-run plays the completion sound once")
        func rerunPlaysTheSound() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")]
                ))
                let model = makeModel("retranscribe-sound")
                let counter = SoundCounter()
                model.completionSoundPlayer = { counter.plays += 1 }
                model.playSoundWhenFinished = true
                let wav = try makeWAV("sound")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))
                #expect(counter.plays == 0)

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: nil)

                #expect(await waitUntil(timeoutMs: 10_000) { counter.plays == 1 })
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(counter.plays == 1)
            }
        }

        @Test("a re-run lets go of the slot without waiting for the cards queued ahead of it")
        func rerunDoesNotWaitForTheCardQueue() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")]
                ))
                let model = makeModel("retranscribe-card-queue")
                let wav = try makeWAV("card-queue")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))
                let (release, releaser) = AsyncStream<Void>.makeStream()
                model.cardMetadataTimeout = .seconds(60)
                model.cardMetadataOperation = { _ in
                    for await _ in release { break }
                    return CardMetadata(title: "Held", summary: "Released.")
                }
                model.enqueueCardMetadata(for: entry.id, transcript: model.transcript!)

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: nil)

                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(model.fileTranscribeTask == nil)
                #expect(model.cardJobsPending == 2)
                releaser.finish()
                await model.awaitCardMetadataQueue()
            }
        }

        @Test("a cancel that lands in post-processing still leaves the old take alone")
        func cancelDuringPostProcessingKeepsTheOldTake() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")]
                ))
                let model = makeModel("retranscribe-cancel-postprocess")
                let wav = try makeWAV("cancel-postprocess")
                defer { try? FileManager.default.removeItem(at: wav) }
                let personID = UUID()
                let entry = try await seed(model, audio: wav, personID: personID)
                #expect(await load(model, entry.id))

                // The engine is done and the file is closed; this is the only suspension left
                // before the write that replaces the old take.
                model.postProcessOperation = { [weak model] transcript in
                    await MainActor.run { model?.cancelCurrentWork() }
                    return transcript
                }

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { model.fileTranscribeTask == nil })

                let stored = try await model.library.load(entry.id)
                #expect(stored.document.transcript.segments.map(\.text) == ["the old take"])
                #expect(stored.document.transcript.summary?.text == "old recap")
                #expect(stored.entry.favoriteSegments == [0])
                #expect(stored.entry.segmentNotes == ["0": "old note"])
                #expect(stored.entry.speakerAssignments == ["Speaker 1": personID])
                #expect(stored.entry.aiTitle == "Old AI title")
                // Without the check the write is skipped inside replaceEntry and the phase is left
                // reading "transcribing" for a run that is over.
                #expect(model.phase == .idle)
            }
        }

        @Test("an engine failure leaves the old take and everything hanging off it alone")
        func engineFailureKeepsTheOldTake() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the engine went down")
                ))
                let model = makeModel("retranscribe-enginefail")
                let wav = try makeWAV("enginefail")
                defer { try? FileManager.default.removeItem(at: wav) }
                let personID = UUID()
                let entry = try await seed(model, audio: wav, personID: personID)
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { model.fileTranscribeTask == nil })

                let stored = try await model.library.load(entry.id)
                #expect(stored.document.transcript.segments.map(\.text) == ["the old take"])
                #expect(stored.document.transcript.summary?.text == "old recap")
                #expect(stored.document.transcript.translation?.targetLanguage == "it")
                #expect(stored.entry.favoriteSegments == [0])
                #expect(stored.entry.segmentNotes == ["0": "old note"])
                #expect(stored.entry.speakerAssignments == ["Speaker 1": personID])
                #expect(stored.entry.aiTitle == "Old AI title")
                #expect(stored.entry.modelName == "openai_whisper-tiny")
                #expect(model.transcript?.segments.first?.text == "the old take")
                if case .failed(let message) = model.phase {
                    #expect(message.contains("the engine went down"))
                } else {
                    Issue.record("expected the failure to reach the phase, got \(model.phase)")
                }
            }
        }

        @Test("a cancelled re-run leaves every last thing about the old take alone")
        func cancelledRunKeepsTheOldTake() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")], gate: gate
                ))
                let model = makeModel("retranscribe-cancelled")
                let wav = try makeWAV("cancelled")
                defer { try? FileManager.default.removeItem(at: wav) }
                let personID = UUID()
                let entry = try await seed(model, audio: wav, personID: personID)
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")
                #expect(model.retranscribeRequest != nil)
                #expect(await waitForEngine(model))

                model.cancelCurrentWork()
                await gate.open()
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { model.fileTranscribeTask == nil })

                let stored = try await model.library.load(entry.id)
                #expect(stored.document.transcript.segments.map(\.text) == ["the old take"])
                #expect(stored.document.transcript.translation?.targetLanguage == "it")
                #expect(stored.entry.favoriteSegments == [0])
                #expect(stored.entry.segmentNotes == ["0": "old note"])
                #expect(stored.entry.speakerAssignments == ["Speaker 1": personID])
                #expect(stored.entry.aiTitle == "Old AI title")
                #expect(stored.entry.modelName == "openai_whisper-tiny")
                #expect(model.phase == .idle)
                #expect(model.canCancel == false)
            }
        }

        @Test("a re-run whose entry went away leaves a warning and an idle app, not a stuck bar")
        func saveFailureUnsticksThePhase() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")], gate: gate
                ))
                let model = makeModel("retranscribe-savefail")
                let wav = try makeWAV("savefail")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: nil)
                #expect(model.retranscribeRequest != nil)
                #expect(await waitForEngine(model))

                // The bundle goes while the run is held; the write lands on nothing.
                try FileManager.default.removeItem(at: entry.bundleURL)
                await gate.open()

                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
                #expect(await waitUntil(timeoutMs: 10_000) { model.nonFatalWarning != nil })
                #expect(model.phase == .idle)
                #expect(model.canCancel == false)
                #expect(model.fileTranscribeTask == nil)
            }
        }

        @Test("an entry that came in without audio is refused")
        func subtitleOnlyEntryIsRefused() async throws {
            let model = makeModel("retranscribe-noaudio")
            let transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "imported")],
                language: "en",
                modelName: "youtube-subs"
            )
            let entry = try await model.library.add(transcript: transcript, audioSource: nil, title: "Captions")
            model.refreshLibrary()
            #expect(await load(model, entry.id))

            #expect(model.canRetranscribeSelectedEntry == false)
            #expect(model.retranscribeUnavailableReason != nil)

            model.retranscribeCurrentEntry(model: Self.appleSpeech, language: nil)

            #expect(model.retranscribeRequest == nil)
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("a second request while one is running is ignored")
        func oneRunAtATime() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")], gate: gate
                ))
                let model = makeModel("retranscribe-single")
                let wav = try makeWAV("single")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)
                #expect(await load(model, entry.id))

                model.retranscribeCurrentEntry(model: Self.appleSpeech, language: "it")
                model.retranscribeCurrentEntry(model: "openai_whisper-tiny", language: "fr")

                #expect(model.retranscribeRequest?.modelName == Self.appleSpeech)
                #expect(model.retranscribeRequest?.language == "it")

                await gate.open()
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
            }
        }

        @Test("the bridge opens the entry and runs it through the same entry point")
        func bridgeRunsThroughTheModel() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the new take")], gate: gate
                ))
                let model = makeModel("retranscribe-bridge")
                let wav = try makeWAV("bridge")
                defer { try? FileManager.default.removeItem(at: wav) }
                let entry = try await seed(model, audio: wav)

                let server = try ParolaAutomationServer(model: model)
                let context = AutomationContext(model: model, server: server)
                let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
                let command = try #require(commands["retranscribeEntry"])
                let args = try command.validate(AutomationArgs([
                    "entryID": .string(entry.id),
                    "model": .string(Self.appleSpeech),
                    "language": .string(""),
                ]))

                let reply = try await command.handler(args, context)
                withExtendedLifetime(server) {}

                guard case .object(let fields) = reply else {
                    Issue.record("retranscribeEntry returned no object")
                    await gate.open()
                    return
                }
                #expect(fields["entryID"] == .string(entry.id))
                #expect(fields["model"] == .string(Self.appleSpeech))
                #expect(fields["language"] == .null)
                #expect(model.selectedEntryID == entry.id)

                await gate.open()
                #expect(await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil })
            }
        }
    }
}
