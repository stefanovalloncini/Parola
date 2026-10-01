import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A capture the test drives: it comes up when let, meters only what the test records, and keeps every pause, prepare and cancel.
private actor ScriptedTrack: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    nonisolated let file: URL
    private let startFailure: (any Error)?
    private let prepareFailure: (any Error)?
    private var holdsStart: Bool
    private var startGate: CheckedContinuation<Void, Never>?
    private(set) var pauseCalls: [Bool] = []
    private(set) var cancelled = false
    private(set) var prepared = false

    init(file: URL, startFailure: (any Error)? = nil, prepareFailure: (any Error)? = nil, holdsStart: Bool = false) {
        self.file = file
        self.startFailure = startFailure
        self.prepareFailure = prepareFailure
        self.holdsStart = holdsStart
    }

    func start() async throws {
        if holdsStart { await withCheckedContinuation { startGate = $0 } }
        if let startFailure { throw startFailure }
    }

    func letStart() {
        holdsStart = false
        startGate?.resume()
        startGate = nil
    }

    func prepare() async throws -> URL {
        prepared = true
        if let prepareFailure { throw prepareFailure }
        return file
    }

    func cancel() async { cancelled = true }
    func setPaused(_ paused: Bool) async { pauseCalls.append(paused) }
    func inFlightURL() async -> URL? { file }
}

