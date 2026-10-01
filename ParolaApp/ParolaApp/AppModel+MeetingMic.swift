import AVFoundation
import Foundation
import ParolaCore

/// A meeting take's second track: your microphone, recorded beside the Mac audio from soon after Record until Stop.
struct MicTrack {
    let takeID: Int
    var capture: (any LiveAudioSource)?
    var file: URL?
    /// Seconds into the take's own audio where the microphone's first sample sits, once it has been heard.
    var offset: TimeInterval?
    var stalled = false
    /// Stalled at some point in the take, so its file can't be trusted to drift evenly against the Mac's.
    var stoppedEarly = false
    var lastMicReading: ContinuousClock.Instant?
    var lastMacReading: ContinuousClock.Instant?
    var quietTicks = 0
}

/// Where a meeting's microphone track stands, for the "You" meter.
enum MicTrackState: Equatable {
    case starting
    case recording
    /// The microphone never came up, or went quiet while the Mac audio kept coming.
    case unavailable
}

/// Where a meeting's mic file starts in its take, kept beside it for a sweep that finds the pair with no checkpoint.
struct MicTrackNote: Codable, Equatable {
    var offset: TimeInterval
    var stoppedEarly: Bool

    static func url(for mic: URL) -> URL {
        mic.deletingPathExtension().appendingPathExtension("json")
    }

    static func read(for mic: URL) -> MicTrackNote? {
        (try? Data(contentsOf: url(for: mic))).flatMap { try? JSONDecoder().decode(MicTrackNote.self, from: $0) }
    }
}

/// How a microphone track's finish came back, when it did.
enum MicTrackFinish: Sendable {
    case finished(URL)
    case cutShort(URL)
    case failed(String)
}

/// A stopped microphone track's file, where it starts in the take, and whether it stopped before the take did.
struct StoppedMicTrack {
    let file: URL
    let offset: TimeInterval
    var stoppedEarly = false
}

/// A mic track waiting in a record of its own for its entry, and the record's generation.
struct MicTrackRecord {
    let generation: Int
    let mic: StoppedMicTrack
}

/// What a take's file is once its microphone track is folded in, and the mono mix the engine reads, when one was made.
struct FoldedTake {
    let audio: URL
    var engineInput: URL?
    /// A test seam stopped the fold partway, as a crash would; nothing after it runs.
    var stopped = false
}

/// The steps of a fold, after each of which a crash leaves one take file.
enum FoldStep: CaseIterable, Sendable {
    case mixed
    case handedOver
    case repointed
    case micReleased
}

extension AppModel {

    /// A meeting take records your microphone beside the Mac audio, when the setting asks for it.
    func startMicTrack(for take: TakeContext, pairedWith macFile: URL?) {
        guard take.source == .systemAudio, take.category == .meeting, meetingRecordsMicrophone else { return }
        micTrack = MicTrack(takeID: take.id)
        takeMicTrackState = .starting
        let levels = TakeLevelHistory()
        for _ in 0..<(takeLevels?.sampleCount ?? 0) { levels.append(0) }
        takeMicLevels = levels
        Task { [weak self] in await self?.bringUpMicTrack(take, pairedWith: macFile) }
    }

    private func bringUpMicTrack(_ take: TakeContext, pairedWith macFile: URL?) async {
        guard let capture = await makeMicTrackCapture(pairedWith: macFile) else {
            guard micTrack?.takeID == take.id else { return }
            micTrack = nil
            takeMicTrackState = nil
            takeMicLevels = nil
            return
        }
        let asks = micAccessRequest != nil || (capture is MicAudioSource && mode == .normal)
        if asks, await requestMicAccess() == false {
            ParolaLog.notice(.appPermissions, "microphone access for a meeting's second track was denied")
            micTrackUnavailable(take.id)
            return
        }
        // The permission prompt can outlast the take: a late Allow must not switch the microphone on.
        guard micTrack?.takeID == take.id, takeIsCurrent(take) else { return }
        do {
            try await capture.start()
        } catch {
            ParolaLog.error(.audioCapture, "a meeting's microphone track did not start", [.error: .error(error)])
            micTrackUnavailable(take.id)
            return
        }
        let file = await capture.inFlightURL()
        guard micTrack?.takeID == take.id, micTrack?.capture == nil, takeIsCurrent(take), liveSource != nil else {
            await capture.cancel()
            return
        }
        micTrack?.capture = capture
        micTrack?.file = file
        takeMicTrackState = .recording
        liveCompanionAudioURL = file
        liveCompanionStartOffset = nil
        if recording?.isPaused == true { queueMicTrackPause(true, on: capture) }
        writeRecordingCheckpoint()
    }

