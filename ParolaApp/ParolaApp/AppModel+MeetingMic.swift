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
    var unavailable = false
    var stalled = false
    var lastMicReading: ContinuousClock.Instant?
    var lastMacReading: ContinuousClock.Instant?
    var quietTicks = 0
}

/// A stopped microphone track's file, and where it starts in the take.
struct StoppedMicTrack {
    let file: URL
    let offset: TimeInterval
}

/// What a take's file is once its microphone track is folded in, and the mono mix the engine reads, when one was made.
struct FoldedTake {
    let audio: URL
    let engineInput: URL?
}

extension AppModel {

    /// A meeting take records your microphone beside the Mac audio, when the setting asks for it.
    func startMicTrack(for take: TakeContext, pairedWith macFile: URL?) {
        guard take.source == .systemAudio, take.category == .meeting, meetingRecordsMicrophone else { return }
        micTrack = MicTrack(takeID: take.id)
        Task { [weak self] in await self?.bringUpMicTrack(take, pairedWith: macFile) }
    }

    private func bringUpMicTrack(_ take: TakeContext, pairedWith macFile: URL?) async {
        guard let capture = await makeMicTrackCapture(pairedWith: macFile) else {
            if micTrack?.takeID == take.id { micTrack = nil }
            return
        }
        if capture is MicAudioSource, mode == .normal, await AVCaptureDevice.requestAccess(for: .audio) == false {
            ParolaLog.notice(.appPermissions, "microphone access for a meeting's second track was denied")
            micTrackUnavailable(take.id)
            return
        }
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
        liveCompanionAudioURL = file
        liveCompanionStartOffset = nil
        if recording?.isPaused == true { queueCapturePause(true, on: capture) }
        writeRecordingCheckpoint()
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
        micTrack?.unavailable = true
        noteMicTrackMissing(takeID, stopped: false)
    }

