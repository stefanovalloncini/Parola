import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind them first.
@MainActor
@Suite("Meeting defaults")
struct MeetingDefaultsTests {
    @Test("a system-audio take files as a meeting unless told otherwise")
    func systemAudioIsAMeeting() {
        #expect(AppModel.defaultCategory(for: .systemAudio) == .meeting)
        #expect(AppModel.defaultCategory(for: .microphone) == .transcription)
    }

    // MARK: - The You and Mac audio meters

    @Test("one lane is the whole band as before; a meeting's two share it in halves, You on top")
    func lanes() {
        let size = CGSize(width: 1180, height: StageBand.height)
        #expect(StageBand.lanes(1, in: size) == [CGRect(x: 0, y: 0, width: 1180, height: 140)])
        #expect(StageBand.lanes(2, in: size) == [
            CGRect(x: 0, y: 0, width: 1180, height: 70),
            CGRect(x: 0, y: 70, width: 1180, height: 70),
        ])
    }

    @Test("the You lane reads the microphone's levels and the Mac audio lane the take's, sample for sample")
    func lanesReadTheirSides() {
        let mac = TakeLevelHistory()
        let mic = TakeLevelHistory()
        for sample in 0..<20 {
            mac.append(0.25)
            mic.append(sample < 5 ? 0 : 0.75)
        }
        let meeting = StageBand.tape(levels: mac, micLevels: mic, micState: .recording, markers: [], paused: false)
        #expect(meeting.levels == [Float](repeating: 0.25, count: 20))
        #expect(meeting.micLevels == [Float](repeating: 0, count: 5) + [Float](repeating: 0.75, count: 15))
        #expect(meeting.newest == 19)
        #expect(meeting.micLost == nil)

        let plain = StageBand.tape(levels: mac, micLevels: nil, micState: nil, markers: [], paused: false)
        #expect(plain.levels == meeting.levels)
        #expect(plain.micLevels == nil)
    }

    @Test("the You lane greys and says why once the microphone isn't in the take: never recorded, or stopped partway")
    func offLane() throws {
        #expect(StageBand.lostMicNote(.unavailable) == "Microphone not recorded")
        #expect(StageBand.lostMicNote(.stopped) == "Microphone stopped")
        #expect(StageBand.lostMicNote(.starting) == nil)
        #expect(StageBand.lostMicNote(.recording) == nil)
        #expect(StageBand.lostMicNote(nil) == nil, "Stop lets a live state go and keeps the levels: the lane stays as it was")
        #expect(StageBand.offLaneStrength < 1)
        #expect(MicTrackState.unavailable.isLost && MicTrackState.stopped.isLost)
        #expect(!MicTrackState.starting.isLost && !MicTrackState.recording.isLost)

        let mac = TakeLevelHistory()
        let mic = TakeLevelHistory()
        mac.append(0.5)
        mic.append(0)
        #expect(StageBand.tape(levels: mac, micLevels: mic, micState: .stopped, markers: [], paused: false).micLost == "Microphone stopped")
        #expect(StageBand.tape(levels: mac, micLevels: mic, micState: nil, markers: [], paused: false).micLevels == [0])

        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(StageBand.lostMicNote(.unavailable, bundle: it) == "Microfono non registrato")
        #expect(StageBand.lostMicNote(.stopped, bundle: it) == "Microfono fermato")
    }

    @Test("the Mac audio lane says so once its capture ends by itself, and the notices say it in Italian too")
    func macLaneStopped() throws {
        let mac = TakeLevelHistory()
        let mic = TakeLevelHistory()
        mac.append(0.5)
        mic.append(0.5)
        #expect(StageBand.stoppedMacNote(false) == nil)
        #expect(StageBand.tape(levels: mac, micLevels: mic, micState: .recording, markers: [], paused: false, macStopped: true).macLost == "Mac audio stopped")
        let before = StageTape(levels: [0.1], micLevels: [0.2], flags: [], newest: 4, paused: false)
        #expect(before != StageTape(levels: [0.1], micLevels: [0.2], macLost: "Mac audio stopped", flags: [], newest: 4, paused: false))

        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(StageBand.stoppedMacNote(true, bundle: it) == "Audio del Mac fermato")
        #expect(AppModel.macAudioStoppedMessage(bundle: it) == "L'audio del Mac si è fermato. Il tuo microfono continua a registrare.")
        #expect(AppModel.macAudioStoppedTakeMessage(bundle: it) == "L'audio del Mac si è fermato, quindi Parola ha fermato la registrazione.")
    }

    @Test("the band follows the microphone's observed state even before its levels exist, so the lanes always get their names")
    func lanesFollowTheObservedState() {
        let model = makeRecordingModel("meeting-lane-observed")
        #expect(StageBand.micLane(of: model).shown == false)
        let changed = LaneObservation()
        withObservationTracking {
            _ = StageBand.micLane(of: model)
        } onChange: {
            changed.fired = true
        }

        model.takeMicLevels = TakeLevelHistory()
        model.takeMicTrackState = .starting

        #expect(changed.fired)
        let lane = StageBand.micLane(of: model)
        #expect(lane.shown)
        #expect(lane.state == .starting)
    }

    @Test("the bars are built again when the You lane comes, goes or stops, and only then")
    func tapeRedrawsForTheYouLane() {
        let one = StageTape(levels: [0.1], flags: [], newest: 4, paused: false)
        let two = StageTape(levels: [0.1], micLevels: [0.2], flags: [], newest: 4, paused: false)
        #expect(one != two)
        #expect(two != StageTape(levels: [0.1], micLevels: [0.2], micLost: "Microphone not recorded", flags: [], newest: 4, paused: false))
        #expect(
            StageTape(levels: [0.1], micLevels: [0.2], micLost: "Microphone not recorded", flags: [], newest: 4, paused: false)
                != StageTape(levels: [0.1], micLevels: [0.2], micLost: "Microphone stopped", flags: [], newest: 4, paused: false)
        )
        #expect(two == StageTape(levels: [0.1], micLevels: [0.2], flags: [], newest: 4, paused: false))
    }

    private func meetingTake() -> RecordingSession {
        var take = RecordingSession(
            takeID: 1, source: .systemAudio, category: .meeting, title: "M", isStreaming: false, arming: .startingCapture
        )
        _ = take.markCapturing(at: Date(timeIntervalSinceNow: -60))
        return take
    }

    private func stageElements(_ take: RecordingSession, model: AppModel) -> [HostedAccessibility.Element] {
        model.route = .recording
        let hosted = HostedWindow(StagePage(take: take).environment(model), width: 1180, height: 708)
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host)
    }

    @Test("a meeting that records your microphone shows a You lane over a Mac audio lane in the band's place")
    func meetingStageShowsTwoLanes() throws {
        let model = makeRecordingModel("meeting-lanes")
        let plain = stageElements(meetingTake(), model: model)
        #expect(plain.contains { $0.label == "Input level" })
        #expect(!plain.contains { $0.label == "You" })

        model.takeMicLevels = TakeLevelHistory()
        model.takeMicTrackState = .recording
        let meeting = stageElements(meetingTake(), model: model)
        let youLane = meeting.first { $0.label == "You" }
        let macLane = meeting.first { $0.label == "Mac audio" }
        let you = try #require(youLane)
        let mac = try #require(macLane)
        #expect(!meeting.contains { $0.label == "Input level" })
        #expect(you.frame.midY > mac.frame.midY, "screen coordinates grow upwards: You sits above Mac audio")
        #expect(you.value != "Microphone not recorded")
    }

    @Test("the You lane says so in place once your microphone isn't in the take")
    func offLaneSaysSo() throws {
        let model = makeRecordingModel("meeting-lane-off")
        model.takeMicLevels = TakeLevelHistory()
        model.takeMicTrackState = .unavailable
        let elements = stageElements(meetingTake(), model: model)
        let youLane = elements.first { $0.label == "You" }
        let you = try #require(youLane)
        #expect(you.value == "Microphone not recorded")
        #expect(elements.contains { $0.label == "Mac audio" })

        model.takeMicTrackState = .stopped
        let stopped = stageElements(meetingTake(), model: model)
        let stoppedLane = stopped.first { $0.label == "You" }
        let youStopped = try #require(stoppedLane)
        #expect(youStopped.value == "Microphone stopped")
    }

    @Test("the meters' words have their Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(String(localized: "You", bundle: it) == "Tu")
        #expect(String(localized: "Mac audio", bundle: it) == "Audio del Mac")
        #expect(String(localized: "Microphone not recorded", bundle: it) == "Microfono non registrato")
        #expect(StageFacts.silenceWarning(source: .systemAudio, micTrack: .recording, bundle: it) == "Nessun suono dal Mac né dal microfono.")
    }

    // MARK: - The silence warning

    @Test("a meeting's silence counts your microphone only while it records")
    func silenceCountsTheMic() {
        #expect(AppModel.silenceCountsMic(.recording))
        #expect(!AppModel.silenceCountsMic(.starting))
        #expect(!AppModel.silenceCountsMic(.unavailable))
        #expect(!AppModel.silenceCountsMic(nil))
    }

    @Test("the take's latest sound is the later of its two sides")
    func latestSound() {
        let early = ContinuousClock.now
        let late = early + .seconds(3)
        #expect(AppModel.latestSound(nil, nil) == nil)
        #expect(AppModel.latestSound(early, nil) == early)
        #expect(AppModel.latestSound(nil, late) == late)
        #expect(AppModel.latestSound(late, early) == late)
        #expect(AppModel.latestSound(early, late) == late)
    }

    @Test("a quiet meeting names both sides while it records your microphone, and the Mac alone otherwise")
    func silenceWarningNamesItsSides() {
        let english = Bundle.main
        let both = "No sound from your Mac or your microphone."
        let mac = "No sound from your Mac — check that audio is playing."
        #expect(StageFacts.silenceWarning(source: .systemAudio, micTrack: .recording, bundle: english) == both)
        #expect(StageFacts.silenceWarning(source: .systemAudio, micTrack: .starting, bundle: english) == mac)
        #expect(StageFacts.silenceWarning(source: .systemAudio, micTrack: .unavailable, bundle: english) == mac)
        #expect(StageFacts.silenceWarning(source: .systemAudio, micTrack: nil, bundle: english) == mac)
        #expect(StageFacts.silenceWarning(source: .microphone, micTrack: nil, bundle: english) == "No voice detected — check your microphone.")
    }

    // MARK: - The device menu before a take

    @Test("only a take still counting in can change its microphone; from its start on, it may have opened one")
    func countInChoosesTheInput() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        #expect(take.isCountingIn)
        _ = take.arm(.startingCapture)
        #expect(!take.isCountingIn)
        _ = take.arm(.preparingModel(name: "openai_whisper-tiny", download: nil))
        #expect(!take.isCountingIn)
        _ = take.markCapturing(at: Date())
        #expect(!take.isCountingIn)
        _ = take.pause(at: Date())
        #expect(!take.isCountingIn)
    }

    private static let builtIn = AudioInputDevice(uid: "built-in", name: "MacBook Pro Microphone", isDefault: true)
    private static let usb = AudioInputDevice(uid: "usb", name: "USB Mic", isDefault: false)

    @Test("the device menu lists System Default first, as Settings and the menu bar do, then the Mac's inputs")
    func deviceMenuRows() throws {
        #expect(StageDeviceMenu.rows([Self.builtIn, Self.usb]) == [
            StageDeviceMenu.Row(id: "", name: "System Default"),
            StageDeviceMenu.Row(id: "built-in", name: "MacBook Pro Microphone"),
            StageDeviceMenu.Row(id: "usb", name: "USB Mic"),
        ])
        #expect(StageDeviceMenu.rows([]) == [StageDeviceMenu.Row(id: "", name: "System Default")])
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(StageDeviceMenu.rows([], bundle: it).first?.name == "Predefinito di sistema")
    }

    @Test("during a count-in the menu checks the saved microphone, System Default included; after, the input the take listens on")
    func deviceMenuChecksTheSavedChoice() {
        let both = [Self.builtIn, Self.usb]
        #expect(StageDeviceMenu.checkedRow(countingIn: true, takeDevice: nil, savedUID: "", devices: both) == "")
        #expect(StageDeviceMenu.checkedRow(countingIn: true, takeDevice: nil, savedUID: "usb", devices: both) == "usb")
        #expect(StageDeviceMenu.checkedRow(countingIn: true, takeDevice: nil, savedUID: "gone", devices: both) == "", "a saved mic that's gone records on the default")
        #expect(StageDeviceMenu.checkedRow(countingIn: false, takeDevice: "USB Mic", savedUID: "usb", devices: both) == "usb")
        #expect(StageDeviceMenu.checkedRow(countingIn: false, takeDevice: nil, savedUID: "", devices: both) == "built-in")
        #expect(StageDeviceMenu.checkedRow(countingIn: false, takeDevice: "Unplugged Mic", savedUID: "", devices: both) == nil, "no row, not System Default")
    }

    @Test("the device menu's help says it changes the microphone Parola records from, and how to change it once recording")
    func deviceMenuHelp() throws {
        #expect(StageDeviceMenu.help(countingIn: true) == "Choose the microphone Parola records from")
        #expect(StageDeviceMenu.help(countingIn: false) == "Stop the recording to change the microphone")
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(StageDeviceMenu.help(countingIn: true, bundle: it) == "Scegli il microfono che Parola usa per registrare")
        #expect(StageDeviceMenu.help(countingIn: false, bundle: it) == "Ferma la registrazione per cambiare microfono")
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Meeting meter takes", .serialized)
    struct MeetingMeterTakeTests {
        @Test("a You lane whose microphone isn't in the take stays that way through Stop, and goes with the session")
        func lostMicStaysLostThroughStop() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 0.3, "Welcome.")])
                let model = makeRecordingModel("meeting-lane-stop")
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                let macFile = try makeTakeWAV("meeting-lane-stop-mac")
                defer { try? FileManager.default.removeItem(at: macFile) }
                model.takeCaptureOverride = { _ in MeteredCapture(file: macFile) }
                model.micAccessRequest = { false }
                model.micTrackCaptureOverride = { MeteredCapture(file: macFile) }

                model.startRecording(source: .systemAudio)
                let lost = await waitUntil(timeoutMs: 10_000) { model.takeMicTrackState == .unavailable }
                #expect(lost)
                let recording = await waitUntil(timeoutMs: 10_000) { model.recording?.state == .recording }
                #expect(recording)

                model.stopRecordingAndTranscribe()
                #expect(model.takeMicTrackState == .unavailable)
                #expect(model.takeMicLevels != nil)

                model.cancelCurrentWork()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
                model.forgetTakeSession()
                #expect(model.takeMicTrackState == nil)
                #expect(model.takeMicLevels == nil)
            }
        }
    }

    @MainActor
    @Suite("Lost microphone takes", .serialized)
    struct LostMicrophoneTakeTests {
        /// A meeting whose Mac audio keeps coming every 50 ms while your microphone sends `micReadings` and then nothing.
        private func meetingWithAQuietMic(_ label: String, micReadings: Int) async throws -> (model: AppModel, files: [URL]) {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            model.micTrackStallTicks = 3
            let macFile = try makeTakeWAV("\(label)-mac")
            let micFile = try makeTakeWAV("\(label)-mic")
            let mac = MeteredCapture(file: macFile)
            let mic = MeteredCapture(file: micFile)
            model.takeCaptureOverride = { _ in mac }
            model.micTrackCaptureOverride = { mic }
            model.startRecording(source: .systemAudio)
            let micUp = await waitUntil(timeoutMs: 10_000) { model.takeMicTrackState == .recording }
            guard micUp else { throw FixtureTakeDidNotStart() }
            for tick in 0..<80 {
                mac.levelMeter.record(0.3)
                if tick < micReadings { mic.levelMeter.record(0.3) }
                if model.takeMicTrackState?.isLost == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            return (model, [macFile, micFile])
        }

        @Test("a microphone that recorded and then went quiet reads as stopped, and stays so through Stop")
        func stalledMicIsStopped() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 0.3, "Welcome.")])
                let (model, files) = try await meetingWithAQuietMic("lost-mic-stopped", micReadings: 10)
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }
                model.selectedModel = "openai_whisper-tiny"
                #expect(model.takeMicTrackState == .stopped)

                model.stopRecordingAndTranscribe()
                #expect(model.takeMicTrackState == .stopped, "the lane keeps saying so through Finishing")
                model.cancelCurrentWork()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }

        /// A meeting whose microphone permission stood at `status` before the take; `answers` is the prompt's answer, counting each ask.
        private func meetingWithMicAccess(
            _ label: String, status: AVAuthorizationStatus, answers: Bool, asked: MicPrompts
        ) async throws -> (model: AppModel, files: [URL]) {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            let macFile = try makeTakeWAV("\(label)-mac")
            let micFile = try makeTakeWAV("\(label)-mic")
            model.takeCaptureOverride = { _ in MeteredCapture(file: macFile) }
            model.micTrackCaptureOverride = { MeteredCapture(file: micFile) }
            model.micAccessStatus = { status }
            model.micAccessRequest = {
                asked.count += 1
                return answers
            }
            model.startRecording(source: .systemAudio)
            let settled = await waitUntil(timeoutMs: 10_000) { model.takeMicTrackState == .unavailable }
            guard settled else { throw FixtureTakeDidNotStart() }
            return (model, [macFile, micFile])
        }

        @Test("a microphone refused before the take asks no more and says nothing; its lane says it isn't recorded", arguments: [
            AVAuthorizationStatus.denied, .restricted,
        ])
        func refusedBeforeTheTakeIsQuiet(_ status: AVAuthorizationStatus) async throws {
            try await withMocksCleared(.audioSource) {
                let asked = MicPrompts()
                let (model, files) = try await meetingWithMicAccess("mic-refused-before", status: status, answers: false, asked: asked)
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }
                await settle(for: .milliseconds(300))
                #expect(model.exportNotice == nil)
                #expect(asked.count == 0, "no prompt for a permission already refused")
                #expect(StageBand.lostMicNote(model.takeMicTrackState) == "Microphone not recorded")
                #expect(model.recording?.source == .systemAudio)
                await model.discardTake()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }

        @Test("a microphone refused at this take's own prompt is said once, as a microphone that fails is")
        func refusedAtThePromptSaysSo() async throws {
            try await withMocksCleared(.audioSource) {
                let asked = MicPrompts()
                let (model, files) = try await meetingWithMicAccess("mic-refused-now", status: .notDetermined, answers: false, asked: asked)
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }
                let notice = await waitForNotice(model)
                #expect(notice?.message == AppModel.micTrackMissingMessage())
                #expect(asked.count == 1)
                await model.discardTake()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }

        @Test("only a refused or restricted permission counts as refused before the take")
        func refusedStatuses() {
            #expect(AppModel.refusesMic(.denied))
            #expect(AppModel.refusesMic(.restricted))
            #expect(!AppModel.refusesMic(.notDetermined))
            #expect(!AppModel.refusesMic(.authorized))
        }

        @Test("a microphone that came up but never sent a sound reads as not recorded")
        func silentMicIsNotRecorded() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, files) = try await meetingWithAQuietMic("lost-mic-never", micReadings: 0)
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }
                #expect(model.takeMicTrackState == .unavailable)
                await model.discardTake()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }
    }

    @MainActor
    @Suite("Orphaned take categories", .serialized)
    struct OrphanedTakeCategoryTests {
        @Test("the sweep brings back a crashed Mac-audio take as a meeting, with no microphone beside it, and a microphone take as a note")
        func sweepFilesByTheTakeSource() async throws {
            let library = makeTempLibraryURL("orphan-categories")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let recovery = library.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            try ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
                .write(to: recovery.appendingPathComponent("take-import-cutoff"), atomically: true, encoding: .utf8)
            let mac = try makeTakeWAV("orphan-mac", seconds: 1, in: inflight, prefix: "parola-system")
            let mic = try makeTakeWAV("orphan-mic", seconds: 1.1, in: inflight, prefix: "parola-mic")
            for file in [mac, mic] {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: file.path)
            }

            let relaunched = AppModel(bootstrap: AppBootstrap(
                mode: .test, library: library, defaultsOverride: temporaryDefaults(), sideEffects: [], filePicker: TestFilePicker()
            ))
            await relaunched.inflightSweep?.value

            let listed = await relaunched.library.list()
            let macEntry = listed.first { $0.manifest.source == .systemAudio }
            let micEntry = listed.first { $0.manifest.source == .microphone }
            let meeting = try #require(macEntry)
            let note = try #require(micEntry)
            #expect(meeting.category == .meeting)
            #expect(meeting.title.hasPrefix("Meeting "))
            #expect(note.category == .transcription)
            #expect(note.title.hasPrefix("Recording "))
        }
    }

    @MainActor
    @Suite("Count-in category takes", .serialized)
    struct CountInCategoryTakeTests {
        @Test("Note picked during a Mac-audio count-in sticks: the take files as a note and still records your microphone")
        func countInNoteSticks() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                await installMockTranscriber(segments: [(0, 0.3, "Welcome.")])
                let model = makeRecordingModel("count-in-note")
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                let macFile = try makeTakeWAV("count-in-note-mac")
                let micFile = try makeTakeWAV("count-in-note-mic")
                defer {
                    try? FileManager.default.removeItem(at: macFile)
                    try? FileManager.default.removeItem(at: micFile)
                }
                let mac = MeteredCapture(file: macFile)
                model.takeCaptureOverride = { _ in mac }
                model.micTrackCaptureOverride = { MeteredCapture(file: micFile) }
                model.recordingCountInSeconds = 1

                model.startRecording(source: .systemAudio)
                let countIn = try #require(model.recording)
                #expect(countIn.isCountingIn)
                #expect(countIn.category == .meeting)
                TakeCategoryPicker.choose(.transcription, for: countIn.takeID, model: model)
                #expect(model.recording?.category == .transcription, "the click sticks")
                #expect(model.recording?.title.hasPrefix("Recording ") == true)

                let micUp = await waitUntil(timeoutMs: 10_000) { model.takeMicTrackState == .recording }
                #expect(micUp, "the meeting's microphone records though the take is now a note")
                #expect(model.activeTake?.category == .transcription)
                #expect(model.recording?.category == .transcription)
                #expect(model.recording?.title.hasPrefix("Recording ") == true)
                mac.levelMeter.record(0.4)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)

                model.stopRecordingAndTranscribe()
                let entry = try #require(await landedEntry(model, timeoutMs: 15_000))
                #expect(entry.category == .transcription)
                #expect(entry.title.hasPrefix("Recording "))
            }
        }

        @Test("Meeting picked during a microphone count-in sticks, and the take files as a meeting")
        func countInMeetingSticks() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("count-in-meeting")
                model.useStreaming = false
                let audio = try makeTakeWAV("count-in-meeting")
                defer { try? FileManager.default.removeItem(at: audio) }
                model.takeCaptureOverride = { _ in StubSource(url: audio) }
                model.recordingCountInSeconds = 1

                model.startRecording(source: .microphone)
                let countIn = try #require(model.recording)
                TakeCategoryPicker.choose(.meeting, for: countIn.takeID, model: model)
                #expect(model.recording?.category == .meeting)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)

                let handedOver = await waitUntil(timeoutMs: 10_000) { model.activeTake != nil }
                #expect(handedOver)
                #expect(model.activeTake?.category == .meeting)
                #expect(model.recording?.category == .meeting)
                #expect(model.takeMicTrackState == nil, "a microphone take has no second track")
                await model.discardTake()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }

        @Test("a cancelled count-in lets its choice go, so the next take files by its source")
        func cancelledCountInForgetsItsChoice() {
            let model = makeRecordingModel("count-in-cancel")
            model.recordingCountInSeconds = 60
            model.startRecording(source: .systemAudio)
            let takeID = model.recording?.takeID ?? -1
            TakeCategoryPicker.choose(.transcription, for: takeID, model: model)
            #expect(model.recording?.category == .transcription)

            model.cancelArmingTake()

            #expect(model.recording == nil)
            #expect(model.pendingRecordingCategory == nil)
            model.startRecording(source: .systemAudio)
            #expect(model.recording?.category == .meeting)
            model.cancelArmingTake()
        }

        @Test("a second Record turned away during a count-in changes nothing about the take: it keeps the category and the apps it was given")
        func refusedRecordDuringCountIn() async throws {
            let model = makeRecordingModel("count-in-second-record")
            model.recordingCountInSeconds = 1
            model.meetingRecordsMicrophone = false
            model.meetingCaptureAppOnly = true
            model.pendingCaptureBundleIDs = ["us.zoom.xos"]
            model.pendingRecordingCategory = .meeting
            try armMeteredTake(model, source: .systemAudio)
            let countingIn = model.recording?.isCountingIn == true
            #expect(countingIn)
            let takeID = try #require(model.recording?.takeID)
            TakeCategoryPicker.choose(.transcription, for: takeID, model: model)

            model.startRecording(source: .microphone)
            model.startMeetingRecording(appName: "Microsoft Teams")

            let capturing = await waitUntil(timeoutMs: 6_000) { model.recording?.state == .recording }
            #expect(capturing)
            #expect(model.activeTake?.category == .transcription)
            #expect(model.activeTake?.captureTargets == ["us.zoom.xos"])
            await model.discardTake()
        }
    }

    @MainActor
    @Suite("Stage device menu takes", .serialized)
    struct StageDeviceMenuTakeTests {
        @Test("the device menu picks the microphone while the take counts in, and the take opens that one; once it starts, it only shows it")
        func countInPicksTheMicrophone() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("device-count-in")
                model.useStreaming = false
                let audio = try makeTakeWAV("device-count-in")
                defer { try? FileManager.default.removeItem(at: audio) }
                var openedOn: [String?] = []
                model.takeCaptureOverride = { _ in
                    openedOn.append(model.preferredInputDeviceUID)
                    return StubSource(url: audio)
                }
                model.inputDeviceUID = "built-in"
                model.recordingCountInSeconds = 1

                model.startRecording(source: .microphone)
                #expect(model.recording?.isCountingIn == true)
                #expect(model.chooseTakeInput("usb"))
                #expect(model.inputDeviceUID == "usb", "written where the Microphone setting writes it")

                let opened = await waitUntil(timeoutMs: 10_000) { !openedOn.isEmpty }
                #expect(opened)
                #expect(openedOn == ["usb"])
                #expect(!model.chooseTakeInput("built-in"))
                #expect(model.inputDeviceUID == "usb", "a take past its count-in keeps the input it opened")

                await model.discardTake()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }

        @Test("System Default in the device menu during a count-in sets the saved microphone back to it, and the take opens the default")
        func countInPicksSystemDefault() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("device-count-in-default")
                model.useStreaming = false
                let audio = try makeTakeWAV("device-count-in-default")
                defer { try? FileManager.default.removeItem(at: audio) }
                var openedOn: [String?] = []
                model.takeCaptureOverride = { _ in
                    openedOn.append(model.preferredInputDeviceUID)
                    return StubSource(url: audio)
                }
                model.inputDeviceUID = "usb"
                model.recordingCountInSeconds = 1

                model.startRecording(source: .microphone)
                #expect(model.chooseTakeInput(""))
                #expect(model.inputDeviceUID == "")

                let opened = await waitUntil(timeoutMs: 10_000) { !openedOn.isEmpty }
                #expect(opened)
                #expect(openedOn == [nil])

                await model.discardTake()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }
    }
}