    private func requestMicAccess() async -> Bool {
        if let micAccessRequest { return await micAccessRequest() }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// A test seam's capture, a fixture's, or the real microphone; a test host never opens the real one.
    private func makeMicTrackCapture(pairedWith macFile: URL?) async -> (any LiveAudioSource)? {
        if let micTrackCaptureOverride { return micTrackCaptureOverride() }
        if let fixture = await MockAudioSourceRegistry.shared.resolve(for: .mic) {
            return FixtureAudioSource.make(fixtureURL: fixture, clock: clock)
        }
        guard mode == .normal, !TestHostSandbox.isTestHost(ProcessInfo.processInfo.environment) else { return nil }
        return MicAudioSource(deviceUID: preferredInputDeviceUID, fileURL: RecordingScratch.meetingMicURL(for: macFile))
    }

    private func micTrackUnavailable(_ takeID: Int) {
        guard micTrack?.takeID == takeID else { return }
        takeMicTrackState = .unavailable
        noteMicTrackMissing(takeID, stopped: false)
    }

    /// Reads the microphone's meter once a tick: its first sample places it in the take, and one gone quiet while the Mac audio runs on has stopped.
    @discardableResult
    func sampleMicTrack(macMeter: LevelMeter, take: TakeContext) -> Float? {
        guard var track = micTrack, track.takeID == take.id, let meter = track.capture?.levelMeter else { return nil }
        let peak = meter.takePeak()
        if track.offset == nil, let heard = meter.firstReadingAt, let offset = takeOffset(of: heard, take: take.id) {
            track.offset = offset
            noteMicTrackStart(track)
            if liveCompanionAudioURL == track.file {
                liveCompanionStartOffset = offset
                micTrack = track
                writeRecordingCheckpoint()
            }
        }
        if recording?.takeID == take.id, recording?.state == .recording {
            let micReading = meter.lastReadingAt
            let macReading = macMeter.lastReadingAt
            if micReading != track.lastMicReading {
                track.quietTicks = 0
                if track.stalled { takeMicTrackState = .recording }
                track.stalled = false
            } else if macReading != track.lastMacReading {
                track.quietTicks += 1
            }
            if !track.stalled, track.quietTicks >= micTrackStallTicks {
                track.stalled = true
                track.stoppedEarly = true
                micTrack = track
                noteMicTrackStart(track)
                writeRecordingCheckpoint()
                takeMicTrackState = .unavailable
                noteMicTrackMissing(take.id, stopped: micReading != nil)
            }
            track.lastMicReading = micReading
            track.lastMacReading = macReading
        }
        micTrack = track
        return peak
    }

    /// The note beside the mic file says where it starts; only for the take's own working file, never beside a fixture.
    private func noteMicTrackStart(_ track: MicTrack) {
        guard let file = track.file, isInflightFile(file), let offset = track.offset else { return }
        let note = MicTrackNote(offset: offset, stoppedEarly: track.stoppedEarly)
        Task { _ = try? await Self.offMainIO { try JSONEncoder().encode(note).write(to: MicTrackNote.url(for: file), options: .atomic) } }
    }

    /// Where a moment sits in the take's own audio, pauses left out; earlier than the take's first sample is negative.
    private func takeOffset(of instant: ContinuousClock.Instant, take takeID: Int) -> TimeInterval? {
        guard let session = recording, session.takeID == takeID, let startedAt = session.startedAt else { return nil }
        let moment = Self.date(of: instant)
        return moment < startedAt ? moment.timeIntervalSince(startedAt) : session.elapsed(at: moment)
    }

    /// Takes the microphone track away from the take, as Stop, a quit or a cancel does; one still coming up drops itself.
    func detachMicTrack(of takeID: Int?) -> MicTrack? {
        guard let track = micTrack, takeID == nil || track.takeID == takeID else { return nil }
        micTrack = nil
        takeMicTrackState = nil
        return track
    }

    /// Stops the microphone track and hands back what it recorded; a write that failed partway still keeps what landed.
    func finishMicTrack(_ track: MicTrack?) async -> StoppedMicTrack? {
        guard let track, let capture = track.capture else { return nil }
        let finish = await AsyncTimeout.run(micTrackFinishLimit, clock: clock) { () -> MicTrackFinish in
            do {
                return .finished(try await capture.prepare())
            } catch let cut as CaptureInterrupted {
                return .cutShort(cut.url)
            } catch {
                return .failed(String(describing: error))
            }
        }
        switch finish {
        case .finished(let file)?:
            return StoppedMicTrack(file: file, offset: track.offset ?? 0, stoppedEarly: track.stoppedEarly)
        case .cutShort(let file)?:
            return StoppedMicTrack(file: file, offset: track.offset ?? 0, stoppedEarly: true)
        case .failed?, nil:
            // A wedged device or a failed finish still leaves on disk what the mic wrote until then.
            ParolaLog.error(.audioRecording, "a meeting's microphone track did not finish; keeping what it wrote")
            guard let file = track.file, FileManager.default.fileExists(atPath: file.path) else { return nil }
            return StoppedMicTrack(file: file, offset: track.offset ?? 0, stoppedEarly: true)
        }
    }

    /// A take that ends with nothing to keep lets its microphone file go too.
    func releaseStoppedMicTrack(_ mic: StoppedMicTrack?) {
        guard let mic else { return }
        releaseMicFile(mic.file)
    }

    /// Cancel and Discard end the microphone track as they end the take: its file goes with the take's.
    func dropMicTrack(_ track: MicTrack?) async {
        if let file = track?.file { forgetLiveCompanion(file) }
        if let capture = track?.capture {
            _ = await AsyncTimeout.run(micTrackFinishLimit, clock: clock) { await capture.cancel() }
        }
        if let file = track?.file { releaseMicFile(file) }
    }

    /// Folds the microphone track into the take's own file, or leaves the take as it was when there is nothing to add.
    func foldMicTrack(
        _ mic: StoppedMicTrack?, into mac: URL, take: TakeContext?, recovery: Int?, wantsEngineInput: Bool
    ) async -> FoldedTake {
        guard let mic else { return FoldedTake(audio: mac) }
        forgetLiveCompanion(mic.file)
        guard await !Self.holdsNoAudio(mic.file) else {
            if let recovery { await rewriteRecoveryCheckpoint(recovery) { $0 = $0.foldingMicTrack(into: mac) } }
            releaseMicFile(mic.file)
            return FoldedTake(audio: mac)
        }
        switch await foldIntoTakeFile(mic, take: mac, generation: recovery, wantsEngineInput: wantsEngineInput) {
        case .folded(let audio, let engineInput):
            if liveRecordingAudioURL == mac { liveRecordingAudioURL = audio }
            updateSession(of: take?.id) { if $0.audioURL == mac { $0.audioURL = audio } }
            return FoldedTake(audio: audio, engineInput: engineInput)
        case .failed:
            pendingMicTracks[mac] = mic
            noteMicTrackKept(take?.id)
            return FoldedTake(audio: mac)
        case .stopped:
            return FoldedTake(audio: mac, stopped: true)
        }
    }

    /// A recovered meeting's mic folds into its take file before the take is saved; a take already stereo only lets its mic go.
    func foldRecoveredMicTrack(
        _ checkpoint: RecoveryCheckpoint, audio: URL, generation: Int, notifies: Bool, wantsEngineInput: Bool = false
    ) async -> FoldedTake {
        if await Self.isStereoFile(audio) {
            await rewriteRecoveryCheckpoint(generation) { $0 = $0.foldingMicTrack(into: audio) }
            for mic in Set([checkpoint.companionAudioURL, RecordingScratch.meetingMicURL(for: audio)].compactMap { $0 })
            where RecordingScratch.isMeetingMic(mic) {
                releaseMicFile(mic)
            }
            return FoldedTake(audio: audio)
        }
        guard let mic = checkpoint.micTrack, FileManager.default.fileExists(atPath: mic.file.path) else {
            return FoldedTake(audio: audio)
        }
        guard await !Self.holdsNoAudio(mic.file) else {
            await rewriteRecoveryCheckpoint(generation) { $0 = $0.foldingMicTrack(into: audio) }
            releaseMicFile(mic.file)
            return FoldedTake(audio: audio)
        }
        switch await foldIntoTakeFile(mic, take: audio, generation: generation, wantsEngineInput: wantsEngineInput) {
        case .folded(let folded, let engineInput):
            return FoldedTake(audio: folded, engineInput: engineInput)
        case .failed:
            pendingMicTracks[audio] = mic
            if notifies { noteMicTrackKept(nil) }
            return FoldedTake(audio: audio)
        case .stopped:
            return FoldedTake(audio: audio, stopped: true)
        }
    }

    /// A checkpoint's mic track whose take is in the library already waits for that entry, and gets a first try at once; false while the checkpoint is all that names it.
    @discardableResult
    func keepMicTrack(of checkpoint: RecoveryCheckpoint, forEntry entryID: LibraryEntry.ID) async -> Bool {
        guard let mic = checkpoint.micTrack, FileManager.default.fileExists(atPath: mic.file.path) else { return true }
        let recorded = await keepMicTrack(mic, forEntry: entryID)
        guard let record = micTrackRecords[entryID] else { return recorded }
        return await foldWaitingMicTrack(record, intoEntry: entryID) || recorded
    }

    /// A mic left beside a take copy the library already holds goes to that entry; false while the copy must stay to pair with it.
    func giveMicToSavedTake(_ mic: URL, take: URL, digest: String) async -> Bool {
        if await Self.isStereoFile(take) {
            releaseMicFile(mic)
            return true
        }
        guard let entry = await savedEntry(digest: digest) else { return true }
        let note = MicTrackNote.read(for: mic)
        let waiting = StoppedMicTrack(file: mic, offset: note?.offset ?? 0, stoppedEarly: note?.stoppedEarly ?? false)
        guard await keepMicTrack(waiting, forEntry: entry.id) else { return false }
        if let record = micTrackRecords[entry.id] { await foldWaitingMicTrack(record, intoEntry: entry.id) }
        return true
    }

    /// The entry made from these bytes, in the library or in Recently Deleted.
    private func savedEntry(digest: String) async -> LibraryEntry? {
        if let entry = await library.findEntry(digest: digest) { return entry }
        return await library.listDeleted().first { $0.manifest.sourceDigest == digest }
    }

    /// The records a launch found are folded in one after another; those that still can't wait for the next launch.
    func foldWaitingMicTracks(_ checkpoints: [RecoveryCheckpoint]) {
        var waiting: [(entryID: LibraryEntry.ID, record: MicTrackRecord)] = []
        for checkpoint in checkpoints {
            guard let entryID = checkpoint.entryID, let mic = checkpoint.micTrack else { continue }
            let record = MicTrackRecord(generation: adoptRecovery(checkpoint), mic: mic)
            micTrackRecords[entryID] = record
            waiting.append((entryID, record))
        }
        guard !waiting.isEmpty else { return }
        micTrackFolds = Task { [weak self] in
            for item in waiting { await self?.foldWaitingMicTrack(item.record, intoEntry: item.entryID) }
        }
    }

    /// Folds a waiting mic track into its entry's audio and labels your side of what it says; false leaves the record for later.
    @discardableResult
    func foldWaitingMicTrack(_ record: MicTrackRecord, intoEntry entryID: LibraryEntry.ID) async -> Bool {
        guard await !Self.holdsNoAudio(record.mic.file) else {
            settleMicTrackRecord(record, entryID: entryID)
            return true
        }
        let loaded: LoadedEntry
        do {
            loaded = try await library.load(entryID)
        } catch LibraryStore.LibraryError.notFound {
            settleMicTrackRecord(record, entryID: entryID)
            return true
        } catch {
            return false
        }
        guard let audio = loaded.document.audioURL else {
            settleMicTrackRecord(record, entryID: entryID)
            return true
        }
        if await !Self.isStereoFile(audio) {
            guard await hasRoomToFold(mac: audio, mic: record.mic.file, mono: false) else { return false }
            let scratch = meetingScratchURL()
            meetingScratchInUse.insert(scratch)
            defer { meetingScratchInUse.remove(scratch) }
            let folder = inflightRecordingsURL
            do {
                try await Self.offMainIO { [offset = record.mic.offset, micFile = record.mic.file, stoppedEarly = record.mic.stoppedEarly] in
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    WAVHeaderRepair.makeReadable(micFile)
                    let start = Date(timeIntervalSinceReferenceDate: 0)
                    try MeetingTakeMixer.mix(
                        mac: audio, mic: micFile, macStart: start, micStart: start.addingTimeInterval(offset), into: scratch, mono: nil,
                        micStoppedEarly: stoppedEarly
                    )
                }
                try await library.replaceAudio(of: entryID, with: scratch)
            } catch {
                ParolaLog.error(.audioRecording, "a waiting microphone track could not be folded in", [.error: .error(error)])
                discardMeetingScratch([scratch])
                return false
            }
        }
        await labelSides(ofEntry: entryID)
        settleMicTrackRecord(record, entryID: entryID)
        refreshLibrary()
        return true
    }

    private func settleMicTrackRecord(_ record: MicTrackRecord, entryID: LibraryEntry.ID) {
        if micTrackRecords[entryID]?.generation == record.generation { micTrackRecords[entryID] = nil }
        recoveryReferencedFiles.remove(record.mic.file.resolvingSymlinksInPath().path)
        endRecovery(record.generation)
        releaseMicFile(record.mic.file)
    }

    /// Labels your side of a meeting entry's transcript from its stereo audio, segment by segment as it stands now.
    private func labelSides(ofEntry entryID: LibraryEntry.ID) async {
        guard let loaded = try? await library.load(entryID), let stereo = loaded.document.audioURL,
              !loaded.document.transcript.segments.isEmpty else { return }
        let segments = loaded.document.transcript.segments
        let label = meetingMeLabel
        guard let labelled = try? await Self.offMainIO({
            try SpeakerSideAttribution.label(segments: segments, stereo: stereo, meLabel: label)
        }) else { return }
        let sides = Dictionary(labelled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let updated = try? await library.mutateTranscript(for: entryID, { transcript in
            for index in transcript.segments.indices {
                guard let side = sides[transcript.segments[index].id], side.text == transcript.segments[index].text else { continue }
                transcript.segments[index].speaker = side.speaker
                transcript.segments[index].words = side.words
            }
        }) else { return }
        assignMePerson(in: entryID, transcript: updated)
        guard selectedEntryID == entryID else { return }
        installStoredTranscript(updated)
        installPlayer(for: stereo)
    }

    private enum FoldResult {
        case folded(audio: URL, engineInput: URL?)
        case failed
        case stopped
    }

    /// Mix, rename over the take's own file, rewrite the checkpoint, then let the mic go: a crash after any step leaves one take file.
    private func foldIntoTakeFile(_ mic: StoppedMicTrack, take mac: URL, generation: Int?, wantsEngineInput: Bool) async -> FoldResult {
        var audio = mac
        var engineInput: URL?
        if await !Self.isStereoFile(mac) {
            guard await hasRoomToFold(mac: mac, mic: mic.file, mono: wantsEngineInput) else {
                ParolaLog.notice(.audioRecording, "no room on disk to fold a meeting's microphone track in")
                return .failed
            }
            let scratch = meetingScratchURL()
            let mono = wantsEngineInput ? meetingScratchURL() : nil
            meetingScratchInUse.formUnion([scratch, mono].compactMap { $0 })
            defer { meetingScratchInUse.remove(scratch) }
            let folder = inflightRecordingsURL
            do {
                try await Self.offMainIO { [offset = mic.offset, micFile = mic.file, stoppedEarly = mic.stoppedEarly] in
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    WAVHeaderRepair.makeReadable(mac)
                    WAVHeaderRepair.makeReadable(micFile)
                    let start = Date(timeIntervalSinceReferenceDate: 0)
                    try MeetingTakeMixer.mix(
                        mac: mac, mic: micFile, macStart: start, micStart: start.addingTimeInterval(offset), into: scratch, mono: mono,
                        micStoppedEarly: stoppedEarly
                    )
                }
            } catch {
                ParolaLog.error(.audioRecording, "a meeting's microphone track could not be mixed in", [.error: .error(error)])
                discardMeetingScratch([scratch, mono])
                return .failed
            }
            guard await foldStepHook?(.mixed) ?? true else { return .stopped }
            let inPlace = isInflightFile(mac)
            do {
                audio = try await Self.offMainIO { try Self.handOver(scratch, to: mac, inPlace: inPlace) }
            } catch {
                ParolaLog.error(.audioRecording, "a meeting's mix could not take its take's place", [.error: .error(error)])
                discardMeetingScratch([scratch, mono])
                return .failed
            }
            engineInput = mono
            guard await foldStepHook?(.handedOver) ?? true else { return .stopped }
        }
        if let generation { await rewriteRecoveryCheckpoint(generation) { $0 = $0.foldingMicTrack(into: audio) } }
        guard await foldStepHook?(.repointed) ?? true else { return .stopped }
        releaseMicFile(mic.file)
        guard await foldStepHook?(.micReleased) ?? true else { return .stopped }
        return .folded(audio: audio, engineInput: engineInput)
    }

    /// The mix takes the take file's own name, so there is only ever one take file; one outside the working folder, a fixture, is never overwritten.
    nonisolated static func handOver(_ scratch: URL, to take: URL, inPlace: Bool) throws -> URL {
        let target = inPlace
            ? take
            : scratch.deletingLastPathComponent().appendingPathComponent("parola-system-\(UUID().uuidString).wav")
        guard rename(scratch.path, target.path) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: scratch)
            throw failure
        }
        return target
    }

