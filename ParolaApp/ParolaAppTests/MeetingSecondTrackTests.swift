import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// What a wedged input device never returns from.
private enum Wedge: Hashable {
    case prepare
    case pause
    case cancel
}

/// A capture the test drives: it comes up when let, meters only what the test records, and keeps every pause, prepare and cancel.
private actor ScriptedTrack: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    nonisolated let file: URL
    private let startFailure: (any Error)?
    private let prepareFailure: (any Error)?
    private var holdsStart: Bool
    private var startGate: CheckedContinuation<Void, Never>?
    private var holdsInFlightRead: Bool
    private var heldRead: CheckedContinuation<Void, Never>?
    private var wedges: Set<Wedge>
    private var wedged: [CheckedContinuation<Void, Never>] = []
    private(set) var pauseCalls: [Bool] = []
    private(set) var cancelled = false
    private(set) var prepared = false
    private(set) var started = false
    private var ends: (@Sendable () -> Void)?

    init(
        file: URL, startFailure: (any Error)? = nil, prepareFailure: (any Error)? = nil, holdsStart: Bool = false,
        holdsInFlightRead: Bool = false, wedges: Set<Wedge> = []
    ) {
        self.file = file
        self.startFailure = startFailure
        self.prepareFailure = prepareFailure
        self.holdsStart = holdsStart
        self.holdsInFlightRead = holdsInFlightRead
        self.wedges = wedges
    }

    private func hang(_ wedge: Wedge) async {
        guard wedges.contains(wedge) else { return }
        await withCheckedContinuation { wedged.append($0) }
    }

    func unwedge() {
        wedges = []
        for waiter in wedged { waiter.resume() }
        wedged.removeAll()
    }

    func start() async throws {
        started = true
        if holdsStart { await withCheckedContinuation { startGate = $0 } }
        if let startFailure { throw startFailure }
    }

    func letStart() {
        holdsStart = false
        startGate?.resume()
        startGate = nil
    }

    func prepare() async throws -> URL {
        await hang(.prepare)
        prepared = true
        if let prepareFailure { throw prepareFailure }
        return file
    }

    func cancel() async {
        await hang(.cancel)
        cancelled = true
    }

    func setPaused(_ paused: Bool) async {
        await hang(.pause)
        pauseCalls.append(paused)
    }
    func inFlightURL() async -> URL? {
        if holdsInFlightRead { await withCheckedContinuation { heldRead = $0 } }
        return file
    }

    func letInFlightRead() {
        holdsInFlightRead = false
        heldRead?.resume()
        heldRead = nil
    }

    func whenCaptureEnds(_ handler: @escaping @Sendable () -> Void) async {
        ends = handler
    }

    /// Ends as ScreenCaptureKit's capture does after a display change, without being asked.
    func endByItself() {
        ends?()
    }
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