    /// Reads the microphone's meter once a tick: its first sample places it in the take, and one gone quiet while the Mac audio runs on has stopped.
    @discardableResult
    func sampleMicTrack(macMeter: LevelMeter, take: TakeContext) -> Float? {
        guard var track = micTrack, track.takeID == take.id, let meter = track.capture?.levelMeter else { return nil }
        let peak = meter.takePeak()
        if track.offset == nil, let heard = meter.firstReadingAt, let offset = takeOffset(of: heard, take: take.id) {
            track.offset = offset
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
                track.stalled = false
            } else if macReading != track.lastMacReading {
                track.quietTicks += 1
            }
            if !track.stalled, track.quietTicks >= micTrackStallTicks {
                track.stalled = true
                noteMicTrackMissing(take.id, stopped: micReading != nil)
            }
            track.lastMicReading = micReading
            track.lastMacReading = macReading
        }
        micTrack = track
        return peak
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
        return track
    }

    /// Stops the microphone track and hands back what it recorded; a write that failed partway still keeps what landed.
    func finishMicTrack(_ track: MicTrack?) async -> StoppedMicTrack? {
        guard let track, let capture = track.capture else { return nil }
        do {
            return StoppedMicTrack(file: try await capture.prepare(), offset: track.offset ?? 0)
        } catch let cut as CaptureInterrupted {
            return StoppedMicTrack(file: cut.url, offset: track.offset ?? 0)
        } catch {
            ParolaLog.error(.audioRecording, "a meeting's microphone track could not be finished", [.error: .error(error)])
            return nil
        }
    }

    /// A take that ends with nothing to keep lets its microphone file go too.
    func releaseStoppedMicTrack(_ mic: StoppedMicTrack?) {
        guard let mic else { return }
        if liveCompanionAudioURL == mic.file {
            liveCompanionAudioURL = nil
            liveCompanionStartOffset = nil
        }
        releaseTakeFile(mic.file)
    }

    /// Cancel and Discard end the microphone track as they end the take: its file goes with the take's.
    func dropMicTrack(_ track: MicTrack?) async {
        if liveCompanionAudioURL == track?.file {
            liveCompanionAudioURL = nil
            liveCompanionStartOffset = nil
        }
        await track?.capture?.cancel()
        if let file = track?.file { releaseTakeFile(file) }
    }

    /// The two tracks become the take's one stereo file, Mac audio left and you right, which takes the Mac file's place before both go.
    func foldMicTrack(
        _ mic: StoppedMicTrack?, into mac: URL, take: TakeContext?, recovery: Int?, wantsEngineInput: Bool
    ) async -> FoldedTake {
        guard let mic else { return FoldedTake(audio: mac, engineInput: nil) }
        if liveCompanionAudioURL == mic.file {
            liveCompanionAudioURL = nil
            liveCompanionStartOffset = nil
        }
        guard await !Self.holdsNoAudio(mic.file) else {
            releaseTakeFile(mic.file)
            return FoldedTake(audio: mac, engineInput: nil)
        }
        let folder = inflightRecordingsURL
        let engineInput = wantsEngineInput ? Self.meetingEngineInputURL() : nil
        let stereo: URL
        do {
            let mixed = try await Self.mixMeetingFiles(mac: mac, mic: mic.file, micOffset: mic.offset, in: folder, mono: engineInput)
            stereo = try await Self.offMainIO {
                let take = folder.appendingPathComponent("parola-system-\(UUID().uuidString).wav")
                do {
                    try FileManager.default.moveItem(at: mixed, to: take)
                } catch {
                    try? FileManager.default.removeItem(at: mixed)
                    throw error
                }
                return take
            }
        } catch {
            ParolaLog.error(.audioRecording, "a meeting's microphone track could not be mixed in", [.error: .error(error)])
            if let engineInput { try? FileManager.default.removeItem(at: engineInput) }
            if let take { noteMicTrackMissing(take.id, stopped: false) }
            return FoldedTake(audio: mac, engineInput: nil)
        }
        if let recovery, let take, let startedAt = take.recoveryStartedAt {
            await repointRecordingCheckpoint(
                recovery, startedAt: startedAt, audio: stereo, source: take.source.entrySource, category: take.category
            )
        }
        if liveRecordingAudioURL == mac { liveRecordingAudioURL = stereo }
        updateSession(of: take?.id) { if $0.audioURL == mac { $0.audioURL = stereo } }
        releaseTakeFile(mac)
        releaseTakeFile(mic.file)
        return FoldedTake(audio: stereo, engineInput: engineInput)
    }

    /// Mixes a meeting's two files into a stereo file under a scratch name in `folder`, which a sweep never takes for a take.
    nonisolated static func mixMeetingFiles(mac: URL, mic: URL, micOffset: TimeInterval, in folder: URL, mono: URL?) async throws -> URL {
        let mixed = folder.appendingPathComponent("\(RecordingScratch.meetingMixPrefix)-\(UUID().uuidString).wav")
        do {
            try await offMainIO {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                WAVHeaderRepair.makeReadable(mac)
                WAVHeaderRepair.makeReadable(mic)
                let start = Date(timeIntervalSinceReferenceDate: 0)
                try MeetingTakeMixer.mix(
                    mac: mac, mic: mic, macStart: start, micStart: start.addingTimeInterval(micOffset), into: mixed, mono: mono
                )
            }
        } catch {
            for file in [mixed, mono].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        return mixed
    }

    /// A crashed meeting's microphone track goes back into its take; one that is gone or unreadable leaves the Mac side alone.
    func mixRecoveredMicTrack(_ checkpoint: RecoveryCheckpoint, mac: URL?) async -> URL? {
        guard let mac, let companion = checkpoint.companionAudioURL else { return nil }
        guard let mic = (try? await Self.offMainIO { Self.readableRecordingURL(companion) }) ?? nil else { return nil }
        do {
            return try await Self.mixMeetingFiles(
                mac: mac, mic: mic, micOffset: checkpoint.companionStartOffset ?? 0, in: inflightRecordingsURL, mono: nil
            )
        } catch {
            ParolaLog.error(.appRecovery, "a recovered meeting's microphone track could not be mixed in", [.error: .error(error)])
            return nil
        }
    }

    nonisolated static func meetingEngineInputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("parola-meeting-mix-\(UUID().uuidString).wav")
    }

    /// A Mac-audio take with two channels is a meeting with your microphone on the right.
    func isMeetingStereo(_ audio: URL, source: EntrySource) async -> Bool {
        guard source == .systemAudio else { return false }
        return (try? await Self.offMainIO { MeetingTakeMixer.isStereo(audio) }) ?? false
    }

    /// The mono mix an engine reads for a meeting's stereo take; nil when one can't be made, and the engine reads the stereo.
    func meetingEngineInput(for stereo: URL) async -> URL? {
        let mono = Self.meetingEngineInputURL()
        do {
            try await Self.offMainIO { try MeetingTakeMixer.downmix(stereo: stereo, into: mono) }
            return mono
        } catch {
            ParolaLog.error(.audioRecording, "a meeting's mono mix could not be made", [.error: .error(error)])
            try? FileManager.default.removeItem(at: mono)
            return nil
        }
    }

    /// A run on a meeting's stereo take labels your side as the engine finishes, before sentences join.
    func meetingOptions(_ options: TranscriptionOptions, stereo: URL) -> TranscriptionOptions {
        var sided = options
        sided.speakerSides = SpeakerSides(stereo: stereo, meLabel: meetingMeLabel)
        return sided
    }

    /// The speaker label your own words take in a meeting.
    var meetingMeLabel: String {
        Self.meLabel()
    }

    nonisolated static func meLabel(bundle: Bundle = .main) -> String {
        String(localized: "Me", bundle: bundle)
    }

    /// Says once per take that your microphone is not, or no longer, in the recording.
    func noteMicTrackMissing(_ takeID: Int, stopped: Bool) {
        guard micTrackNoticeTake != takeID, exportNotice?.actions.isEmpty ?? true else { return }
        micTrackNoticeTake = takeID
        let message = stopped ? Self.micTrackStoppedMessage() : Self.micTrackMissingMessage()
        exportNotice = ExportNotice(message: message, failures: [], folder: nil, tone: .info)
    }

    nonisolated static func micTrackMissingMessage(bundle: Bundle = .main) -> String {
        String(localized: "Your microphone isn't in this recording. It has the Mac audio only.", bundle: bundle)
    }

    nonisolated static func micTrackStoppedMessage(bundle: Bundle = .main) -> String {
        String(localized: "Your microphone stopped. The rest of this recording has the Mac audio only.", bundle: bundle)
    }
}