    /// Mixes a meeting's two files into a stereo file under a scratch name in `folder`, which a sweep never takes for a take.
    nonisolated static func mixMeetingFiles(
        mac: URL, mic: URL, micOffset: TimeInterval, micStoppedEarly: Bool, in folder: URL, mono: URL?
    ) async throws -> URL {
        let mixed = folder.appendingPathComponent("\(RecordingScratch.meetingMixPrefix)-\(UUID().uuidString).wav")
        do {
            try await offMainIO {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                WAVHeaderRepair.makeReadable(mac)
                WAVHeaderRepair.makeReadable(mic)
                let start = Date(timeIntervalSinceReferenceDate: 0)
                try MeetingTakeMixer.mix(
                    mac: mac, mic: mic, macStart: start, micStart: start.addingTimeInterval(micOffset), into: mixed, mono: mono,
                    micStoppedEarly: micStoppedEarly
                )
            }
        } catch {
            for file in [mixed, mono].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        return mixed
    }

    /// The engines other than WhisperKit get a mono mix of a meeting's sides; WhisperKit sums the channels itself.
    func engineNeedsMonoMix(model: String? = nil) -> Bool {
        ModelCatalog.variant(id: model ?? selectedModel)?.engineID != .whisperKit
    }

    /// What a meeting's fold at Stop will write: the stereo take, and the engine's mono mix when it needs one.
    nonisolated static func foldBytes(mac: URL, mic: URL, mono: Bool) async -> Int64 {
        let sizes = (try? await offMainIO {
            [mac, mic].map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }) ?? []
        return (sizes.max() ?? 0) * (mono ? 2 : 1)
    }

    /// The room a meeting recording its mic keeps free for its fold, so the guard stops the take while the fold still fits.
    func meetingFoldReserve() async -> Int64 {
        guard micTrack?.capture != nil, let mac = liveRecordingAudioURL, let mic = liveCompanionAudioURL else { return 0 }
        return await Self.foldBytes(mac: mac, mic: mic, mono: engineNeedsMonoMix())
    }

    /// Left free after a fold; less than the guard's floor, which already set the fold's room aside.
    nonisolated static let meetingFoldMarginBytes: Int64 = 50_000_000

    /// Whether the volume holds a fold of these files with a margin still free after it.
    func hasRoomToFold(mac: URL, mic: URL, mono: Bool) async -> Bool {
        let provider = freeDiskSpaceProvider
        let need = await Self.foldBytes(mac: mac, mic: mic, mono: mono)
        guard let free = await Self.freeDiskSpace(provider) else { return true }
        return free - need >= Self.meetingFoldMarginBytes
    }

    /// A scratch file for a meeting's mix, in the working folder, where a sweep clears what a crash leaves.
    func meetingScratchURL() -> URL {
        inflightRecordingsURL.appendingPathComponent("\(RecordingScratch.meetingMixPrefix)-\(UUID().uuidString).wav")
    }

    func discardMeetingScratch(_ files: [URL?]) {
        for file in files.compactMap({ $0 }) {
            meetingScratchInUse.remove(file)
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The live take lets go of a microphone file that is now the fold's to settle.
    private func forgetLiveCompanion(_ file: URL) {
        guard liveCompanionAudioURL == file else { return }
        liveCompanionAudioURL = nil
        liveCompanionStartOffset = nil
    }

    func releaseMicFile(_ file: URL) {
        forgetLiveCompanion(file)
        releaseTakeFile(file)
        if !FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: MicTrackNote.url(for: file)) }
    }

    nonisolated static func isStereoFile(_ url: URL) async -> Bool {
        (try? await offMainIO { MeetingTakeMixer.isStereo(url) }) ?? false
    }

    /// A Mac-audio take with two channels is a meeting with your microphone on the right.
    func isMeetingStereo(_ audio: URL, source: EntrySource) async -> Bool {
        guard source == .systemAudio else { return false }
        return (try? await Self.offMainIO { MeetingTakeMixer.isStereo(audio) }) ?? false
    }

    /// The mono mix an engine reads for a meeting's stereo take; nil when one can't be made, and the engine reads the stereo.
    func meetingEngineInput(for stereo: URL) async -> URL? {
        let mono = meetingScratchURL()
        meetingScratchInUse.insert(mono)
        let folder = inflightRecordingsURL
        do {
            try await Self.offMainIO {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try MeetingTakeMixer.downmix(stereo: stereo, into: mono)
            }
            return mono
        } catch {
            ParolaLog.error(.audioRecording, "a meeting's mono mix could not be made", [.error: .error(error)])
            discardMeetingScratch([mono])
            return nil
        }
    }

    /// A run on a meeting's stereo take labels your side as the engine finishes, before sentences join.
    func meetingOptions(_ options: TranscriptionOptions, stereo: URL) -> TranscriptionOptions {
        var sided = options
        sided.speakerSides = SpeakerSides(stereo: stereo, meLabel: meetingMeLabel)
        return sided
    }

    /// The speaker label your own words take in a meeting: the name of the person marked as you, or Me.
    var meetingMeLabel: String {
        mePerson?.name ?? Self.meLabel()
    }

    nonisolated static func meLabel(bundle: Bundle = .main) -> String {
        String(localized: "Me", bundle: bundle)
    }

    /// Says once per take that your microphone is not, or no longer, in the recording.
    func noteMicTrackMissing(_ takeID: Int, stopped: Bool) {
        guard micTrackNoticeTake != takeID, exportNotice?.actions.isEmpty ?? true else { return }
        micTrackNoticeTake = takeID
        let message = stopped ? Self.micTrackStoppedMessage() : Self.micTrackMissingMessage()
        exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .info, forTake: takeID)
    }

    /// The fold failed and the mic waits: said for that take, and gone with it.
    func noteMicTrackKept(_ takeID: Int?) {
        guard exportNotice?.actions.isEmpty ?? true else { return }
        exportNotice = ExportNotice(message: Self.micTrackKeptMessage(), failures: [], folder: nil, tone: .info, forTake: takeID)
    }

    nonisolated static func micTrackKeptMessage(bundle: Bundle = .main) -> String {
        String(
            localized: "Your microphone's track couldn't be added to this recording yet. Parola keeps it and tries again the next time it opens.",
            bundle: bundle
        )
    }

    nonisolated static func micTrackMissingMessage(bundle: Bundle = .main) -> String {
        String(localized: "Your microphone isn't in this recording. It has the Mac audio only.", bundle: bundle)
    }

    nonisolated static func micTrackStoppedMessage(bundle: Bundle = .main) -> String {
        String(localized: "Your microphone stopped. The rest of this recording has the Mac audio only.", bundle: bundle)
    }
}