/// The files the engine was handed, and how many channels each had while it read them.
private actor EngineReads {
    private(set) var files: [URL] = []
    private(set) var channels: [AVAudioChannelCount] = []

    func note(_ file: URL?) {
        guard let file else { return }
        files.append(file)
        channels.append((try? AVAudioFile(forReading: file))?.fileFormat.channelCount ?? 0)
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Meeting second track", .serialized)
    struct MeetingSecondTrackTests {

        private func makeModel(
            libraryURL: URL = makeTempLibraryURL("second-track"), defaults: UserDefaults = temporaryDefaults()
        ) -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: libraryURL,
                defaultsOverride: defaults,
                sideEffects: [],
                filePicker: TestFilePicker()
            ))
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func inflight(_ library: URL) throws -> URL {
            let folder = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        private func age(_ file: URL, by seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: file.path)
        }

        private func writeLegacyCheckpoint(_ checkpoint: RecoveryCheckpoint, library: URL) throws {
            try JSONEncoder().encode(checkpoint).write(to: library.appendingPathComponent("recovery.json"))
        }

        /// A two-second meeting in the take's working folder: the Mac talks in the first second, you in the second.
        private func meetingFiles(_ model: AppModel) throws -> (mac: URL, mic: URL) {
            try meetingFiles(in: model.inflightRecordingsURL)
        }

        private func meetingFiles(in folder: URL) throws -> (mac: URL, mic: URL) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let mac = folder.appendingPathComponent("parola-system-\(id).wav")
            let mic = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(id).wav")
            let rate = 16_000.0
            let quiet = [Float](repeating: 0, count: Int(rate))
            try TestAudio.write(channels: [TestAudio.sine(seconds: 1, hz: 440, amplitude: 0.4, sampleRate: rate) + quiet], sampleRate: rate, to: mac)
            try TestAudio.write(channels: [quiet + TestAudio.sine(seconds: 1, hz: 220, amplitude: 0.4, sampleRate: rate)], sampleRate: rate, to: mic)
            return (mac, mic)
        }

        private func startMeeting(
            _ model: AppModel, mac: ScriptedTrack, mic: ScriptedTrack?, category: EntryCategory = .meeting,
            micOverride: (@MainActor () -> (any LiveAudioSource)?)? = nil
        ) async throws {
            model.useStreaming = false
            model.selectedModel = "openai_whisper-tiny"
            model.takeCaptureOverride = { _ in mac }
            model.micTrackCaptureOverride = micOverride ?? { mic }
            model.pendingRecordingCategory = category
            model.startRecording(source: .systemAudio)
            let up = await waitUntil { model.liveSource != nil }
            guard up else { throw FixtureTakeDidNotStart() }
            mac.levelMeter.record(0.4)
            let recording = await waitUntil { model.recording?.state == .recording }
            guard recording else { throw FixtureTakeDidNotStart() }
        }

        private func waitForMicTrack(_ model: AppModel) async -> Bool {
            await waitUntil { model.micTrack?.capture != nil }
        }

        private func channels(of file: URL) throws -> AVAudioChannelCount {
            try AVAudioFile(forReading: file).fileFormat.channelCount
        }

        private func exists(_ file: URL) -> Bool {
            FileManager.default.fileExists(atPath: file.path)
        }

        // MARK: - Recording the microphone beside the Mac audio

        @Test("a meeting take records your microphone beside the Mac audio, and its checkpoint names both")
        func meetingRecordsTheMic() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                let mic = ScriptedTrack(file: files.mic)

                try await startMeeting(model, mac: mac, mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                #expect(model.liveCompanionAudioURL == files.mic)
                await model.pendingRecoveryWrite?.value
                let recovery = try #require(model.activeTake?.recovery)
                let checkpointFile = model.recoveryFileURL(for: try #require(model.recoveryFileIDs[recovery]))
                let written = try JSONDecoder().decode(RecoveryCheckpoint.self, from: try Data(contentsOf: checkpointFile))
                #expect(written.audioURL == files.mac)
                #expect(written.companionAudioURL == files.mic)
                model.cancelCurrentWork()
            }
        }

        @Test("a Mac-audio take that isn't a meeting, or a meeting with the setting off, records no microphone")
        func onlyMeetingsWithTheSettingOn() async throws {
            try await withMocksCleared(.audioSource) {
                var asked = 0
                let counting: @MainActor () -> (any LiveAudioSource)? = {
                    asked += 1
                    return nil
                }
                let plain = makeModel()
                let files = try meetingFiles(plain)
                try await startMeeting(plain, mac: ScriptedTrack(file: files.mac), mic: nil, category: .transcription, micOverride: counting)
                await settle()
                #expect(plain.micTrack == nil)
                plain.cancelCurrentWork()

                let off = makeModel()
                off.meetingRecordsMicrophone = false
                let offFiles = try meetingFiles(off)
                try await startMeeting(off, mac: ScriptedTrack(file: offFiles.mac), mic: nil, micOverride: counting)
                await settle()
                #expect(off.micTrack == nil)
                #expect(off.liveCompanionAudioURL == nil)
                off.cancelCurrentWork()
                #expect(asked == 0)
            }
        }

        @Test("a meeting's microphone is placed in the take by its first sample, and the checkpoint says where")
        func micTrackOffset() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                try await Task.sleep(for: .milliseconds(300))

                mic.levelMeter.record(0.3)

                let placed = await waitUntil { model.micTrack?.offset != nil }
                #expect(placed)
                let offset = try #require(model.micTrack?.offset)
                #expect(offset > 0.2 && offset < 1.5, "about as long after the Mac audio began as it came up")
                #expect(model.liveCompanionStartOffset == offset)
                await model.pendingRecoveryWrite?.value
                let recovery = try #require(model.activeTake?.recovery)
                let checkpointFile = model.recoveryFileURL(for: try #require(model.recoveryFileIDs[recovery]))
                let written = try JSONDecoder().decode(RecoveryCheckpoint.self, from: try Data(contentsOf: checkpointFile))
                #expect(written.companionStartOffset == offset)
                model.cancelCurrentWork()
            }
        }

        @Test("pausing and resuming a meeting take reach its microphone as they reach the Mac audio, in order")
        func pauseReachesTheMic() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: mac, mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                #expect(model.pauseTake())
                #expect(model.resumeTake())

                let told = await waitUntil { await mic.pauseCalls.count == 2 }
                #expect(told)
                #expect(await mic.pauseCalls == [true, false])
                #expect(await mac.pauseCalls == [true, false])
                model.cancelCurrentWork()
            }
        }

        @Test("a microphone that comes up while the take is paused joins it paused")
        func lateMicJoinsPaused() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic, holdsStart: true)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                #expect(model.pauseTake())

                await mic.letStart()

                let joined = await waitUntil { await mic.pauseCalls == [true] }
                #expect(joined)
                #expect(model.resumeTake())
                let resumed = await waitUntil { await mic.pauseCalls == [true, false] }
                #expect(resumed)
                model.cancelCurrentWork()
            }
        }

        @Test("Stop folds your microphone into the take: the entry is stereo, the engine reads one mono mix, and your side is labelled Me")
        func stopFoldsTheMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone"), (1, 2, "Thanks, glad to be here")])
                let reads = EngineReads()
                model.postProcessOperation = { transcript in
                    await reads.note(transcript.sourceURL)
                    return transcript
                }
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let stored = try await model.library.load(entry.id).document
                let audio = try #require(stored.audioURL)
                #expect(try channels(of: audio) == 2, "the entry keeps both sides")
                let speakers = stored.transcript.segments.map(\.speaker)
                #expect(speakers == [nil, AppModel.meLabel()])
                #expect(await reads.channels == [1], "the engine read the mono mix")
                let mono = try #require(await reads.files.first)
                #expect(mono != audio)
                let cleaned = await waitUntil { !exists(mono) && !exists(files.mac) && !exists(files.mic) }
                #expect(cleaned, "the mix and both tracks go once the take is one file")
                #expect(await mic.prepared)
                #expect(model.liveCompanionAudioURL == nil)
            }
        }

        @Test("a meeting whose Mac file was cut short still folds your microphone in, and is saved as interrupted")
        func cutShortMacStillFolds() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac, prepareFailure: CaptureInterrupted(url: files.mac, reason: "the disk is full"))
                try await startMeeting(model, mac: mac, mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                #expect(entry.title.hasSuffix("(interrupted)"))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
            }
        }

        @Test("Stop and Save on quit keeps your microphone in the saved take")
        func quitKeepsTheMic() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                #expect(await model.resolveQuitDuringTake(.stopAndSave))

                let entry = try #require(await landedEntry(model))
                #expect(entry.title.hasSuffix("(not transcribed)"))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
            }
        }

        @Test("Discard deletes your microphone's file with the take and saves nothing")
        func discardDropsTheMic() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                await model.discardTake()

                #expect(await mic.cancelled)
                #expect(!exists(files.mic))
                #expect(!exists(files.mac))
                #expect(model.micTrack == nil)
                await settle()
                #expect(await model.library.list().isEmpty)
            }
        }

        @Test("Cancel ends your microphone's track with the take")
        func cancelDropsTheMic() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.cancelCurrentWork()

                let cancelled = await waitUntil { await mic.cancelled }
                #expect(cancelled)
                #expect(model.micTrack == nil)
                #expect(model.liveCompanionAudioURL == nil)
            }
        }

        @Test("a microphone that can't start leaves a Mac-audio take that says so, once")
        func refusedMicSaysSoOnce() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                let files = try meetingFiles(model)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone")])
                let refused = ScriptedTrack(file: files.mic, startFailure: ParolaError.captureUnavailable("microphone not available"))
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: refused)

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackMissingMessage())
                #expect(notice?.tone == .info)
                #expect(model.recording?.state == .recording, "the take goes on with the Mac audio")
                let takeID = try #require(model.recording?.takeID)
                model.exportNotice = nil
                model.noteMicTrackMissing(takeID, stopped: true)
                #expect(model.exportNotice == nil, "said once for the take")

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 1)
            }
        }

        @Test("a microphone that stops while the Mac audio keeps coming is noticed once; one that keeps up never is")
        func stoppedMicIsNoticed() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                model.micTrackStallTicks = 3
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: mac, mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                for _ in 0..<12 {
                    mac.levelMeter.record(0.3)
                    mic.levelMeter.record(0.2)
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(model.exportNotice == nil, "both sides are coming")

                let feeding = Task { @MainActor in
                    for _ in 0..<60 {
                        mac.levelMeter.record(0.3)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                let notice = await waitForNotice(model)
                feeding.cancel()
                #expect(notice?.message == AppModel.micTrackStoppedMessage())
                #expect(model.recording?.state == .recording)
                #expect(model.micTrack?.stalled == true)
                model.cancelCurrentWork()
            }
        }

        @Test("a test host never opens the real microphone: with no microphone mock, a meeting records the Mac audio alone, quietly")
        func noRealMicInTests() async throws {
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                let files = try meetingFiles(model)
                model.useStreaming = false
                model.takeCaptureOverride = { _ in ScriptedTrack(file: files.mac) }
                model.pendingRecordingCategory = .meeting
                model.startRecording(source: .systemAudio)
                let up = await waitUntil { model.liveSource != nil }
                #expect(up)
                await settle()

                #expect(model.micTrack == nil)
                #expect(model.exportNotice == nil)
                model.cancelCurrentWork()
            }
        }

        @Test("Retry of a meeting whose transcription failed runs on its stereo take and labels your side Me")
        func retryLabelsMe() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                let files = try meetingFiles(model)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "the engine gave up")
                ))
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.stopRecordingAndTranscribe()
                let failed = await waitUntil { model.recording?.failure != nil && !model.hasPendingTakeWork }
                #expect(failed)
                let saved = try #require(await landedEntry(model))
                let savedAudio = try #require(try await model.library.load(saved.id).document.audioURL)
                #expect(try channels(of: savedAudio) == 2, "the failure saved both sides")

                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone"), (1, 2, "Thanks, glad to be here")])
                await model.unloadTranscriptionSession()
                model.retryFailedTake()

                var speakers: [String?] = []
                let labelled = await waitUntil {
                    speakers = (try? await model.library.load(saved.id).document.transcript.segments.map(\.speaker)) ?? []
                    return speakers.count == 2
                }
                #expect(labelled)
                #expect(speakers == [nil, AppModel.meLabel()])
                #expect(await model.library.list().count == 1, "Retry fills in the entry the failure saved")
            }
        }

        // MARK: - After a crash

        private func crashedMeeting(in library: URL, age seconds: TimeInterval = 300) throws -> (mac: URL, mic: URL) {
            let files = try meetingFiles(in: try inflight(library))
            for file in [files.mac, files.mic] { try age(file, by: seconds) }
            return files
        }

        private func meetingCheckpoint(_ files: (mac: URL, mic: URL)) -> RecoveryCheckpoint {
            RecoveryCheckpoint(
                kind: .recording, startedAt: Date(), modelName: "m", audioURL: files.mac, source: .systemAudio, category: .meeting,
                companionAudioURL: files.mic, companionStartOffset: 0
            )
        }

        private func mixLeftovers(_ library: URL) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("inflight").path)) ?? []
            return names.filter { $0.hasPrefix(RecordingScratch.meetingMixPrefix) }
        }

        @Test("Restore brings a crashed meeting back with your microphone mixed in, and lets both files go once it is saved")
        func restoreMixesTheMicBackIn() async throws {
            let library = makeTempLibraryURL("second-track-restore")
            let files = try crashedMeeting(in: library)
            try writeLegacyCheckpoint(meetingCheckpoint(files), library: library)
            let model = makeModel(libraryURL: library)
            #expect(model.pendingRecovery?.companionAudioURL == files.mic)

            model.acceptPendingRecovery()

            let entry = try #require(await landedEntry(model))
            #expect(entry.category == .meeting)
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
            let released = await waitUntil { !exists(files.mac) && !exists(files.mic) }
            #expect(released)
            let cleared = await waitUntil { model.recoveryCheckpointFiles.isEmpty && mixLeftovers(library).isEmpty }
            #expect(cleared)
        }

        @Test("Not Now keeps a crashed meeting in the library with your microphone mixed in")
        func notNowMixesTheMicBackIn() async throws {
            let library = makeTempLibraryURL("second-track-not-now")
            let files = try crashedMeeting(in: library)
            try writeLegacyCheckpoint(meetingCheckpoint(files), library: library)
            let model = makeModel(libraryURL: library)

            model.declinePendingRecovery()

            let entry = try #require(await landedEntry(model))
            #expect(entry.title.hasSuffix("(recovered)"))
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
            let released = await waitUntil { !exists(files.mac) && !exists(files.mic) && mixLeftovers(library).isEmpty }
            #expect(released)
        }

        @Test("a crashed meeting whose microphone file is gone comes back with the Mac side alone")
        func restoreWithoutTheMicKeepsTheMacSide() async throws {
            let library = makeTempLibraryURL("second-track-mic-gone")
            let files = try crashedMeeting(in: library)
            try FileManager.default.removeItem(at: files.mic)
            try writeLegacyCheckpoint(meetingCheckpoint(files), library: library)
            let model = makeModel(libraryURL: library)

            model.acceptPendingRecovery()

            let entry = try #require(await landedEntry(model))
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 1)
        }

        @Test("the sweep brings back a meeting that never reached the library with your microphone mixed in")
        func sweepMixesAnOrphanedPair() async throws {
            let library = makeTempLibraryURL("second-track-sweep-pair")
            let files = try crashedMeeting(in: library, age: 3_600)
            let orphan = try makeTakeWAV("lone-mic", in: try inflight(library), prefix: RecordingScratch.meetingMicPrefix)
            try age(orphan, by: 3_600)

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let listed = await model.library.list()
            #expect(listed.count == 1, "one meeting, and a microphone track is never a take of its own")
            let entry = try #require(listed.first)
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
            #expect(!exists(files.mac) && !exists(files.mic))
            #expect(mixLeftovers(library).isEmpty)
            #expect(exists(orphan), "an orphaned track goes only after two days")
            #expect(AppModel.pairedMeetingMic(for: files.mac, in: [(orphan, Date()), (files.mic, Date())]) == files.mic)
        }

        @Test("an orphaned meeting whose Mac side recorded nothing still comes back for its microphone")
        func sweepKeepsAMicWithAnEmptyMacSide() async throws {
            let library = makeTempLibraryURL("second-track-sweep-empty-mac")
            let folder = try inflight(library)
            let id = UUID().uuidString
            let mac = folder.appendingPathComponent("parola-system-\(id).wav")
            let mic = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(id).wav")
            try TestAudio.write(channels: [[]], sampleRate: 16_000, to: mac)
            try TestAudio.write(channels: [TestAudio.sine(seconds: 1, hz: 220, amplitude: 0.4, sampleRate: 16_000)], sampleRate: 16_000, to: mic)
            for file in [mac, mic] { try age(file, by: 3_600) }

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let listed = await model.library.list()
            #expect(listed.count == 1)
            let entry = try #require(listed.first)
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
        }

        // MARK: - Me in People

        @Test("with a person marked This Is Me, your side of a meeting takes their name, and the entry stands for them")
        func meTakesTheMarkedPersonsName() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                await model.addPerson(named: "Stefano")
                let me = try #require(model.person(named: "Stefano"))
                model.setMePerson(me.id)
                #expect(model.meetingMeLabel == "Stefano")
                let files = try meetingFiles(model)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone"), (1, 2, "Thanks, glad to be here")])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let speakers = try await model.library.load(entry.id).document.transcript.segments.map(\.speaker)
                #expect(speakers == [nil, "Stefano"])
                let assigned = await waitUntil { model.libraryEntry(id: entry.id)?.speakerAssignments["Stefano"] == me.id }
                #expect(assigned)
                await model.awaitSpeakerAssignmentWrites()
                let stored = try await model.library.load(entry.id).entry.speakerAssignments
                #expect(stored["Stefano"] == me.id)
            }
        }

        @Test("the mark follows its person through a merge, goes with a delete, and People's reset clears it")
        func meMarkFollowsThePerson() async throws {
            let defaults = temporaryDefaults()
            let model = makeModel(defaults: defaults)
            await model.addPerson(named: "Stefano")
            await model.addPerson(named: "Stefano V")
            let me = try #require(model.person(named: "Stefano V"))
            let other = try #require(model.person(named: "Stefano"))
            #expect(model.mePerson == nil)
            #expect(model.meetingMeLabel == AppModel.meLabel())

            model.setMePerson(me.id)
            #expect(model.mePerson?.id == me.id)
            #expect(defaults.string(forKey: "mePersonID") == me.id.uuidString)

            await model.mergePerson(me.id, into: other.id)
            #expect(model.mePerson?.id == other.id)
            #expect(model.meetingMeLabel == "Stefano")

            await model.deletePerson(other.id)
            #expect(model.mePerson == nil)
            #expect(model.mePersonID.isEmpty)
            #expect(SettingsPaneScope.people.defaultsKeys.contains("mePersonID"))
        }

        @Test("the microphone notices and the Me label read in Italian")
        func micTrackStringsReadInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(AppModel.meLabel(bundle: italian) == "Io")
            #expect(String(localized: "This Is Me", bundle: italian) == "Sono io")
            #expect(AppModel.micTrackMissingMessage(bundle: italian) == "Il tuo microfono non è in questa registrazione. Contiene solo l'audio del Mac.")
            #expect(AppModel.micTrackStoppedMessage(bundle: italian) == "Il tuo microfono si è fermato. Il resto della registrazione contiene solo l'audio del Mac.")
        }

        // MARK: - The setting

        @Test("recording your microphone in meetings starts on, is kept, resets with its pane, and the bridge may set it")
        func micSettingStartsOn() {
            let defaults = temporaryDefaults()
            let model = makeModel(defaults: defaults)
            #expect(model.meetingRecordsMicrophone)

            model.meetingRecordsMicrophone = false
            #expect(defaults.object(forKey: "meetingRecordsMicrophone") as? Bool == false)
            model.reloadSettings()
            #expect(!model.meetingRecordsMicrophone)

            #expect(SettingsPaneScope.recordMeetings.defaultsKeys.contains("meetingRecordsMicrophone"))
            #expect(ParolaAutomationServer.writableSettingKeys.contains("meetingRecordsMicrophone"))
            for key in SettingsPaneScope.recordMeetings.defaultsKeys { defaults.removeObject(forKey: key) }
            model.reloadSettings()
            #expect(model.meetingRecordsMicrophone)
            #expect(SettingsSidebarCatalog.matches(route: .recordMeetings, query: "microphone"))
        }

        @Test("the setting reads in Italian")
        func micSettingReadsInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(String(localized: "Record my microphone in meetings", bundle: italian) == "Registra il mio microfono nelle riunioni")
        }

        // MARK: - The checkpoint and the sweep

        @Test("a meeting's checkpoint names its microphone track and where it starts, and counts it among its files")
        func checkpointCarriesTheMicTrack() throws {
            let take = URL(fileURLWithPath: "/tmp/inflight/parola-system-1.wav")
            let mic = URL(fileURLWithPath: "/tmp/inflight/parola-meetmic-1.wav")
            let checkpoint = RecoveryCheckpoint(
                kind: .recording, startedAt: Date(), modelName: "m", audioURL: take, source: .systemAudio, category: .meeting,
                companionAudioURL: mic, companionStartOffset: 0.25
            )

            let decoded = try JSONDecoder().decode(RecoveryCheckpoint.self, from: try JSONEncoder().encode(checkpoint))

            #expect(decoded.companionAudioURL == mic)
            #expect(decoded.companionStartOffset == 0.25)
            #expect(decoded.referencedPaths.first == take.resolvingSymlinksInPath().path, "the take's own file still comes first")
            #expect(decoded.referencedPaths.contains(mic.resolvingSymlinksInPath().path))
        }

        @Test("a take's checkpoint is written with the microphone track recording beside it")
        func liveCheckpointNamesTheMicTrack() async throws {
            let model = makeModel()
            let take = URL(fileURLWithPath: "/tmp/parola-system-live.wav")
            let mic = URL(fileURLWithPath: "/tmp/parola-meetmic-live.wav")
            model.beginRecordingRecovery()
            model.liveRecordingAudioURL = take
            model.liveCompanionAudioURL = mic
            model.liveCompanionStartOffset = 0.1

            model.writeRecordingCheckpoint()
            await model.pendingRecoveryWrite?.value

            let written = try JSONDecoder().decode(
                RecoveryCheckpoint.self, from: try Data(contentsOf: try #require(model.activeRecoveryFileURL))
            )
            #expect(written.audioURL == take)
            #expect(written.companionAudioURL == mic)
            #expect(written.companionStartOffset == 0.1)
            model.endActiveRecovery()
        }

        @Test("the microphone track recording now is a working file in use, which the heartbeat keeps fresh")
        func liveMicTrackIsInUse() throws {
            let library = makeTempLibraryURL("second-track-in-use")
            let folder = try inflight(library)
            let model = makeModel(libraryURL: library)
            let mic = try makeTakeWAV("mic-in-use", in: folder, prefix: RecordingScratch.meetingMicPrefix)
            try age(mic, by: 3_600)

            model.liveCompanionAudioURL = mic
            model.touchTakeFilesInUse()

            #expect(model.inflightFileInUse(mic))
            let modified = try #require(try mic.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            #expect(modified > Date().addingTimeInterval(-60))
        }

        @Test("the sweep keeps a microphone track while its take is in the folder, and takes an orphaned one only after two days")
        func sweepKeepsTheMicTrackWithItsTake() {
            let folder = URL(fileURLWithPath: "/tmp/parola-sweep", isDirectory: true)
            let now = Date()
            let days = now.addingTimeInterval(-3 * 86_400)
            let take = folder.appendingPathComponent("parola-system-AAA.wav")
            let paired = folder.appendingPathComponent("parola-meetmic-AAA.wav")
            let orphan = folder.appendingPathComponent("parola-meetmic-BBB.wav")
            let youngOrphan = folder.appendingPathComponent("parola-meetmic-CCC.wav")

            let stale = AppModel.staleInflightFiles(
                in: [(take, now.addingTimeInterval(-60)), (paired, days), (orphan, days), (youngOrphan, now.addingTimeInterval(-3_600))],
                keeping: [],
                now: now
            )

            #expect(!stale.contains(paired), "two days old, but its take is still here")
            #expect(stale.contains(orphan))
            #expect(!stale.contains(youngOrphan), "an orphan goes only after two days")
            #expect(!stale.contains(take), "a take written a minute ago may still be recording")
        }

        @Test("a sweep at launch deletes only the two-day-old orphaned microphone track")
        func launchSweepDeletesOnlyOldOrphans() async throws {
            let library = makeTempLibraryURL("second-track-sweep")
            let folder = try inflight(library)
            let take = try makeTakeWAV("still-recording", seconds: 1, in: folder, prefix: "parola-system")
            let pairedName = RecordingScratch.meetingMicURL(for: take)
            try Data(count: 64 * 1024).write(to: pairedName)
            try age(pairedName, by: 3 * 86_400)
            let oldOrphan = try makeTakeWAV("old-orphan", in: folder, prefix: RecordingScratch.meetingMicPrefix)
            try age(oldOrphan, by: 3 * 86_400)
            let youngOrphan = try makeTakeWAV("young-orphan", in: folder, prefix: RecordingScratch.meetingMicPrefix)
            try age(youngOrphan, by: 3_600)

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            #expect(FileManager.default.fileExists(atPath: pairedName.path), "kept with its take")
            #expect(!FileManager.default.fileExists(atPath: oldOrphan.path))
            #expect(FileManager.default.fileExists(atPath: youngOrphan.path))
            #expect(await model.library.list().isEmpty, "a microphone track is never imported as a take of its own")
        }

        @Test("a second instance leaves a running take's microphone track alone, whatever its name")
        func secondInstanceLeavesTheMicTrackAlone() async throws {
            let library = makeTempLibraryURL("second-track-two-instances")
            let folder = try inflight(library)
            let first = makeModel(libraryURL: library)
            await first.inflightSweep?.value
            let take = try makeTakeWAV("recording-elsewhere", seconds: 1, in: folder, prefix: "parola-system")
            let mic = try makeTakeWAV("mic-elsewhere", seconds: 1, in: folder, prefix: RecordingScratch.meetingMicPrefix)
            for file in [take, mic] { try age(file, by: 3 * 86_400) }
            first.beginRecordingRecovery()
            first.liveRecordingAudioURL = take
            first.liveCompanionAudioURL = mic
            first.writeRecordingCheckpoint()
            await first.pendingRecoveryWrite?.value

            let second = makeModel(libraryURL: library)
            await second.inflightSweep?.value

            #expect(FileManager.default.fileExists(atPath: take.path))
            #expect(FileManager.default.fileExists(atPath: mic.path), "its checkpoint names it, though nothing pairs it by name")
            first.endActiveRecovery()
        }

        @Test("Discard on the recovery offer deletes the meeting's microphone track with its take")
        func discardOfferDeletesTheMicTrack() async throws {
            let library = makeTempLibraryURL("second-track-discard-offer")
            let folder = try inflight(library)
            let take = try makeTakeWAV("crashed-meeting", in: folder, prefix: "parola-system")
            let mic = RecordingScratch.meetingMicURL(for: take)
            try FileManager.default.copyItem(at: take, to: mic)
            for file in [take, mic] { try age(file, by: 300) }
            try writeLegacyCheckpoint(RecoveryCheckpoint(
                kind: .recording, startedAt: Date(), modelName: "m", audioURL: take, source: .systemAudio, category: .meeting,
                companionAudioURL: mic
            ), library: library)
            let model = makeModel(libraryURL: library)
            #expect(model.pendingRecovery?.companionAudioURL == mic)
            #expect(model.inflightFileInUse(mic), "an offer still waiting holds its microphone track too")

            model.discardPendingRecovery()

            #expect(!FileManager.default.fileExists(atPath: take.path))
            #expect(!FileManager.default.fileExists(atPath: mic.path))
        }
    }
}