/// Set by an observation's change handler and read once the change is made; the test waits on nothing else.
private final class LaneObservation: @unchecked Sendable {
    var fired = false
}

/// How many times a take asked for the microphone; set and read on the main actor only.
@MainActor
private final class MicPrompts {
    var count = 0
}

/// A capture whose meter reads whatever the test records into it.
private actor MeteredCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    nonisolated let file: URL

    init(file: URL) {
        self.file = file
    }

    func start() async throws {}
    func prepare() async throws -> URL { file }
    func cancel() async {}
    func inFlightURL() async -> URL? { file }
}

/// Feeds both sides of a meeting a buffer every 100 ms, the Mac's silent and yours at `micLevel`, until cancelled.
private func feed(mac: LevelMeter, mic: LevelMeter, micLevel: Float) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            mac.record(0)
            mic.record(micLevel)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Meeting defaults takes", .serialized)
    struct MeetingDefaultsTakeTests {
        private func makeModel(_ label: String) throws -> (model: AppModel, audio: URL) {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            let audio = try makeTakeWAV(label)
            model.takeCaptureOverride = { _ in StubSource(url: audio) }
            return (model, audio)
        }

        private func end(_ model: AppModel) async {
            await model.discardTake()
            let released = await waitUntil { !model.recordingActive }
            #expect(released)
        }

        @Test("a take that names no category files by its source: Mac audio as a meeting, the microphone as a note")
        func recordFilesBySource() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-source")
                defer { try? FileManager.default.removeItem(at: audio) }

                model.startRecording(source: .systemAudio)
                #expect(model.activeTake?.category == .meeting)
                #expect(model.recording?.category == .meeting)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)
                await end(model)

                model.startRecording(source: .microphone)
                #expect(model.activeTake?.category == .transcription)
                #expect(model.recording?.category == .transcription)
                await end(model)
            }
        }

        @Test("a Record that names its category keeps it, and the next take that names none goes back to its source's")
        func namedCategoryWins() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-named")
                defer { try? FileManager.default.removeItem(at: audio) }

                model.pendingRecordingCategory = .transcription
                model.startRecording(source: .systemAudio)
                #expect(model.activeTake?.category == .transcription)
                await end(model)

                model.startRecording(source: .systemAudio)
                #expect(model.activeTake?.category == .meeting)
                await end(model)
            }
        }

        @Test("a count-in already shows a Mac-audio take as a meeting, and the take it hands over to stays one")
        func countInFilesBySource() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-count-in")
                defer { try? FileManager.default.removeItem(at: audio) }
                model.recordingCountInSeconds = 1

                model.startRecording(source: .systemAudio)
                #expect(model.recordingCountdown != nil)
                #expect(model.recording?.category == .meeting)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)

                let handedOver = await waitUntil(timeoutMs: 10_000) { model.activeTake != nil }
                #expect(handedOver)
                #expect(model.activeTake?.category == .meeting)
                #expect(model.recording?.category == .meeting)
                await end(model)
            }
        }

        @Test("the menu bar's Record System Audio records a meeting")
        func menuBarSystemAudioIsAMeeting() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-menu-bar")
                defer { try? FileManager.default.removeItem(at: audio) }
                model.showMenuBarExtra = false
                let controller = MenuBarController()
                controller.bind(model)
                let snapshot = MenuBarController.MenuSnapshot(
                    mode: .full, dictateTitle: "", showsDictation: false, showsMicRecording: true, showsSystemAudio: true
                )
                let items = MenuBarController.items(for: snapshot, target: controller)
                let submenu = items.first { $0.title == "Record Meeting" }?.submenu
                let found = submenu?.items.first { $0.title == "Record System Audio" }
                let systemAudio = try #require(found)
                let action = try #require(systemAudio.action)

                _ = controller.perform(action, with: systemAudio)

                #expect(model.activeTake?.source == .systemAudio)
                #expect(model.activeTake?.category == .meeting)
                await end(model)
            }
        }

        private func startRecording(
            _ server: ParolaAutomationServer, _ model: AppModel, _ args: [String: AutomationValue]
        ) async throws -> [String: AutomationValue] {
            let commands = Dictionary(uniqueKeysWithValues: server.recordingCommands().map { ($0.name, $0) })
            let command = try #require(commands["startRecording"])
            let context = AutomationContext(model: model, server: server)
            let reply = try await command.handler(try command.validate(AutomationArgs(args)), context)
            guard case .object(let fields) = reply else { throw AutomationError.precondition("startRecording did not reply with an object") }
            return fields
        }

        @Test("the bridge's startRecording files Mac audio as a meeting unless it names a category, and says which")
        func bridgeFilesBySource() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-bridge")
                defer { try? FileManager.default.removeItem(at: audio) }
                let server = try ParolaAutomationServer(model: model)

                let plain = try await startRecording(server, model, ["source": .string("systemAudio")])
                #expect(model.activeTake?.category == .meeting)
                #expect(plain["category"] == .string("meeting"))
                await end(model)

                let named = try await startRecording(server, model, ["source": .string("systemAudio"), "category": .string("transcription")])
                #expect(model.activeTake?.category == .transcription)
                #expect(named["category"] == .string("transcription"))
                await end(model)

                let mic = try await startRecording(server, model, [:])
                #expect(model.activeTake?.category == .transcription)
                #expect(mic["category"] == .string("transcription"))
                await end(model)
                withExtendedLifetime(server) {}
            }
        }

        @Test("the bridge's startRecording takes only a real category, and refuses a word like note before any take starts")
        func bridgeRefusesAnUnknownCategory() async throws {
            let model = makeRecordingModel("meeting-default-bridge-enum")
            let server = try ParolaAutomationServer(model: model)
            let commands = Dictionary(uniqueKeysWithValues: server.recordingCommands().map { ($0.name, $0) })
            let command = try #require(commands["startRecording"])
            for category in ["transcription", "meeting", "dictation"] {
                do {
                    _ = try command.validate(AutomationArgs(["source": .string("systemAudio"), "category": .string(category)]))
                } catch {
                    Issue.record("\(category) should be accepted: \(error)")
                }
            }
            for category in ["note", "Meeting", ""] {
                do {
                    _ = try command.validate(AutomationArgs(["category": .string(category)]))
                    Issue.record("\(category) should be refused")
                } catch AutomationError.invalidArgs(let field, _) {
                    #expect(field == "category")
                } catch {
                    Issue.record("\(category) failed with \(error)")
                }
            }
            #expect(model.recording == nil)
            withExtendedLifetime(server) {}
        }

        @Test("a meeting stays unwarned while your microphone hears you and the Mac is quiet, and warns once both go quiet")
        func meetingSilenceCountsBothSides() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("meeting-silence")
                model.useStreaming = false
                model.silenceRule = AppModel.SilenceRule(microphone: 0.5, macAudioBeforeSound: 0.5, macAudioAfterSound: 0.5)
                let macFile = try makeTakeWAV("meeting-silence-mac")
                let micFile = try makeTakeWAV("meeting-silence-mic")
                defer {
                    try? FileManager.default.removeItem(at: macFile)
                    try? FileManager.default.removeItem(at: micFile)
                }
                let mac = MeteredCapture(file: macFile)
                let mic = MeteredCapture(file: micFile)
                model.takeCaptureOverride = { _ in mac }
                model.micTrackCaptureOverride = { mic }
                let talking = feed(mac: mac.levelMeter, mic: mic.levelMeter, micLevel: 0.5)

                model.startRecording(source: .systemAudio)
                let micUp = await waitUntil(timeoutMs: 10_000) { model.takeMicTrackState == .recording }
                #expect(micUp)
                var warned = false
                for _ in 0..<60 {
                    warned = warned || model.recordingIsSilent
                    await settle(for: .milliseconds(50))
                }
                #expect(!warned, "your voice is sound enough: the Mac side's quiet is the others listening")
                talking.cancel()

                let quiet = feed(mac: mac.levelMeter, mic: mic.levelMeter, micLevel: 0)
                // A few 750 ms ticks of the watch, and a slow host can stall the main actor for seconds.
                let silent = await waitUntil(timeoutMs: 15_000) { model.recordingIsSilent }
                #expect(silent)
                #expect(model.takeMicTrackState == .recording)
                quiet.cancel()
                await end(model)
            }
        }
    }
}