/// Holds a step until the test lets it go.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reached = false

    func wait() async {
        reached = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
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
            // The launch's model scan swaps a model that isn't installed for the default, which needn't be Whisper.
            await model.awaitModelListRefresh()
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
                await model.discardTake()
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
                await plain.discardTake()

                let off = makeModel()
                off.meetingRecordsMicrophone = false
                let offFiles = try meetingFiles(off)
                try await startMeeting(off, mac: ScriptedTrack(file: offFiles.mac), mic: nil, micOverride: counting)
                await settle()
                #expect(off.micTrack == nil)
                #expect(off.liveCompanionAudioURL == nil)
                await off.discardTake()
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
                await model.discardTake()
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
                await model.discardTake()
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
                await model.discardTake()
            }
        }

        /// Stops a meeting take with `model` selected for its transcription; hands back the entry and what the engine read.
        private func stopFoldedMeeting(engineModel: String) async throws -> (entry: LibraryEntry, reads: EngineReads, files: (mac: URL, mic: URL)) {
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
            model.selectedModel = engineModel
            let micUp = await waitForMicTrack(model)
            guard micUp else { throw FixtureTakeDidNotStart() }

            model.stopRecordingAndTranscribe()

            let entry = try #require(await landedEntry(model))
            let stored = try await model.library.load(entry.id).document
            let audio = try #require(stored.audioURL)
            #expect(try channels(of: audio) == 2, "the entry keeps both sides")
            let speakers = stored.transcript.segments.map(\.speaker)
            #expect(speakers == [nil, AppModel.meLabel()])
            let cleaned = await waitUntil {
                let read = await reads.files
                return !read.contains(where: exists) && !exists(files.mac) && !exists(files.mic)
            }
            #expect(cleaned, "the mix and both tracks go once the take is one file")
            #expect(await mic.prepared)
            #expect(model.liveCompanionAudioURL == nil)
            return (entry, reads, files)
        }

        @Test("Stop folds your microphone into the take: the entry is stereo, WhisperKit reads it as it is, and your side is labelled Me")
        func stopFoldsTheMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let folded = try await stopFoldedMeeting(engineModel: "openai_whisper-tiny")
                #expect(await folded.reads.channels == [2], "WhisperKit sums the sides itself, so no mono mix is written")
            }
        }

        @Test("an engine that reads one channel gets a mono mix of both sides, made with the fold")
        func otherEnginesReadAMonoMix() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let folded = try await stopFoldedMeeting(engineModel: "nvidia_parakeet-tdt-0.6b-v3")
                #expect(await folded.reads.channels == [1])
                let mono = try #require(await folded.reads.files.first)
                #expect(mono.deletingLastPathComponent().lastPathComponent == "inflight", "in the working folder, where a sweep clears it")
                #expect(mono.lastPathComponent.hasPrefix(RecordingScratch.meetingMixPrefix))
            }
        }

        /// Whether the model's run failed, as the error card shows it.
        private func runFailed(_ model: AppModel) -> Bool {
            if case .failed = model.phase { return true }
            return false
        }

        @Test("Transcribe Again on a meeting with no room for the mono mix Parakeet needs fails and says so, never handing the engine the stereo")
        func retranscribeWithoutRoomForTheMonoFails() async throws {
            try await withMocksCleared(.transcriber) {
                let library = makeTempLibraryURL("second-track-no-room-rerun")
                let stereo = try TestAudio.stereo(leftAmplitude: 0.3, rightAmplitude: 0.3, seconds: 1)
                let seeded = try await LibraryStore(libraryURL: library, extraIndexer: nil).add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Welcome")], language: "en", modelName: "m"
                    ),
                    audioSource: stereo, category: .meeting, source: .systemAudio
                )
                let model = makeModel(libraryURL: library)
                await model.awaitModelListRefresh()
                await installMockTranscriber(segments: [(0, 1, "Welcome")])
                let reads = EngineReads()
                model.postProcessOperation = { transcript in
                    await reads.note(transcript.sourceURL)
                    return transcript
                }
                _ = try await model.openEntry(seeded.id)
                model.freeDiskSpaceProvider = { AppModel.meetingFoldMarginBytes + 1_000 }

                model.retranscribeCurrentEntry(model: "nvidia_parakeet-tdt-0.6b-v3", language: nil)
                let started = model.retranscribeRequest != nil
                #expect(started, "Transcribe Again started a run")

                // The run loads and checks the room off the main actor, which a loaded host can hold up for seconds.
                let over = await waitUntil(timeoutMs: 30_000) { model.retranscribeRequest == nil }
                #expect(over)
                #expect(model.phase == .failed(message: AppModel.meetingMixUnavailableMessage()))
                #expect(await reads.files.isEmpty, "the engine never got the stereo")
                #expect(model.meetingScratchInUse.isEmpty)
            }
        }

        @Test("Transcribe Again on a meeting lets Parakeet's mono mix go when the run is done, from the disk and from the files in use")
        func retranscribeLetsTheMonoGo() async throws {
            try await withMocksCleared(.transcriber) {
                let library = makeTempLibraryURL("second-track-rerun-mono")
                let stereo = try TestAudio.stereo(leftAmplitude: 0.3, rightAmplitude: 0.3, seconds: 1)
                let seeded = try await LibraryStore(libraryURL: library, extraIndexer: nil).add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Welcome")], language: "en", modelName: "m"
                    ),
                    audioSource: stereo, category: .meeting, source: .systemAudio
                )
                let model = makeModel(libraryURL: library)
                await model.awaitModelListRefresh()
                await installMockTranscriber(segments: [(0, 1, "Welcome back")])
                let reads = EngineReads()
                model.postProcessOperation = { transcript in
                    await reads.note(transcript.sourceURL)
                    return transcript
                }
                _ = try await model.openEntry(seeded.id)

                model.retranscribeCurrentEntry(model: "nvidia_parakeet-tdt-0.6b-v3", language: nil)

                let done = await waitUntil { model.retranscribeRequest == nil && model.phase == .ready }
                #expect(done)
                #expect(await reads.channels == [1])
                let mono = try #require(await reads.files.first)
                #expect(!exists(mono))
                #expect(model.meetingScratchInUse.isEmpty)
            }
        }

        @Test("a mono mix that fails for a reason other than room says what went wrong, not that the disk is full")
        func failedDownmixSaysWhy() async throws {
            try await withMocksCleared(.transcriber) {
                let library = makeTempLibraryURL("second-track-downmix-fails")
                let stereo = try TestAudio.stereo(leftAmplitude: 0.3, rightAmplitude: 0.3, seconds: 1)
                let seeded = try await LibraryStore(libraryURL: library, extraIndexer: nil).add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Welcome")], language: "en", modelName: "m"
                    ),
                    audioSource: stereo, category: .meeting, source: .systemAudio
                )
                let model = makeModel(libraryURL: library)
                await model.awaitModelListRefresh()
                await installMockTranscriber(segments: [(0, 1, "Welcome")])
                _ = try await model.openEntry(seeded.id)
                let folder = try inflight(library)
                try refuseWrites(in: folder)
                defer { try? allowWrites(in: folder) }

                model.retranscribeCurrentEntry(model: "nvidia_parakeet-tdt-0.6b-v3", language: nil)
                let started = model.retranscribeRequest != nil
                #expect(started, "Transcribe Again started a run")

                // The run loads, checks the room and fails its downmix off the main actor, which a loaded host can hold up for seconds.
                let over = await waitUntil(timeoutMs: 30_000) { model.retranscribeRequest == nil }
                #expect(over)
                #expect(runFailed(model))
                #expect(model.phase != .failed(message: AppModel.meetingMixUnavailableMessage()))
            }
        }

        @Test("Restore of a meeting mid-transcription with no room for the mono mix Parakeet needs saves the take untranscribed and says so")
        func restoreWithoutRoomForTheMonoFails() async throws {
            try await withMocksCleared(.transcriber) {
                let library = makeTempLibraryURL("second-track-no-room-restore")
                let take = try inflight(library).appendingPathComponent("parola-system-\(UUID().uuidString).wav")
                try FileManager.default.copyItem(at: try TestAudio.stereo(leftAmplitude: 0.3, rightAmplitude: 0.3, seconds: 1), to: take)
                try age(take, by: 300)
                try writeLegacyCheckpoint(RecoveryCheckpoint(
                    kind: .fileTranscription, startedAt: Date(), modelName: "m", sourceURL: take, title: "Meeting",
                    source: .systemAudio, category: .meeting
                ), library: library)
                let model = makeModel(libraryURL: library)
                await model.awaitModelListRefresh()
                model.selectedModel = "nvidia_parakeet-tdt-0.6b-v3"
                await installMockTranscriber(segments: [(0, 1, "Welcome")])
                let reads = EngineReads()
                model.postProcessOperation = { transcript in
                    await reads.note(transcript.sourceURL)
                    return transcript
                }
                model.freeDiskSpaceProvider = { AppModel.meetingFoldMarginBytes + 1_000 }
                #expect(model.pendingRecovery?.sourceURL == take)

                model.acceptPendingRecovery()

                let entry = try #require(await landedEntry(model))
                let failed = await waitUntil { runFailed(model) }
                #expect(failed)
                let message = AppModel.meetingMixUnavailableMessage() + " " + String(localized: "The audio was saved to your library.")
                #expect(model.phase == .failed(message: message))
                #expect(await reads.files.isEmpty, "the engine never got the stereo")
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
            }
        }

        @Test("the message for a meeting with no room for its mono mix reads in Italian")
        func meetingMixUnavailableReadsInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(AppModel.meetingMixUnavailableMessage(bundle: italian)
                == "Non c'è spazio per preparare questa riunione alla trascrizione. Libera un po' di spazio su disco e riprova.")
        }

        // MARK: - The permission prompt

        @Test("a late Allow on the mic prompt, after the take has stopped, never switches the mic on")
        func lateAllowLeavesTheMicOff() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let files = try meetingFiles(model)
                let prompt = Gate()
                model.micAccessRequest = {
                    await prompt.wait()
                    return true
                }
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let asked = await waitUntil { await prompt.reached }
                #expect(asked)

                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                await prompt.open()
                await settle()

                #expect(await mic.started == false, "the Allow came after the take")
                #expect(model.micTrack == nil)
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 1)
            }
        }

        @Test("a mic the user refuses leaves the take recording the Mac audio, and says so once")
        func refusedPromptSaysSo() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                model.micAccessRequest = { false }
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackMissingMessage())
                #expect(model.takeMicTrackState == .unavailable)
                #expect(await mic.started == false)
                #expect(model.recording?.state == .recording)
                await model.discardTake()
            }
        }

        // MARK: - A wedged input device

        @Test("a mic that won't finish holds Stop back only so long, and what it wrote is still folded in")
        func wedgedFinishDoesNotHoldStop() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                model.micTrackFinishLimit = .milliseconds(300)
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic, wedges: [.prepare])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
                await mic.unwedge()
            }
        }

        @Test("a mic that won't pause can't hold up the Mac audio's pause or resume")
        func wedgedPauseDoesNotHoldTheMac() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                let mic = ScriptedTrack(file: files.mic, wedges: [.pause])
                try await startMeeting(model, mac: mac, mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                #expect(model.pauseTake())
                #expect(model.resumeTake())

                let told = await waitUntil { await mac.pauseCalls == [true, false] }
                #expect(told)
                await mic.unwedge()
                await model.discardTake()
            }
        }

        @Test("Discard doesn't wait for a mic that won't stop, and its file still goes")
        func wedgedCancelDoesNotHoldDiscard() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                model.micTrackFinishLimit = .milliseconds(300)
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic, wedges: [.cancel])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                var discarded = false

                Task { @MainActor in
                    await model.discardTake()
                    discarded = true
                }

                let done = await waitUntil { discarded }
                #expect(done)
                #expect(!exists(files.mic))
                await mic.unwedge()
            }
        }

        // MARK: - A mic that stopped

        @Test("a mic that stalled is lined up, never stretched, so a sound at 10 s stays at 10 s; its checkpoint says it stopped")
        func stalledMicIsNeverStretched() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let library = makeTempLibraryURL("second-track-stalled")
                let model = makeModel(libraryURL: library)
                model.micTrackStallTicks = 3
                let folder = model.inflightRecordingsURL
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let id = UUID().uuidString
                let mac = folder.appendingPathComponent("parola-system-\(id).wav")
                let mic = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(id).wav")
                let rate = 16_000.0
                try TestAudio.write(channels: [TestAudio.sine(seconds: 20, hz: 440, amplitude: 0.3, sampleRate: rate)], sampleRate: rate, to: mac)
                var voice = [Float](repeating: 0, count: Int(19.997 * rate))
                for index in Int(10 * rate)..<Int(10 * rate) + 160 { voice[index] = 0.9 }
                try TestAudio.write(channels: [voice], sampleRate: rate, to: mic)
                let macTrack = ScriptedTrack(file: mac)
                try await startMeeting(model, mac: macTrack, mic: ScriptedTrack(file: mic))
                let micUp = await waitUntil { model.micTrack?.capture != nil }
                #expect(micUp)

                let feeding = Task { @MainActor in
                    for _ in 0..<60 {
                        macTrack.levelMeter.record(0.3)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                let stalled = await waitUntil { model.micTrack?.stoppedEarly == true }
                feeding.cancel()
                #expect(stalled)
                await model.pendingRecoveryWrite?.value
                let live = try checkpointsOnDisk(library)
                #expect(live.first?.companionStopped == true, "a crash now still knows not to stretch it")

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                let sides = try TestAudio.read(audio)
                let burst = sides.channels[1].firstIndex { $0 > 0.5 }
                let onset = try #require(burst)
                #expect(abs(Double(onset) / sides.sampleRate - 10) < 0.001, "lined up as recorded, not stretched by 20/19.997")
            }
        }

        /// A 20 s meeting in the working folder whose mic is `micSeconds` long, with one burst of your voice at 10 s.
        private func meetingWithBurst(in model: AppModel, micSeconds: Double) throws -> (mac: URL, mic: URL) {
            let folder = model.inflightRecordingsURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let mac = folder.appendingPathComponent("parola-system-\(id).wav")
            let mic = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(id).wav")
            let rate = 16_000.0
            try TestAudio.write(channels: [TestAudio.sine(seconds: 20, hz: 440, amplitude: 0.3, sampleRate: rate)], sampleRate: rate, to: mac)
            var voice = [Float](repeating: 0, count: Int(micSeconds * rate))
            for index in Int(10 * rate)..<Int(10 * rate) + 160 { voice[index] = 0.9 }
            try TestAudio.write(channels: [voice], sampleRate: rate, to: mic)
            return (mac, mic)
        }

        /// When your side of the entry first hears the burst, and how long the entry's audio is.
        private func burstAndLength(of entry: LibraryEntry, in model: AppModel) async throws -> (onset: Double, seconds: Double) {
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            let sides = try TestAudio.read(audio)
            let burst = sides.channels[1].firstIndex { $0 > 0.5 }
            let onset = try #require(burst)
            return (Double(onset) / sides.sampleRate, Double(sides.frameCount) / sides.sampleRate)
        }

        @Test("a mic whose last reading trails the Mac audio's by more than half a second at Stop is lined up, not stretched")
        func micTrailingAtStopIsNeverStretched() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let files = try meetingWithBurst(in: model, micSeconds: 19.997)
                let macTrack = ScriptedTrack(file: files.mac)
                let micTrack = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: macTrack, mic: micTrack)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                micTrack.levelMeter.record(0.3, capturedAt: macTrack.levelMeter.firstReadingAt)
                for _ in 0..<16 {
                    macTrack.levelMeter.record(0.3)
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(model.micTrack?.stoppedEarly == false, "too short a gap for the stall watch")

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let mixed = try await burstAndLength(of: entry, in: model)
                #expect(abs(mixed.onset - 10) < 0.001, "lined up as recorded, not stretched by 20/19.997")
            }
        }

        @Test("Stop ends the take with the Mac audio: what the mic heard after it is trimmed, and the rest isn't compressed")
        func stopTrimsTheMicOverrun() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let files = try meetingWithBurst(in: model, micSeconds: 20.2)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let entry = try #require(await landedEntry(model))
                let mixed = try await burstAndLength(of: entry, in: model)
                #expect(abs(mixed.onset - 10) < 0.001)
                #expect(abs(mixed.seconds - 20) < 0.001, "as long as the Mac audio")
            }
        }

        @Test("a meeting whose Mac capture stopped early keeps your whole side, at Stop and when the app quits", arguments: [false, true])
        func macStoppedEarlyKeepsYourSide(quits: Bool) async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let folder = model.inflightRecordingsURL
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let id = UUID().uuidString
                let mac = folder.appendingPathComponent("parola-system-\(id).wav")
                let mic = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(id).wav")
                let rate = 16_000.0
                try TestAudio.write(channels: [TestAudio.sine(seconds: 2, hz: 440, amplitude: 0.3, sampleRate: rate)], sampleRate: rate, to: mac)
                var voice = [Float](repeating: 0, count: Int(10 * rate))
                for index in Int(8 * rate)..<Int(8 * rate) + 160 { voice[index] = 0.9 }
                try TestAudio.write(channels: [voice], sampleRate: rate, to: mic)
                try await startMeeting(model, mac: ScriptedTrack(file: mac), mic: ScriptedTrack(file: mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                if quits {
                    _ = await model.resolveQuitDuringTake(.stopAndSave)
                } else {
                    model.stopRecordingAndTranscribe()
                }

                let entry = try #require(await landedEntry(model))
                let mixed = try await burstAndLength(of: entry, in: model)
                #expect(abs(mixed.onset - 8) < 0.001, "your words after the Mac audio stopped are kept")
                #expect(abs(mixed.seconds - 10) < 0.001, "as long as your side")
            }
        }

        @Test("a meeting whose Mac audio stops by itself goes on with your microphone, says so on its Mac lane and in a notice that stays, and keeps your side")
        func macStopsByItselfMidMeeting() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let server = try ParolaAutomationServer(model: model)
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                try await startMeeting(model, mac: mac, mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                let take = try #require(model.recording?.takeID)
                let older = ExportNotice.Action(title: "Transcribe", handler: .transcribeEntry("an older entry"))
                model.exportNotice = ExportNotice(
                    message: "Saved the previous recording without transcribing it.", failures: [], folder: nil, tone: .info,
                    actions: [older]
                )

                await mac.endByItself()

                let said = await waitUntil { model.takeMacAudioStopped }
                #expect(said)
                #expect(model.recording?.state == .recording)
                #expect(model.micTrack?.capture != nil)
                #expect(!model.takeStoppedOnItsOwn)
                let notice = try #require(model.exportNotice)
                #expect(notice.message == AppModel.macAudioStoppedMessage(), "it outranks the older notice")
                #expect(notice.actions.map(\.handler) == [.showTake(take)])
                #expect(!notice.autoDismisses)
                guard case .object(let state) = server.snapshotState(), case .object(let recording)? = state["recording"] else {
                    throw AutomationError.precondition("getState has no recording")
                }
                #expect(recording["macAudioStopped"] == .bool(true))
                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
                withExtendedLifetime(server) {}
            }
        }

        @Test("a Mac-audio take with nothing else recording stops when its capture ends by itself, lands, and says so until dismissed")
        func macStopsByItselfAlone() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "the Mac side")])
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                try await startMeeting(model, mac: mac, mic: nil, category: .transcription)

                await mac.endByItself()

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.macAudioStoppedTakeMessage())
                #expect(notice?.tone == .failure)
                #expect(notice?.autoDismisses == false)
                #expect(model.takeMacAudioStopped)
                #expect(model.takeStoppedOnItsOwn)
                let entry = try #require(await landedEntry(model))
                #expect(entry.title.contains("(") == false, "it lands as Stop lands it")
                #expect(!model.recordingActive)
                #expect(model.exportNotice?.message == AppModel.macAudioStoppedTakeMessage(), "still up once the take has landed")
            }
        }

        @Test("a Mac-audio take whose capture ends before it heard anything ends with nothing saved, and says why")
        func macStopsBeforeItHeardAnything() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                await model.awaitModelListRefresh()
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                model.meetingRecordsMicrophone = false
                model.takeCaptureOverride = { _ in mac }
                model.startRecording(source: .systemAudio)
                let up = await waitUntil { model.liveSource != nil }
                #expect(up)
                let take = try #require(model.recording?.takeID)
                model.goHome()

                await mac.endByItself()

                let failed = await waitUntil { model.recording?.state == .failed(message: AppModel.macAudioStoppedBeforeSoundMessage()) }
                #expect(failed)
                #expect(model.takeStoppedOnItsOwn)
                #expect(model.exportNotice?.message == AppModel.macAudioStoppedBeforeSoundMessage())
                #expect(model.exportNotice?.actions.map(\.handler) == [.showTake(take)])
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
                await settle()
                #expect(await model.library.list().isEmpty)
            }
        }

        // MARK: - Room for the fold

        @Test("a meeting recording its mic stops while its fold still fits on disk, and a take without one keeps going")
        func guardReservesTheFold() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let files = try meetingFiles(model)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                let foldBytes = await AppModel.foldBytes(mac: files.mac, mic: files.mic, mono: false)
                #expect(foldBytes > 0)
                model.freeDiskSpaceProvider = { AppModel.diskSpaceRefuseFloorBytes + foldBytes / 2 }

                await model.checkRecordingDiskSpace()

                #expect(model.recording?.isCapturing == false, "stopped while the fold still fits")
                let landed = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(landed.id).document.audioURL)
                #expect(try channels(of: audio) == 2, "and the fold did fit")

                let plain = makeModel()
                let plainFiles = try meetingFiles(plain)
                try await startMeeting(plain, mac: ScriptedTrack(file: plainFiles.mac), mic: nil, category: .transcription)
                plain.freeDiskSpaceProvider = { AppModel.diskSpaceRefuseFloorBytes + foldBytes / 2 }
                await plain.checkRecordingDiskSpace()
                #expect(plain.recording?.isCapturing == true, "no fold to make room for")
                await plain.discardTake()
            }
        }

        @Test("the room a meeting keeps doubles for an engine that needs a mono mix")
        func reserveFollowsTheEngine() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                let whisper = await model.meetingFoldReserve()
                model.selectedModel = "nvidia_parakeet-tdt-0.6b-v3"
                let parakeet = await model.meetingFoldReserve()

                #expect(whisper > 0)
                #expect(parakeet == 2 * whisper)
                await model.discardTake()
            }
        }

        @Test("with no room for the fold at Stop, nothing is mixed and the mic waits for the next launch")
        func noRoomLeavesTheMicWaiting() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let library = makeTempLibraryURL("second-track-no-room")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.freeDiskSpaceProvider = { AppModel.meetingFoldMarginBytes + 1_000 }

                model.stopRecordingAndTranscribe()

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackKeptMessage())
                let entry = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 1)
                let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
                #expect(recorded)
                #expect(exists(files.mic))
                #expect(mixLeftovers(library).isEmpty, "no half-written mix")

                model.recoveryOwner = nil
                try await expectLaterFold(library: library, entry: entry.id, mic: files.mic)
            }
        }

        @Test("Stop, then Stop Transcribing, saves the meeting untranscribed with both sides")
        func stopTranscribingKeepsTheMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                let files = try meetingFiles(model)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.takeRun != nil }
                #expect(transcribing)

                model.stopTranscribingTake()

                let entry = try #require(await landedEntry(model))
                #expect(entry.title.hasSuffix("(not transcribed)"))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
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

        @Test("Cancel leaves a meeting's microphone recording with its take")
        func cancelKeepsTheMic() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.cancelCurrentWork()
                await settle(for: .milliseconds(300))

                #expect(await mic.cancelled == false)
                #expect(model.micTrack?.capture != nil)
                #expect(model.liveCompanionAudioURL == files.mic)
                #expect(model.recording?.state == .recording)
                await model.discardTake()
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
                #expect(model.takeMicTrackState == .stopped)
                await model.discardTake()
            }
        }

        @Test("a microphone that stops after the Mac audio did is noticed too, and with nothing left recording the take stops and lands")
        func micStopsAfterTheMacAudio() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                model.micTrackStallTicks = 3
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: mac, mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                for _ in 0..<6 {
                    mac.levelMeter.record(0.3)
                    mic.levelMeter.record(0.2)
                    try await Task.sleep(for: .milliseconds(50))
                }
                await mac.endByItself()
                let macGone = await waitUntil { model.takeMacAudioStopped }
                #expect(macGone)
                for _ in 0..<6 {
                    mic.levelMeter.record(0.2)
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(model.recording?.state == .recording, "your microphone still records")

                let stopped = await waitUntil { model.exportNotice?.message == AppModel.micTrackStoppedTooMessage() }

                #expect(stopped)
                #expect(model.exportNotice?.tone == .failure)
                #expect(model.takeMicTrackState == .stopped)
                #expect(model.takeStoppedOnItsOwn)
                let entry = try #require(await landedEntry(model))
                #expect(entry.title.contains("(") == false)
                #expect(!model.recordingActive)
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
                await model.discardTake()
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

        // MARK: - A fold that fails

        /// What a mic file holds when the mix can't read it: no header, but plenty of bytes.
        private func corrupt(_ file: URL) throws {
            try Data(repeating: 0x5A, count: 64 * 1024).write(to: file)
        }

        /// The mic readable again, as it is when the space or the device that failed the fold comes back.
        private func repairMic(_ file: URL) throws {
            let rate = 16_000.0
            let quiet = [Float](repeating: 0, count: Int(rate))
            try TestAudio.write(channels: [quiet + TestAudio.sine(seconds: 1, hz: 220, amplitude: 0.4, sampleRate: rate)], sampleRate: rate, to: file)
        }

        private func micRecords(_ library: URL) throws -> [RecoveryCheckpoint] {
            try checkpointsOnDisk(library).filter { $0.kind == .micTrack }
        }

        /// The next launch folds the waiting mic into the entry, labels your side, and lets the record and the mic go.
        private func expectLaterFold(library: URL, entry: LibraryEntry.ID, mic: URL) async throws {
            try repairMic(mic)
            let relaunched = makeModel(libraryURL: library)
            await relaunched.micTrackFolds?.value
            let stored = try await relaunched.library.load(entry).document
            let audio = try #require(stored.audioURL)
            #expect(try channels(of: audio) == 2, "the next launch folds the mic in")
            let speakers = stored.transcript.segments.map(\.speaker)
            if speakers.count == 2 { #expect(speakers == [nil, AppModel.meLabel()]) }
            #expect(!exists(mic))
            #expect(try micRecords(library).isEmpty)
            #expect(await relaunched.library.list().count == 1)
        }

        @Test("a fold that fails at Stop keeps your mic: the take lands with the Mac side, a record names the mic, and the next launch folds it in")
        func failedFoldAtStopKeepsTheMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let library = makeTempLibraryURL("second-track-fold-fails")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                try corrupt(files.mic)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone."), (1, 2, "Thanks, glad to be here")])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                let takeID = try #require(model.recording?.takeID)

                model.stopRecordingAndTranscribe()

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackKeptMessage())
                #expect(notice?.takeID == takeID, "the notice is about this take, and goes with it")
                let entry = try #require(await landedEntry(model))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 1, "the Mac side is saved at once")
                let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
                #expect(recorded)
                let records = try micRecords(library)
                #expect(records.count == 1)
                #expect(records.first?.companionAudioURL == files.mic)
                #expect(records.first?.entryID == entry.id)
                #expect(exists(files.mic))
                #expect(model.inflightFileInUse(files.mic))

                model.recoveryOwner = nil
                try await expectLaterFold(library: library, entry: entry.id, mic: files.mic)
            }
        }

        @Test("a mic folded into an entry that already has a transcript says your words aren't in it yet, and Transcribe Again adds them; nothing runs on its own")
        func lateFoldOffersTranscribeAgain() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let library = makeTempLibraryURL("second-track-late-fold")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                try corrupt(files.mic)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
                #expect(recorded)
                model.recoveryOwner = nil
                try repairMic(files.mic)

                let relaunched = makeModel(libraryURL: library)
                await relaunched.awaitModelListRefresh()
                relaunched.selectedModel = "openai_whisper-tiny"
                await relaunched.micTrackFolds?.value

                let notice = try #require(relaunched.exportNotice)
                #expect(notice.message == AppModel.micTrackAddedMessage(title: entry.title))
                let handlers = notice.actions.map(\.handler)
                #expect(handlers == [.transcribeEntry(entry.id)])
                #expect(notice.actions.first?.title == String(localized: "Transcribe Again"))
                #expect(relaunched.retranscribeRequest == nil, "nothing runs again until asked")
                let kept = try await relaunched.library.load(entry.id).document.transcript.segments.count
                #expect(kept == 1)

                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone."), (1, 2, "Thanks, glad to be here")])
                let action = try #require(notice.actions.first)
                relaunched.performNoticeAction(action)

                var speakers: [String?] = []
                let rerun = await waitUntil {
                    speakers = (try? await relaunched.library.load(entry.id).document.transcript.segments.map(\.speaker)) ?? []
                    return speakers.count == 2
                }
                #expect(rerun)
                #expect(speakers == [nil, AppModel.meLabel()])
            }
        }

        @Test("the notice for a mic added late reads in Italian")
        func micTrackAddedReadsInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(AppModel.micTrackAddedMessage(title: "Riunione", bundle: italian)
                == "La traccia del tuo microfono è stata aggiunta a “Riunione”. Trascrivi di nuovo per includere le tue parole.")
        }

        /// A launch on `library` once its folds of waiting mics are done; it lets go of the library for the next one.
        private func launch(_ library: URL) async -> AppModel {
            let model = makeModel(libraryURL: library)
            await model.micTrackFolds?.value
            model.recoveryOwner = nil
            return model
        }

        @Test("a waiting mic that keeps failing to mix says so once, at the third failed mix, with Reveal in Finder, and is still tried quietly; no room doesn't count")
        func failingMicSaysSoOnce() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let library = makeTempLibraryURL("second-track-keeps-failing")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                try corrupt(files.mic)
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model))
                let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
                #expect(recorded)
                #expect(try micRecords(library).first?.companionFailedMixes == 1, "the mix at Stop counts")
                model.recoveryOwner = nil

                let second = await launch(library)
                #expect(second.exportNotice == nil)
                #expect(try micRecords(library).first?.companionFailedMixes == 2)

                let tight = makeModel(libraryURL: library)
                tight.freeDiskSpaceProvider = { AppModel.meetingFoldMarginBytes + 1_000 }
                await tight.micTrackFolds?.value
                tight.recoveryOwner = nil
                #expect(try micRecords(library).first?.companionFailedMixes == 2, "no room isn't a failed mix")

                let third = await launch(library)
                let notice = try #require(third.exportNotice)
                #expect(notice.message == AppModel.micTrackUnfoldableMessage(title: entry.title))
                let handlers = notice.actions.map(\.handler)
                #expect(handlers == [.revealFile(files.mic)])
                #expect(notice.actions.first?.title == String(localized: "Reveal in Finder"))

                let fourth = await launch(library)
                #expect(fourth.exportNotice == nil, "said once")
                #expect(exists(files.mic))
                #expect(try micRecords(library).first?.companionFailedMixes == 4)

                try await expectLaterFold(library: library, entry: entry.id, mic: files.mic)
            }
        }

        @Test("the notice for a mic that keeps failing, and its button, read in Italian")
        func micTrackUnfoldableReadsInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(AppModel.micTrackUnfoldableMessage(title: "Riunione", bundle: italian)
                == "Parola non è riuscita ad aggiungere la traccia del tuo microfono a “Riunione”.")
            #expect(String(localized: "Reveal in Finder", bundle: italian) == "Mostra nel Finder")
        }

        @Test("a failed fold's notice for a take let go by Cancel while a new one records stays up, still about its own take")
        func keptNoticeOutlivesTheNextTake() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                model.micTrackFinishLimit = .seconds(2)
                let first = try meetingFiles(model)
                try corrupt(first.mic)
                let wedged = ScriptedTrack(file: first.mic, wedges: [.prepare])
                try await startMeeting(model, mac: ScriptedTrack(file: first.mac), mic: wedged)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                let firstTake = try #require(model.recording?.takeID)
                model.stopRecordingAndTranscribe()
                model.cancelCurrentWork()

                let second = try meetingFiles(model)
                try await startMeeting(model, mac: ScriptedTrack(file: second.mac), mic: ScriptedTrack(file: second.mic))
                let secondTake = try #require(model.recording?.takeID)
                #expect(secondTake != firstTake)

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackKeptMessage())
                #expect(notice?.takeID == firstTake)
                #expect(model.pauseTake())
                #expect(model.exportNotice?.message == AppModel.micTrackKeptMessage(), "the next take's session doesn't sweep it away")
                await model.discardTake()
                await wedged.unwedge()
            }
        }

        @Test("a fold whose hand-over the disk refuses keeps the take file as recorded and your mic for the next launch")
        func refusedHandOverKeepsTheMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let library = makeTempLibraryURL("second-track-hand-over-refused")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                let folder = model.inflightRecordingsURL
                model.foldStepHook = { step in
                    if step == .mixed { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
                    return true
                }
                defer { try? allowWrites(in: folder) }
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackKeptMessage())
                let entry = try #require(await landedEntry(model))
                let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
                #expect(recorded)
                try allowWrites(in: folder)
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 1)
                #expect(try channels(of: files.mac) == 1, "the take file is as it was recorded")
                #expect(exists(files.mic))
                #expect(try micRecords(library).count == 1)

                model.recoveryOwner = nil
                try await expectLaterFold(library: library, entry: entry.id, mic: files.mic)
            }
        }

        @Test("a waiting mic whose entry was purged goes at the next launch, with its record; one in Recently Deleted is still folded in, quietly")
        func purgedEntryLetsItsMicGo() async throws {
            let library = makeTempLibraryURL("second-track-purged")
            let files = try crashedMeeting(in: library, age: 3_600)
            try corrupt(files.mic)
            try age(files.mic, by: 3_600)
            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value
            let entry = try #require(await landedEntry(model))
            let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
            #expect(recorded)

            _ = try await model.library.mutateTranscript(for: entry.id) { transcript in
                transcript.segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "Welcome, everyone.")]
            }
            try await model.library.delete(entry.id)
            try repairMic(files.mic)
            model.recoveryOwner = nil
            let second = makeModel(libraryURL: library)
            await second.micTrackFolds?.value
            let deleted = try await second.library.load(entry.id)
            #expect(deleted.entry.manifest.deletedAt != nil)
            let deletedAudio = try #require(deleted.document.audioURL)
            #expect(try channels(of: deletedAudio) == 2, "Recently Deleted keeps the whole meeting")
            #expect(!exists(files.mic))
            #expect(second.exportNotice == nil, "no Transcribe Again for a transcript in Recently Deleted")

            let purgedLibrary = makeTempLibraryURL("second-track-purged-gone")
            let gone = try crashedMeeting(in: purgedLibrary, age: 3_600)
            try corrupt(gone.mic)
            try age(gone.mic, by: 3_600)
            let first = makeModel(libraryURL: purgedLibrary)
            await first.inflightSweep?.value
            let doomed = try #require(await landedEntry(first))
            let waiting = await waitUntil { first.micTrackRecords[doomed.id] != nil }
            #expect(waiting)
            try await first.library.delete(doomed.id)
            try await first.library.purge(doomed.id)
            #expect(exists(gone.mic), "kept until a launch finds the entry gone")
            first.recoveryOwner = nil

            let next = makeModel(libraryURL: purgedLibrary)
            await next.micTrackFolds?.value
            await next.inflightSweep?.value
            #expect(!exists(gone.mic))
            #expect(try micRecords(purgedLibrary).isEmpty)
        }

        @Test("while a take whose fold failed is transcribing, its checkpoint still names your mic")
        func failedFoldRunCarriesTheMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let library = makeTempLibraryURL("second-track-fold-fails-run")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                try corrupt(files.mic)
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")], gate: gate)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)

                model.stopRecordingAndTranscribe()

                let running = await waitUntil { model.takeRun != nil }
                #expect(running)
                await model.pendingRecoveryWrite?.value
                let checkpoints = try checkpointsOnDisk(library)
                #expect(checkpoints.count == 1)
                #expect(checkpoints.first?.kind == .fileTranscription)
                #expect(checkpoints.first?.companionAudioURL == files.mic, "a crash now still brings the mic back")
                await gate.open()
                let entry = try #require(await landedEntry(model))
                let recorded = await waitUntil { model.micTrackRecords[entry.id] != nil }
                #expect(recorded)
            }
        }

        @Test("a fold that fails on Restore keeps your mic beside the restored take, and the next launch folds it in")
        func failedFoldOnRestoreKeepsTheMic() async throws {
            let library = makeTempLibraryURL("second-track-restore-fails")
            let files = try crashedMeeting(in: library)
            try corrupt(files.mic)
            try age(files.mic, by: 300)
            try writeLegacyCheckpoint(meetingCheckpoint(files), library: library)
            let model = makeModel(libraryURL: library)

            model.acceptPendingRecovery()

            let notice = await waitForNotice(model)
            #expect(notice?.message == AppModel.micTrackKeptMessage())
            let entry = try #require(await landedEntry(model))
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 1)
            let recorded = await waitUntil { (try? micRecords(library).count) == 1 }
            #expect(recorded)
            #expect(try micRecords(library).first?.entryID == entry.id)
            #expect(exists(files.mic))

            model.recoveryOwner = nil
            try await expectLaterFold(library: library, entry: entry.id, mic: files.mic)
        }

        @Test("a mix the sweep can't make brings the Mac side back and keeps your mic for it, never deleting the mic")
        func failedFoldInTheSweepKeepsTheMic() async throws {
            let library = makeTempLibraryURL("second-track-sweep-fails")
            let files = try crashedMeeting(in: library, age: 3_600)
            try corrupt(files.mic)
            try age(files.mic, by: 3_600)
            let model = makeModel(libraryURL: library)

            await model.inflightSweep?.value

            let entry = try #require(await landedEntry(model))
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 1)
            #expect(exists(files.mic), "the mic stays when the mix fails")
            #expect(try micRecords(library).first?.entryID == entry.id)

            model.recoveryOwner = nil
            try await expectLaterFold(library: library, entry: entry.id, mic: files.mic)
        }

        /// A folder that refuses new files and removals, as a full or failing disk does, until it is handed back.
        private func refuseWrites(in folder: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }

        private func allowWrites(in folder: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }

        @Test("a mic record that can't be written at the save leaves the take's checkpoint and its copy, so the next launch gives the mic to the entry")
        func unwrittenRecordAtStopKeepsTheTake() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let library = makeTempLibraryURL("second-track-record-refused")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                try corrupt(files.mic)
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")], gate: gate)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.stopRecordingAndTranscribe()
                let running = await waitUntil { model.takeRun != nil }
                #expect(running)
                await model.pendingRecoveryWrite?.value
                let recovery = model.recoveryDirectoryURL
                try refuseWrites(in: recovery)
                defer { try? allowWrites(in: recovery) }

                await gate.open()

                let entry = try #require(await landedEntry(model))
                let settled = await waitUntil { !model.hasPendingTakeWork }
                #expect(settled)
                try allowWrites(in: recovery)
                #expect(exists(files.mac), "the take's copy stays, named by its checkpoint")
                #expect(exists(files.mic))
                let namesTheMic = try checkpointsOnDisk(library).contains { $0.kind == .fileTranscription && $0.companionAudioURL == files.mic }
                #expect(namesTheMic)

                model.recoveryOwner = nil
                try repairMic(files.mic)
                for file in [files.mac, files.mic] { try age(file, by: 49 * 3_600) }
                let relaunched = makeModel(libraryURL: library)
                relaunched.declinePendingRecovery()
                let folded = await waitUntil {
                    guard let audio = try? await relaunched.library.load(entry.id).document.audioURL else { return false }
                    return (try? channels(of: audio)) == 2
                }
                #expect(folded, "the next launch folds the mic into the entry its take was saved as")
                #expect(await relaunched.library.list().count == 1)
                let released = await waitUntil { !exists(files.mic) && ((try? micRecords(library).isEmpty) ?? false) }
                #expect(released)
            }
        }

        @Test("a mic record the sweep can't write keeps the take's copy beside the mic, so a later launch gives the mic to the entry")
        func unwrittenSweepRecordKeepsThePair() async throws {
            let library = makeTempLibraryURL("second-track-sweep-record-refused")
            let files = try crashedMeeting(in: library, age: 3_600)
            try corrupt(files.mic)
            try age(files.mic, by: 3_600)
            let recovery = library.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery.appendingPathComponent("owners", isDirectory: true), withIntermediateDirectories: true)
            try refuseWrites(in: recovery)
            defer { try? allowWrites(in: recovery) }
            let model = makeModel(libraryURL: library)

            await model.inflightSweep?.value

            let entry = try #require(await landedEntry(model))
            try allowWrites(in: recovery)
            #expect(exists(files.mac), "the take's copy stays to pair with the mic")
            #expect(exists(files.mic))
            #expect(try micRecords(library).isEmpty)

            model.recoveryOwner = nil
            try repairMic(files.mic)
            for file in [files.mac, files.mic] { try age(file, by: 49 * 3_600) }
            let relaunched = makeModel(libraryURL: library)
            await relaunched.inflightSweep?.value
            let audio = try #require(try await relaunched.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
            #expect(await relaunched.library.list().count == 1)
            #expect(!exists(files.mic))
            #expect(!exists(files.mac))
            #expect(try micRecords(library).isEmpty)
        }

        @Test("a crash between the sweep's import and its mic record still gives the mic to that entry at the next launch")
        func crashAfterTheSweepsImportKeepsTheMic() async throws {
            let library = makeTempLibraryURL("second-track-sweep-crash")
            let files = try crashedMeeting(in: library, age: 3_600)
            let imported = try await LibraryStore(libraryURL: library, extraIndexer: nil).add(
                transcript: AppModel.untranscribedTranscript(of: files.mac, language: nil), audioSource: files.mac,
                category: .meeting, title: "Meeting (recovered)", source: .systemAudio
            )
            for file in [files.mac, files.mic] { try age(file, by: 3_600) }
            let model = makeModel(libraryURL: library)

            await model.inflightSweep?.value

            let audio = try #require(try await model.library.load(imported.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
            #expect(await model.library.list().count == 1)
            #expect(!exists(files.mic))
            #expect(!exists(files.mac))
            #expect(try micRecords(library).isEmpty)
        }

        @Test("a crashed meeting whose take already reached the library gets its mic folded into that entry, with no twin")
        func micJoinsTheEntryAlreadySaved() async throws {
            let library = makeTempLibraryURL("second-track-entry-holds")
            let files = try crashedMeeting(in: library)
            let seeded = try await LibraryStore(libraryURL: library, extraIndexer: nil).add(
                transcript: AppModel.untranscribedTranscript(of: files.mac, language: nil), audioSource: files.mac,
                category: .meeting, source: .systemAudio
            )
            try writeLegacyCheckpoint(meetingCheckpoint(files), library: library)
            let model = makeModel(libraryURL: library)

            model.declinePendingRecovery()

            let folded = await waitUntil {
                guard let audio = try? await model.library.load(seeded.id).document.audioURL else { return false }
                return (try? channels(of: audio)) == 2
            }
            #expect(folded)
            #expect(await model.library.list().count == 1)
            let gone = await waitUntil { !exists(files.mic) && model.recoveryCheckpointFiles.isEmpty }
            #expect(gone)
        }

        @Test("Retry folds a waiting mic in before it runs again, so your side is labelled Me")
        func retryFoldsTheWaitingMic() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeModel()
                let files = try meetingFiles(model)
                try corrupt(files.mic)
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
                #expect(model.micTrackRecords[saved.id] != nil)

                try repairMic(files.mic)
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
                let audio = try #require(try await model.library.load(saved.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
                #expect(model.micTrackRecords[saved.id] == nil)
                #expect(!exists(files.mic))
            }
        }

        @Test("the notice for a mic that waits reads in Italian")
        func micTrackKeptReadsInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(AppModel.micTrackKeptMessage(bundle: italian)
                == "La traccia del tuo microfono non è ancora stata aggiunta a questa registrazione. Parola la conserva e riprova alla prossima apertura.")
        }

        // MARK: - The You meter

        @Test("a meeting take keeps your microphone's levels beside the Mac audio's, sample for sample")
        func micLevelsBesideMacLevels() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac)
                let mic = ScriptedTrack(file: files.mic, holdsStart: true)
                try await startMeeting(model, mac: mac, mic: mic)
                #expect(model.takeMicTrackState == .starting)
                for _ in 0..<5 {
                    mac.levelMeter.record(0.2)
                    try await Task.sleep(for: .milliseconds(60))
                }
                let macHeard = await waitUntil { (model.takeLevels?.sampleCount ?? 0) >= 3 }
                #expect(macHeard)

                await mic.letStart()
                let up = await waitUntil { model.takeMicTrackState == .recording }
                #expect(up)
                for _ in 0..<6 {
                    mac.levelMeter.record(0.2)
                    mic.levelMeter.record(0.8)
                    try await Task.sleep(for: .milliseconds(60))
                }

                let levels = try #require(model.takeLevels)
                let micLevels = try #require(model.takeMicLevels)
                #expect(micLevels.sampleCount == levels.sampleCount, "one series per meter, lined up")
                let mine = micLevels.recent(micLevels.sampleCount)
                #expect(mine.first == 0, "flat until your microphone came up")
                #expect(mine.contains(0.8))
                #expect(!levels.recent(levels.sampleCount).contains(0.8))
                model.stopRecordingAndTranscribe()
                #expect(model.takeMicTrackState == nil)
            }
        }

        @Test("a microphone track that starts once the Mac audio is already sampled is padded to line up with it")
        func lateMicLevelsLineUp() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeModel()
                let files = try meetingFiles(model)
                let mac = ScriptedTrack(file: files.mac, holdsInFlightRead: true)
                let mic = ScriptedTrack(file: files.mic)
                model.useStreaming = false
                model.takeCaptureOverride = { _ in mac }
                model.micTrackCaptureOverride = { mic }
                model.pendingRecordingCategory = .meeting
                model.startRecording(source: .systemAudio)
                for _ in 0..<5 {
                    mac.levelMeter.record(0.2)
                    try await Task.sleep(for: .milliseconds(60))
                }
                let sampled = await waitUntil { (model.takeLevels?.sampleCount ?? 0) >= 2 }
                #expect(sampled)
                #expect(model.takeMicLevels == nil)

                await mac.letInFlightRead()

                let up = await waitUntil { model.takeMicTrackState == .recording }
                #expect(up)
                let levels = try #require(model.takeLevels)
                let micLevels = try #require(model.takeMicLevels)
                #expect(micLevels.sampleCount == levels.sampleCount)
                await model.discardTake()
            }
        }

        @Test("the You meter's state: unavailable for a refused microphone, gone with the take, and none for a take without one")
        func micTrackStates() async throws {
            try await withMocksCleared(.audioSource) {
                let refusedModel = makeModel()
                let files = try meetingFiles(refusedModel)
                let refusedMic = ScriptedTrack(file: files.mic, startFailure: ParolaError.captureUnavailable("microphone not available"))
                try await startMeeting(refusedModel, mac: ScriptedTrack(file: files.mac), mic: refusedMic)
                let refused = await waitUntil { refusedModel.takeMicTrackState == .unavailable }
                #expect(refused)
                #expect(refusedModel.takeMicLevels != nil, "the meter stays, flat")
                await refusedModel.discardTake()
                #expect(refusedModel.takeMicTrackState == nil)
                #expect(refusedModel.takeMicLevels == nil)

                let plain = makeModel()
                let plainFiles = try meetingFiles(plain)
                try await startMeeting(plain, mac: ScriptedTrack(file: plainFiles.mac), mic: nil, category: .transcription)
                #expect(plain.takeMicTrackState == nil)
                #expect(plain.takeMicLevels == nil)
                await plain.discardTake()
            }
        }

        // MARK: - The fold's hand-over

        /// Stops a meeting's fold after `step`, as a crash there would, and hands back the take's files and its library.
        private func meetingCrashedAfter(_ step: FoldStep) async throws -> (library: URL, files: (mac: URL, mic: URL)) {
            let library = makeTempLibraryURL("second-track-crash")
            let model = makeModel(libraryURL: library)
            let files = try meetingFiles(model)
            var stoppedAt: FoldStep?
            model.foldStepHook = { reached in
                guard reached == step else { return true }
                stoppedAt = reached
                return false
            }
            try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
            let micUp = await waitForMicTrack(model)
            guard micUp else { throw FixtureTakeDidNotStart() }
            model.stopRecordingAndTranscribe()
            let stopped = await waitUntil { stoppedAt == step }
            guard stopped else { throw FixtureTakeDidNotStart() }
            model.recoveryOwner = nil
            for file in try FileManager.default.contentsOfDirectory(at: model.inflightRecordingsURL, includingPropertiesForKeys: nil) {
                try age(file, by: 3_600)
            }
            return (library, files)
        }

        private func checkpointsOnDisk(_ library: URL) throws -> [RecoveryCheckpoint] {
            let folder = library.appendingPathComponent("recovery", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return try files.filter { $0.pathExtension == "json" }.map {
                try JSONDecoder().decode(RecoveryCheckpoint.self, from: try Data(contentsOf: $0))
            }
        }

        /// The Mac talks in the first second and you in the second: a take folded twice would carry your voice on the left too.
        private func expectOneFoldedMeeting(_ model: AppModel, files: (mac: URL, mic: URL)) async throws {
            let entry = try #require(await landedEntry(model))
            await model.inflightSweep?.value
            model.sweepInflightRecordings()
            await model.inflightSweep?.value
            #expect(await model.library.list().count == 1, "one meeting, never a twin")
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            let sides = try TestAudio.read(audio)
            #expect(sides.channels.count == 2)
            #expect(sides.rms(channel: 0, from: 0.1, to: 0.9) > 0.2, "the Mac side")
            #expect(sides.rms(channel: 0, from: 1.1, to: 1.9) < 0.01, "your voice is on your side only")
            #expect(sides.rms(channel: 1, from: 1.1, to: 1.9) > 0.2, "your side")
            let micGone = await waitUntil { !exists(files.mic) }
            #expect(micGone)
        }

        @Test("a crash after any step of the fold leaves one meeting, which the next launch restores with both sides", arguments: FoldStep.allCases)
        func crashAtAnyFoldStepRestoresOneMeeting(_ step: FoldStep) async throws {
            try await withMocksCleared(.audioSource) {
                let crashed = try await meetingCrashedAfter(step)

                let relaunched = makeModel(libraryURL: crashed.library)
                #expect(relaunched.pendingRecovery?.audioURL == crashed.files.mac, "the checkpoint still names the take's own file")
                relaunched.acceptPendingRecovery()

                try await expectOneFoldedMeeting(relaunched, files: crashed.files)
                let cleared = await waitUntil { relaunched.recoveryCheckpointFiles.isEmpty }
                #expect(cleared)
            }
        }

        @Test("a crash once the mix has taken the take's place leaves a meeting that Not Now keeps once, folded once")
        func notNowAfterAHandOverKeepsOneMeeting() async throws {
            try await withMocksCleared(.audioSource) {
                let crashed = try await meetingCrashedAfter(.handedOver)
                #expect(try channels(of: crashed.files.mac) == 2, "the take's own file is the mix now")

                let relaunched = makeModel(libraryURL: crashed.library)
                relaunched.declinePendingRecovery()

                try await expectOneFoldedMeeting(relaunched, files: crashed.files)
            }
        }

        @Test("a crash after the mix took the take's place, with its checkpoint lost, gives the sweep one meeting to bring back")
        func sweepAfterAHandOverKeepsOneMeeting() async throws {
            try await withMocksCleared(.audioSource) {
                let crashed = try await meetingCrashedAfter(.handedOver)
                for file in try FileManager.default.contentsOfDirectory(
                    at: crashed.library.appendingPathComponent("recovery", isDirectory: true), includingPropertiesForKeys: nil
                ) where file.pathExtension == "json" {
                    try FileManager.default.removeItem(at: file)
                }
                let relaunched = makeModel(libraryURL: crashed.library)
                #expect(relaunched.pendingRecovery == nil)

                try await expectOneFoldedMeeting(relaunched, files: crashed.files)
            }
        }

        @Test("once the mix has the take's place, its checkpoint names that one file and no microphone track")
        func foldRewritesTheCheckpoint() async throws {
            try await withMocksCleared(.audioSource) {
                let crashed = try await meetingCrashedAfter(.micReleased)

                let checkpoints = try checkpointsOnDisk(crashed.library)
                #expect(checkpoints.count == 1)
                #expect(checkpoints.first?.audioURL == crashed.files.mac)
                #expect(checkpoints.first?.companionAudioURL == nil)
                #expect(!exists(crashed.files.mic))
            }
        }

        @Test("Cancel while a meeting folds leaves its checkpoint on disk until the take is saved, with both sides")
        func cancelDuringTheFoldKeepsTheCheckpoint() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let library = makeTempLibraryURL("second-track-cancel-fold")
                let model = makeModel(libraryURL: library)
                let files = try meetingFiles(model)
                let gate = Gate()
                model.foldStepHook = { step in
                    if step == .mixed { await gate.wait() }
                    return true
                }
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: ScriptedTrack(file: files.mic))
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                model.stopRecordingAndTranscribe()
                let folding = await waitUntil { await gate.reached }
                #expect(folding)

                model.cancelCurrentWork()

                let held = try checkpointsOnDisk(library)
                #expect(held.count == 1, "the meeting's checkpoint stays while it folds")
                #expect(held.first?.companionAudioURL == files.mic)
                await gate.open()
                let entry = try #require(await landedEntry(model))
                #expect(entry.title.hasSuffix("(not transcribed)"))
                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(try channels(of: audio) == 2)
                let cleared = await waitUntil { model.recoveryCheckpointFiles.isEmpty }
                #expect(cleared)
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
            #expect(entry.category == .meeting, "a take with a mic beside it was a meeting")
            #expect(entry.title.hasPrefix("Meeting"))
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            #expect(try channels(of: audio) == 2)
            #expect(!exists(files.mac) && !exists(files.mic))
            #expect(mixLeftovers(library).isEmpty)
            #expect(exists(orphan), "an orphaned track goes only after two days")
            #expect(AppModel.pairedMeetingMic(for: files.mac, in: [(orphan, Date()), (files.mic, Date())]) == files.mic)
        }

        @Test("the sweep places an orphaned mic where the note beside it says it started, and lets the note go with it")
        func sweepPlacesTheMicByItsNote() async throws {
            let library = makeTempLibraryURL("second-track-sweep-note")
            let folder = try inflight(library)
            let id = UUID().uuidString
            let mac = folder.appendingPathComponent("parola-system-\(id).wav")
            let mic = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(id).wav")
            let rate = 16_000.0
            try TestAudio.write(channels: [TestAudio.sine(seconds: 2, hz: 440, amplitude: 0.3, sampleRate: rate)], sampleRate: rate, to: mac)
            var voice = [Float](repeating: 0, count: Int(1.5 * rate))
            for index in Int(0.2 * rate)..<Int(0.2 * rate) + 160 { voice[index] = 0.9 }
            try TestAudio.write(channels: [voice], sampleRate: rate, to: mic)
            try JSONEncoder().encode(MicTrackNote(offset: 0.5, stoppedEarly: false)).write(to: MicTrackNote.url(for: mic))
            let strayNote = folder.appendingPathComponent("\(RecordingScratch.meetingMicPrefix)-\(UUID().uuidString).json")
            try Data("{}".utf8).write(to: strayNote)
            for file in [mac, mic] { try age(file, by: 3_600) }

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let entry = try #require(await landedEntry(model))
            let audio = try #require(try await model.library.load(entry.id).document.audioURL)
            let sides = try TestAudio.read(audio)
            let burst = sides.channels[1].firstIndex { $0 > 0.5 }
            let onset = try #require(burst)
            #expect(abs(Double(onset) / sides.sampleRate - 0.7) < 0.001, "half a second in, where the mic started")
            #expect(!exists(mic))
            #expect(!exists(MicTrackNote.url(for: mic)))
            #expect(!exists(strayNote), "a note whose mic is gone goes too")
        }

        @Test("a meeting take notes where its mic starts beside the file, and the note goes once the mic is folded in")
        func liveTakeNotesTheMicStart() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 1, "Welcome, everyone.")])
                let model = makeModel()
                let files = try meetingFiles(model)
                let mic = ScriptedTrack(file: files.mic)
                try await startMeeting(model, mac: ScriptedTrack(file: files.mac), mic: mic)
                let micUp = await waitForMicTrack(model)
                #expect(micUp)
                try await Task.sleep(for: .milliseconds(200))

                mic.levelMeter.record(0.3)

                let noted = await waitUntil { MicTrackNote.read(for: files.mic) != nil }
                #expect(noted)
                let offset = try #require(model.micTrack?.offset)
                #expect(MicTrackNote.read(for: files.mic)?.offset == offset)

                model.stopRecordingAndTranscribe()

                _ = try #require(await landedEntry(model))
                let gone = await waitUntil { !exists(files.mic) && !exists(MicTrackNote.url(for: files.mic)) }
                #expect(gone)
            }
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
                await model.setMePerson(me.id)
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

        @Test("the This Is Me mark lives with People in the library, not in settings, and follows its person through a merge and a delete")
        func meMarkLivesWithPeople() async throws {
            let library = makeTempLibraryURL("second-track-me")
            let defaults = temporaryDefaults()
            let model = makeModel(libraryURL: library, defaults: defaults)
            await model.addPerson(named: "Stefano")
            await model.addPerson(named: "Stefano V")
            let me = try #require(model.person(named: "Stefano V"))
            let other = try #require(model.person(named: "Stefano"))
            #expect(model.mePerson == nil)
            #expect(model.meetingMeLabel == AppModel.meLabel())

            await model.setMePerson(me.id)
            #expect(model.mePerson?.id == me.id)
            #expect(defaults.object(forKey: "mePersonID") == nil)
            #expect(!SettingsPaneScope.people.defaultsKeys.contains("mePersonID"))

            let elsewhere = makeModel(libraryURL: library)
            await elsewhere.refreshPeople()
            #expect(elsewhere.mePerson?.id == me.id)
            #expect(elsewhere.meetingMeLabel == "Stefano V")

            await model.mergePerson(me.id, into: other.id)
            #expect(model.mePerson?.id == other.id)
            #expect(model.meetingMeLabel == "Stefano")

            await model.deletePerson(other.id)
            #expect(model.mePerson == nil)
            await model.addPerson(named: "Stefano")
            #expect(model.mePerson == nil)
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
            let description = String(
                localized: "Keeps your voice on a track of its own beside the Mac audio, so the transcript marks what you said as Me.",
                bundle: italian
            )
            #expect(description == "Tiene la tua voce su una traccia a parte, accanto all'audio del Mac, così nella trascrizione quello che dici compare come Io.")
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

        @Test("checkpoints land in the order they were written, so a microphone track added just after the take's start stays on disk")
        func checkpointWritesLandInOrder() async throws {
            let model = makeModel()
            model.beginRecordingRecovery()
            model.liveRecordingAudioURL = URL(fileURLWithPath: "/tmp/parola-system-ordered.wav")
            model.liveSegments = (0..<60_000).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "a checkpoint that takes a while to encode")
            }
            model.writeRecordingCheckpoint()
            model.liveSegments = []
            model.liveCompanionAudioURL = URL(fileURLWithPath: "/tmp/parola-meetmic-ordered.wav")
            model.writeRecordingCheckpoint()

            await model.pendingRecoveryWrite?.value
            await settle(for: .seconds(2))

            let written = try JSONDecoder().decode(
                RecoveryCheckpoint.self, from: try Data(contentsOf: try #require(model.activeRecoveryFileURL))
            )
            #expect(written.companionAudioURL?.lastPathComponent == "parola-meetmic-ordered.wav")
            #expect(written.segments.isEmpty)
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

        @Test("a mix a crash left half written is cleared once it has been quiet ten minutes; one being written stays")
        func sweepClearsAMixLeftBehind() async throws {
            let library = makeTempLibraryURL("second-track-sweep-mix")
            let folder = try inflight(library)
            let left = folder.appendingPathComponent("\(RecordingScratch.meetingMixPrefix)-\(UUID().uuidString).wav")
            let writing = folder.appendingPathComponent("\(RecordingScratch.meetingMixPrefix)-\(UUID().uuidString).wav")
            for file in [left, writing] { try Data(count: 64 * 1024).write(to: file) }
            try age(left, by: 20 * 60)
            try age(writing, by: 60)

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            #expect(!exists(left))
            #expect(exists(writing))
            #expect(await model.library.list().isEmpty, "a mix in progress is never a take")
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

/// How many times a test's Dock asked for the user's attention.
@MainActor
private final class AttentionAsks {
    var count = 0
}

extension TranscriberMockSuites.MeetingSecondTrackTests {
    @Test("a Mac-audio take that stops by itself with Parola in the background stays on the pill and in the menu bar as stopped, in its notice's words, and the Dock bounces once")
    func macStopsByItselfOutOfSight() async throws {
        try await withMocksCleared([.audioSource, .transcriber]) {
            await installMockTranscriber(segments: [(0, 1, "the Mac side")])
            let model = makeModel()
            let pill = RecordingPill(makesPanel: false, appIsActive: { false })
            pill.bind(model, appActive: false)
            let item = RecordingStatusItem(statusBar: nil, appIsActive: { false })
            item.bind(model)
            let asks = AttentionAsks()
            let badge = DockBadge(show: { _ in }, appIsActive: { false }, requestAttention: { asks.count += 1 })
            badge.bind(model)
            let files = try meetingFiles(model)
            let mac = ScriptedTrack(file: files.mac)
            try await startMeeting(model, mac: mac, mic: nil, category: .transcription)

            await mac.endByItself()

            let landed = await landedEntry(model)
            #expect(landed != nil)
            let stopped = await waitUntil { item.face?.lamp == .stopped }
            #expect(stopped)
            #expect(item.face?.notice == AppModel.macAudioStoppedTakeMessage())
            let pillShown = pill.isShown
            #expect(pillShown)
            let bounced = await waitUntil { asks.count == 1 }
            #expect(bounced)
            await settle()
            #expect(asks.count == 1, "once for the take, not once more for the Mac audio")
            withExtendedLifetime(badge) {}
        }
    }
}
