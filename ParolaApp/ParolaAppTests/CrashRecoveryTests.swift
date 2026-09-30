import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A clock whose `sleep` returns at once, so the recording watch ticks without the real 30s wait.
private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

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
        .appendingPathComponent("parola-recovery-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Crash recovery", .serialized)
    struct CrashRecoveryTests {

        private func makeModel(
            clock: any Clock<Duration> = ContinuousClock(),
            libraryURL: URL = makeTempLibraryURL("recovery")
        ) -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: libraryURL,
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: clock
            )
            return AppModel(bootstrap: bootstrap)
        }

        private static func makeSegments() -> [TranscriptSegment] {
            [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "ciao a tutti", words: [
                    WordTiming(id: "0-0", word: "ciao", start: 0, end: 0.5, probability: 1),
                ]),
                TranscriptSegment(id: 1, start: 2, end: 4, text: "secondo segmento"),
            ]
        }

        private func flushRecoveryWrites(_ model: AppModel) async {
            await model.awaitDuplicateCheck()
            await model.pendingRecoveryWrite?.value
        }

        private func decodeRecoveryFile(_ model: AppModel) async throws -> RecoveryCheckpoint {
            await flushRecoveryWrites(model)
            let data = try Data(contentsOf: try #require(model.activeRecoveryFileURL))
            return try JSONDecoder().decode(RecoveryCheckpoint.self, from: data)
        }

        private func writeCheckpoint(_ checkpoint: RecoveryCheckpoint, libraryURL: URL) throws {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: libraryURL.appendingPathComponent("recovery.json"))
        }

        private func recoveryFileExists(_ model: AppModel) -> Bool {
            !model.recoveryCheckpointFiles.isEmpty
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

        // MARK: - File transcription lifecycle

        @Test("transcribe(fileURL:) writes the recovery file at start and deletes it on success")
        func fileTranscribeWritesAndClearsOnSuccess() async throws {
            try await withMocksCleared(.transcriber) {
                // The delay keeps completion from deleting the checkpoint before it's asserted on.
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello")],
                    delayMs: 500
                ))
                let model = makeModel()
                let wav = try makeSilentWAV(label: "success")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)

                let checkpoint = try await decodeRecoveryFile(model)
                #expect(checkpoint.kind == .fileTranscription)
                #expect(checkpoint.sourceURL == wav)
                #expect(checkpoint.modelName == model.selectedModel)

                let finished = await waitUntil { model.phase == .ready }
                #expect(finished)
                #expect(!recoveryFileExists(model))
            }
        }

        @Test("a failed transcription deletes the recovery file")
        func fileTranscribeClearsOnFailure() async throws {
            try await withMocksCleared(.transcriber) {
                // The delay keeps the failure from landing before the checkpoint write we assert on.
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    delayMs: 500,
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
                ))
                let model = makeModel()
                let wav = try makeSilentWAV(label: "failure")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await flushRecoveryWrites(model)
                #expect(recoveryFileExists(model))

                let failed = await waitUntil {
                    if case .failed = model.phase { return true }
                    return false
                }
                #expect(failed)
                #expect(!recoveryFileExists(model))
            }
        }

        @Test("cancelling a transcription deletes the recovery file")
        func fileTranscribeClearsOnCancel() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "slow")],
                    delayMs: 5000
                ))
                let model = makeModel()
                let wav = try makeSilentWAV(label: "cancel")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await flushRecoveryWrites(model)
                #expect(recoveryFileExists(model))

                model.cancelCurrentWork()
                #expect(!recoveryFileExists(model))
                #expect(model.phase == .idle)
            }
        }

        @Test("a superseding transcription's recovery file survives the old task's exit")
        func supersededExitKeepsNewerRecoveryFile() async throws {
            let model = makeModel()
            let a = URL(fileURLWithPath: "/tmp/recovery-a.wav")
            let b = URL(fileURLWithPath: "/tmp/recovery-b.wav")

            let first = model.beginFileTranscribeRecovery(sourceURL: a)
            let second = model.beginFileTranscribeRecovery(sourceURL: b)

            model.endRecovery(first)
            await flushRecoveryWrites(model)
            #expect(recoveryFileExists(model))
            #expect(try await decodeRecoveryFile(model).sourceURL == b)

            model.endRecovery(second)
            #expect(!recoveryFileExists(model))
        }

        // MARK: - Recording checkpoints

        @Test("writeRecordingCheckpoint snapshots the confirmed segments")
        func recordingCheckpointSnapshotsSegments() async throws {
            let model = makeModel()
            model.selectedLanguage = "it"
            model.beginRecordingRecovery()
            model.liveSegments = Self.makeSegments()

            model.writeRecordingCheckpoint()

            let checkpoint = try await decodeRecoveryFile(model)
            #expect(checkpoint.kind == .recording)
            #expect(checkpoint.segments == Self.makeSegments())
            #expect(checkpoint.language == "it")
            #expect(checkpoint.modelName == model.selectedModel)
        }

        @Test("no checkpoint is written without confirmed segments or an active session")
        func recordingCheckpointSkipsEmptyAndInactive() {
            let model = makeModel()
            model.liveSegments = Self.makeSegments()
            model.writeRecordingCheckpoint()
            #expect(!recoveryFileExists(model))

            model.beginRecordingRecovery()
            model.liveSegments = []
            model.writeRecordingCheckpoint()
            #expect(!recoveryFileExists(model))
        }

        @Test("the recording watch checkpoints on the clock cadence")
        func recordingWatchWritesCheckpoints() async {
            let model = makeModel(clock: ImmediateClock())
            model.beginRecordingRecovery()
            model.liveSegments = Self.makeSegments()

            model.startRecordingWatch(checkpoints: true)
            let written = await waitUntil { self.recoveryFileExists(model) }
            model.stopRecordingWatch()

            #expect(written)
            #expect(model.recordingWatchTask == nil)
            model.endActiveRecovery()
            #expect(!recoveryFileExists(model))
        }

        @Test("a finished stream stops the watch and clears the recovery file once the take is in the library")
        func streamingFinishedClearsRecovery() async {
            let model = makeModel()
            model.beginRecordingRecovery()
            model.liveSegments = Self.makeSegments()
            model.writeRecordingCheckpoint()
            model.startRecordingWatch(checkpoints: true)
            await flushRecoveryWrites(model)
            #expect(recoveryFileExists(model))

            let final = Transcript(segments: Self.makeSegments(), language: "en", modelName: "m")
            await model.handleStreamingEvent(.finished(final))

            #expect(model.recordingWatchTask == nil)
            let cleared = await waitUntil { !self.recoveryFileExists(model) }
            #expect(cleared)
            #expect(await !model.library.list().isEmpty, "the checkpoint only goes once the take has its entry")
        }

        @Test("a failed stream clears the recovery file once its interrupted take is in the library")
        func streamingFailureClearsRecovery() async {
            let model = makeModel()
            model.beginRecordingRecovery()
            model.liveSegments = Self.makeSegments()
            model.writeRecordingCheckpoint()
            await flushRecoveryWrites(model)
            #expect(recoveryFileExists(model))

            await model.handleStreamingEvent(.failed("boom"))

            let cleared = await waitUntil { !self.recoveryFileExists(model) }
            #expect(cleared)
            #expect(await !model.library.list().isEmpty, "the checkpoint only goes once the take has its entry")
        }

        @Test("cancelling a recording clears the recovery file")
        func cancelClearsRecordingRecovery() async {
            let model = makeModel()
            model.beginRecordingRecovery()
            model.liveSegments = Self.makeSegments()
            model.writeRecordingCheckpoint()
            await flushRecoveryWrites(model)
            #expect(recoveryFileExists(model))

            model.cancelCurrentWork()

            #expect(!recoveryFileExists(model))
        }

        // MARK: - Launch offer

        @Test("launch offers a pending recording recovery and keeps the file until a decision")
        func launchOffersRecordingRecovery() throws {
            let lib = makeTempLibraryURL("recovery-launch")
            try writeCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", segments: Self.makeSegments()),
                libraryURL: lib
            )

            let model = makeModel(libraryURL: lib)

            #expect(model.pendingRecovery?.kind == .recording)
            #expect(recoveryFileExists(model))
        }

        @Test("launch skips a file recovery whose source vanished")
        func launchSkipsVanishedSource() throws {
            let lib = makeTempLibraryURL("recovery-vanished")
            let gone = URL(fileURLWithPath: "/tmp/parola-gone-\(UUID().uuidString).wav")
            try writeCheckpoint(
                RecoveryCheckpoint(kind: .fileTranscription, startedAt: Date(), modelName: "m", sourceURL: gone),
                libraryURL: lib
            )

            let model = makeModel(libraryURL: lib)

            #expect(model.pendingRecovery == nil)
            #expect(!recoveryFileExists(model))
        }

        @Test("launch deletes a corrupt recovery file")
        func launchDeletesCorruptFile() throws {
            let lib = makeTempLibraryURL("recovery-corrupt")
            try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: lib.appendingPathComponent("recovery.json"))

            let model = makeModel(libraryURL: lib)

            #expect(model.pendingRecovery == nil)
            #expect(!recoveryFileExists(model))
        }

        @Test("Not Now keeps a recording checkpoint's take in the library without opening it, then clears the checkpoint")
        func notNowKeepsTheRecordedTake() async throws {
            let lib = makeTempLibraryURL("recovery-decline")
            try writeCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", segments: Self.makeSegments()),
                libraryURL: lib
            )
            let model = makeModel(libraryURL: lib)
            #expect(model.pendingRecovery != nil)

            model.declinePendingRecovery()

            #expect(model.pendingRecovery == nil)
            let recoveryFileExistsWait = await waitUntil { !self.recoveryFileExists(model) }
            #expect(recoveryFileExistsWait)
            let entries = await model.library.list()
            #expect(entries.count == 1)
            #expect(entries.first?.title.hasSuffix("(recovered)") == true)
            #expect(model.transcript == nil, "a take kept for later doesn't open")
        }

        @Test("accepting a recording recovery installs and persists the transcript")
        func acceptRestoresRecording() async throws {
            let lib = makeTempLibraryURL("recovery-accept")
            let segments = Self.makeSegments()
            try writeCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", language: "it", segments: segments),
                libraryURL: lib
            )
            let model = makeModel(libraryURL: lib)

            model.acceptPendingRecovery()

            #expect(model.pendingRecovery == nil)
            #expect(model.transcript?.segments == segments)
            #expect(model.transcript?.language == "it")
            #expect(model.phase == .ready)

            var entries: [LibraryEntry] = []
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                entries = await model.library.list()
                if !entries.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(15))
            }
            #expect(entries.count == 1)
            #expect(entries.first?.title.hasPrefix("Recording ") == true)
            #expect(entries.first?.title.hasSuffix("(recovered)") == true)
            let recoveryFileExistsWait = await waitUntil { !self.recoveryFileExists(model) }
            #expect(recoveryFileExistsWait, "the checkpoint goes once the restored take is in the library")
        }

        /// The probe is the same await window loadEntry has, and a page opened inside it is the user's last word.
        @Test("a page opened while a recovered take is probed keeps the window")
        func acceptRestoreLeavesAPageOpenedDuringTheProbe() async throws {
            let lib = makeTempLibraryURL("recovery-route")
            let segments = Self.makeSegments()
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-recovery-missing-\(UUID().uuidString).wav")
            try writeCheckpoint(
                RecoveryCheckpoint(
                    kind: .recording, startedAt: Date(), modelName: "m", language: "it",
                    segments: segments, audioURL: missing
                ),
                libraryURL: lib
            )
            let model = makeModel(libraryURL: lib)

            model.acceptPendingRecovery()
            model.openStatistics()

            let transcriptWait = await waitUntil { model.transcript?.segments == segments }
            #expect(transcriptWait)
            #expect(model.route == .statistics)
        }

        @Test("accepting a file recovery re-runs the transcription")
        func acceptRerunsFileTranscription() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ripresa")]
                ))
                let lib = makeTempLibraryURL("recovery-rerun")
                let wav = try makeSilentWAV(label: "rerun")
                defer { try? FileManager.default.removeItem(at: wav) }
                try writeCheckpoint(
                    RecoveryCheckpoint(kind: .fileTranscription, startedAt: Date(), modelName: "m", sourceURL: wav),
                    libraryURL: lib
                )
                let model = makeModel(libraryURL: lib)
                #expect(model.pendingRecovery != nil)

                model.acceptPendingRecovery()

                let finished = await waitUntil { model.phase == .ready }
                #expect(finished)
                #expect(model.transcript?.text == "ripresa")
                #expect(!recoveryFileExists(model))
            }
        }

        @Test("a legacy recovery.json moves into the recovery folder under its checkpoint's own name, once")
        func legacyCheckpointMovesIntoTheFolder() throws {
            let lib = makeTempLibraryURL("recovery-legacy")
            try writeCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", segments: Self.makeSegments()),
                libraryURL: lib
            )

            let model = makeModel(libraryURL: lib)

            let offered = try #require(model.pendingRecovery)
            #expect(!FileManager.default.fileExists(atPath: model.legacyRecoveryFileURL.path))
            #expect(model.recoveryCheckpointFiles.map(\.lastPathComponent) == ["\(offered.id.uuidString).json"])
            model.recoveryOwner = nil
            let relaunched = makeModel(libraryURL: lib)
            #expect(relaunched.pendingRecovery?.id == offered.id, "the moved file keeps the id it was given")
        }

        @Test("ending one run's checkpoint leaves every other run's file on disk")
        func eachRunEndsOnlyItsOwnCheckpoint() async throws {
            let model = makeModel()
            let older = model.beginFileTranscribeRecovery(sourceURL: URL(fileURLWithPath: "/tmp/recovery-older.wav"))
            await flushRecoveryWrites(model)
            let olderFile = try #require(model.activeRecoveryFileURL)
            model.recoveryHeldByTake.insert(older)
            _ = model.beginFileTranscribeRecovery(sourceURL: URL(fileURLWithPath: "/tmp/recovery-newer.wav"))
            await flushRecoveryWrites(model)
            let newerFile = try #require(model.activeRecoveryFileURL)

            model.endActiveRecovery()
            #expect(!FileManager.default.fileExists(atPath: newerFile.path))
            #expect(FileManager.default.fileExists(atPath: olderFile.path), "an older take's held checkpoint outlives a newer run's end")

            model.recoveryHeldByTake.remove(older)
            model.endRecovery(older)
            #expect(!FileManager.default.fileExists(atPath: olderFile.path))
            #expect(model.recoveryCheckpointFiles.isEmpty)
        }

        @Test("a legacy recovery.json that couldn't be moved still goes once its offer is answered")
        func unmovedLegacyCheckpointStillGoes() async throws {
            let lib = makeTempLibraryURL("recovery-unmovable")
            try writeCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", segments: Self.makeSegments()),
                libraryURL: lib
            )
            // A plain file where the folder should be: the move into it fails.
            try Data().write(to: lib.appendingPathComponent("recovery"))
            let model = makeModel(libraryURL: lib)
            #expect(model.pendingRecovery != nil)
            #expect(FileManager.default.fileExists(atPath: model.legacyRecoveryFileURL.path))

            model.declinePendingRecovery()

            let fileExistsWait = await waitUntil { !FileManager.default.fileExists(atPath: model.legacyRecoveryFileURL.path) }
            #expect(fileExistsWait)
            #expect(await model.library.list().count == 1)
        }

        @Test("with several checkpoints on disk, the newest is offered and older takes go to the library quietly")
        func newestCheckpointIsOffered() async throws {
            let lib = makeTempLibraryURL("recovery-several")
            let older = RecoveryCheckpoint(
                kind: .recording, startedAt: Date().addingTimeInterval(-600), modelName: "m", segments: Self.makeSegments()
            )
            let newer = RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", segments: Self.makeSegments())
            let folder = lib.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for checkpoint in [older, newer] {
                try JSONEncoder().encode(checkpoint).write(to: folder.appendingPathComponent("\(checkpoint.id.uuidString).json"))
            }

            let model = makeModel(libraryURL: lib)
            #expect(model.pendingRecovery?.id == newer.id)
            let mapWait = await waitUntil { model.recoveryCheckpointFiles.map(\.lastPathComponent) == ["\(newer.id.uuidString).json"] }
            #expect(mapWait)
            #expect(await model.library.list().count == 1, "the older take is kept, not dropped")

            model.declinePendingRecovery()
            let recoveryFileExistsWait = await waitUntil { !self.recoveryFileExists(model) }
            #expect(recoveryFileExistsWait)
            #expect(await model.library.list().count == 2)
        }

        @Test("recovered recording titles carry the timestamp and suffix")
        func recoveredTitleFormat() {
            let title = AppModel.recoveredRecordingTitle(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(title.hasPrefix("Recording "))
            #expect(title.hasSuffix("(recovered)"))
        }
    }
}
