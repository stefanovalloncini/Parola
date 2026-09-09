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
            await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "fresh")], delayMs: 500
            ))
            defer { Task { await MockTranscriberRegistry.shared.clear() } }
            let model = makeModel()
            let wav = try makeWAV("fresh")
            defer { try? FileManager.default.removeItem(at: wav) }

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()

            #expect(model.duplicateImport == nil)
            #expect(model.fileTranscribeTask != nil)
            model.cancelCurrentWork()
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
            model.openExistingDuplicate()

            #expect(model.duplicateImport == nil)
            #expect(await waitUntil { model.selectedEntryID == existing.id })
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("Transcribe Again starts the run the sheet was holding")
        func transcribeAgainStartsTheRun() async throws {
            await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "again")], delayMs: 500
            ))
            defer { Task { await MockTranscriberRegistry.shared.clear() } }
            let model = makeModel()
            let wav = try makeWAV("again")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()
            model.transcribeDuplicateAgain()

            #expect(model.duplicateImport == nil)
            #expect(model.fileTranscribeTask != nil)
            #expect(model.sourceFileURL == wav)
            model.cancelCurrentWork()
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

        @Test("a deleted entry stops holding up its file")
        func deletedEntryDoesNotPrompt() async throws {
            await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "back")], delayMs: 500
            ))
            defer { Task { await MockTranscriberRegistry.shared.clear() } }
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

        @Test("the batch notice stays quiet when nothing was skipped")
        func noticeIsQuietWithoutDuplicates() {
            let model = makeModel()
            #expect(model.batchDuplicateNotice == nil)
            model.batchDuplicatesSkipped = 3
            #expect(model.batchDuplicateNotice == "3 already in your library")
        }
    }
}
