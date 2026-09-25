import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Duplicate import", .serialized)
    struct DuplicateImportTests {

        private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
            AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults(),
                libraryURL: makeTempLibraryURL("duplicate"),
                features: features
            )
        }

        private func makeWAV(_ label: String, seconds: Double = 0.3) throws -> URL {
            let sampleRate = 16_000, channels = 1, bytesPerSample = 2
            let frames = Int(Double(sampleRate) * seconds)
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
                .appendingPathComponent("parola-duplicate-\(label)-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func waitUntil(timeoutMs: Int = 5_000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        @discardableResult
        private func seedLibrary(_ model: AppModel, with audio: URL, model name: String = "openai_whisper-tiny") async throws -> LibraryEntry {
            let transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "already here")],
                language: "en",
                modelName: name,
                durationSeconds: 61
            )
            return try await model.library.add(transcript: transcript, audioSource: audio, title: "Board meeting")
        }

        @Test("a second import of the same file opens the sheet instead of transcribing")
        func secondImportPrompts() async throws {
            let model = makeModel()
            let wav = try makeWAV("prompt")
            defer { try? FileManager.default.removeItem(at: wav) }
            let existing = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()

            let pending = try #require(model.duplicateImport)
            #expect(pending.entryID == existing.id)
            #expect(pending.entryTitle == "Board meeting")
            #expect(pending.modelName == "openai_whisper-tiny")
            #expect(pending.durationSeconds == 61)
            #expect(pending.fileURL == wav)
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("a file the library has never seen transcribes without a sheet")
        func firstImportRunsStraightThrough() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "fresh")], delayMs: 500
                ))
                let model = makeModel()
                let wav = try makeWAV("fresh")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()

                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask != nil)
                model.cancelCurrentWork()
            }
        }

        @Test("a copy under a different name still counts as the same recording")
        func renamedCopyPrompts() async throws {
            let model = makeModel()
            let wav = try makeWAV("original")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)

            let copy = wav.deletingLastPathComponent()
                .appendingPathComponent("renamed-\(UUID().uuidString).wav")
            try FileManager.default.copyItem(at: wav, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }

            model.transcribe(fileURL: copy)
            await model.awaitDuplicateCheck()

            #expect(model.duplicateImport?.fileURL == copy)
        }

        @Test("Open Existing selects the entry and leaves the file alone")
        func openExistingSelectsTheEntry() async throws {
            let model = makeModel()
            let wav = try makeWAV("open")
            defer { try? FileManager.default.removeItem(at: wav) }
            let existing = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()
            model.openExistingDuplicate(remembering: false)

            #expect(model.duplicateImport == nil)
            #expect(await waitUntil { model.selectedEntryID == existing.id })
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("Transcribe Again starts the run the sheet was holding")
        func transcribeAgainStartsTheRun() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "again")], delayMs: 500
                ))
                let model = makeModel()
                let wav = try makeWAV("again")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try await seedLibrary(model, with: wav)

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                model.transcribeDuplicateAgain(remembering: false)

                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask != nil)
                #expect(model.sourceFileURL == wav)
                model.cancelCurrentWork()
            }
        }

        @Test("dismissing the sheet transcribes nothing")
        func dismissLeavesTheFileAlone() async throws {
            let model = makeModel()
            let wav = try makeWAV("dismiss")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()
            model.dismissDuplicateImport()

            #expect(model.duplicateImport == nil)
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("a batch import skips the duplicates and counts them once")
        func batchImportSkipsDuplicates() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "queued")]
                ))
                let model = makeModel()
                let known = try makeWAV("known")
                let fresh = try makeWAV("unknown", seconds: 0.4)
                defer {
                    try? FileManager.default.removeItem(at: known)
                    try? FileManager.default.removeItem(at: fresh)
                }
                _ = try await seedLibrary(model, with: known)

                model.importBatchFiles([known, fresh])
                await model.awaitBatchImport()

                #expect(model.batchJobs.map(\.url) == [fresh])
                #expect(model.batchDuplicatesSkipped == 1)
                #expect(model.batchDuplicateNotice == "1 already in your library")
                model.clearBatch()
            }
        }

        @Test("only Transcribe it again keeps a known file in a batch", arguments: [
            (DuplicateImportPolicy.alwaysAsk, true),
            (DuplicateImportPolicy.openExisting, true),
            (DuplicateImportPolicy.transcribeAgain, false),
        ])
        func batchSkipDecision(policy: DuplicateImportPolicy, skips: Bool) {
            #expect(policy.batchSkipsDuplicates == skips)
        }

        @Test("with Transcribe it again a batch queues the files the library already has")
        func batchTranscribesDuplicatesAgain() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "again")]
                ))
                let model = makeModel()
                model.duplicateImportPolicy = .transcribeAgain
                let known = try makeWAV("batch-again-known")
                let fresh = try makeWAV("batch-again-fresh", seconds: 0.4)
                defer {
                    try? FileManager.default.removeItem(at: known)
                    try? FileManager.default.removeItem(at: fresh)
                }
                _ = try await seedLibrary(model, with: known)

                model.importBatchFiles([known, fresh])
                await model.awaitBatchImport()

                #expect(model.batchJobs.map(\.url) == [known, fresh])
                #expect(model.batchDuplicatesSkipped == 0)
                #expect(model.batchDuplicateNotice == nil)
                model.clearBatch()
            }
        }

        @Test("with Open the one I have a batch skips the known file and counts it")
        func batchSkipsDuplicatesUnderOpenExisting() async throws {
            let model = makeModel()
            model.duplicateImportPolicy = .openExisting
            let known = try makeWAV("batch-open-known")
            defer { try? FileManager.default.removeItem(at: known) }
            _ = try await seedLibrary(model, with: known)

            model.importBatchFiles([known])
            await model.awaitBatchImport()

            #expect(model.batchJobs.isEmpty)
            #expect(model.batchDuplicateNotice == "1 already in your library")
            #expect(model.duplicateImport == nil)
        }

        @Test("a watched-folder copy of a known file is skipped and counted, idle or busy, without a sheet",
              arguments: [DuplicateImportPolicy.alwaysAsk, DuplicateImportPolicy.openExisting], [false, true])
        func watchedDuplicateIsSkipped(policy: DuplicateImportPolicy, busy: Bool) async throws {
            let model = makeModel()
            model.duplicateImportPolicy = policy
            let wav = try makeWAV("watched-\(policy.rawValue)-\(busy)")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)
            let route = model.route
            let selection = model.selectedEntryID
            if busy { model.fileTranscribeTask = Task {} }

            model.handleWatchedArrival(wav)
            await model.awaitWatchedImport()

            #expect(model.duplicateImport == nil)
            #expect(model.selectedEntryID == selection)
            #expect(model.route == route)
            #expect(model.deferredArrivals.isEmpty)
            #expect(model.batchDuplicateNotice == "1 already in your library")
            if busy {
                model.fileTranscribeTask?.cancel()
                model.fileTranscribeTask = nil
            } else {
                #expect(model.fileTranscribeTask == nil)
            }
        }

        @Test("with Transcribe it again a watched-folder copy of a known file is transcribed")
        func watchedDuplicateTranscribesAgain() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "watched")], delayMs: 500
                ))
                let model = makeModel()
                model.duplicateImportPolicy = .transcribeAgain
                let wav = try makeWAV("watched-again")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try await seedLibrary(model, with: wav)

                model.handleWatchedArrival(wav)
                await model.awaitWatchedImport()

                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask != nil)
                #expect(model.sourceFileURL == wav)
                #expect(model.batchDuplicatesSkipped == 0)
                model.cancelCurrentWork()
            }
        }

        @Test("a watched-folder file the library has never seen starts its run")
        func watchedFreshFileRuns() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "fresh")], delayMs: 500
                ))
                let model = makeModel()
                let wav = try makeWAV("watched-fresh")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.handleWatchedArrival(wav)
                await model.awaitWatchedImport()

                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask != nil)
                #expect(model.batchDuplicatesSkipped == 0)
                model.cancelCurrentWork()
            }
        }

        @Test("a batch of nothing but duplicates shows the page and the count")
        func batchOfOnlyDuplicates() async throws {
            let model = makeModel()
            let first = try makeWAV("dup-one")
            let second = try makeWAV("dup-two", seconds: 0.5)
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            _ = try await seedLibrary(model, with: first)
            _ = try await seedLibrary(model, with: second)

            model.importBatchFiles([first, second])
            await model.awaitBatchImport()

            #expect(model.batchJobs.isEmpty)
            #expect(model.batchDuplicateNotice == "2 already in your library")
            #expect(model.route == .batch)
        }

        @Test("a duplicate deferred during a run is still filtered when the queue drains")
        func deferredArrivalsAreFiltered() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "drained")]
                ))
                let model = makeModel()
                let known = try makeWAV("deferred-known")
                let fresh = try makeWAV("deferred-fresh", seconds: 0.4)
                defer {
                    try? FileManager.default.removeItem(at: known)
                    try? FileManager.default.removeItem(at: fresh)
                }
                _ = try await seedLibrary(model, with: known)

                model.fileTranscribeTask = Task {}
                model.transcribeNow(urls: [known, fresh])
                #expect(model.deferredArrivals == [known, fresh])

                model.fileTranscribeTask?.cancel()
                model.fileTranscribeTask = nil
                model.drainDeferredArrivals()
                await model.awaitBatchImport()

                #expect(model.batchJobs.map(\.url) == [fresh])
                #expect(model.batchDuplicateNotice == "1 already in your library")
                model.clearBatch()
            }
        }

        @Test("a deleted entry stops holding up its file")
        func deletedEntryDoesNotPrompt() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "back")], delayMs: 500
                ))
                let model = makeModel()
                let wav = try makeWAV("deleted")
                defer { try? FileManager.default.removeItem(at: wav) }
                let existing = try await seedLibrary(model, with: wav)
                try await model.library.delete(existing.id)

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()

                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask != nil)
                model.cancelCurrentWork()
            }
        }

        @Test("the app test host is recognised as a test process too")
        func testProcessIsDetected() {
            #expect(LibraryStore.isTestProcess)
        }

        @Test("the batch notice stays quiet when nothing was skipped")
        func noticeIsQuietWithoutDuplicates() {
            let model = makeModel()
            #expect(model.batchDuplicateNotice == nil)
            model.batchDuplicatesSkipped = 3
            #expect(model.batchDuplicateNotice == "3 already in your library")
        }
    }
}
