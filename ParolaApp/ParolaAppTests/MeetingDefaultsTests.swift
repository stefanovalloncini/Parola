import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore

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
        #expect(!meeting.micOff)

        let plain = StageBand.tape(levels: mac, micLevels: nil, micState: nil, markers: [], paused: false)
        #expect(plain.levels == meeting.levels)
        #expect(plain.micLevels == nil)
    }

    @Test("the You lane greys once the microphone isn't in the take, and stays, flat, after Stop")
    func offLane() {
        #expect(StageBand.micOff(.unavailable))
        #expect(!StageBand.micOff(.starting))
        #expect(!StageBand.micOff(.recording))
        #expect(!StageBand.micOff(nil), "Stop lets the state go and keeps the levels: the lane stays as it was")
        #expect(StageBand.offLaneStrength < 1)

        let mac = TakeLevelHistory()
        let mic = TakeLevelHistory()
        mac.append(0.5)
        mic.append(0)
        #expect(StageBand.tape(levels: mac, micLevels: mic, micState: .unavailable, markers: [], paused: false).micOff)
        #expect(StageBand.tape(levels: mac, micLevels: mic, micState: nil, markers: [], paused: false).micLevels == [0])
    }

    @Test("the bars are drawn again when the You lane comes, goes or stops, never for a frame that only slides them")
    func tapeRedrawsForTheYouLane() {
        let one = StageTape(levels: [0.1], flags: [], newest: 4, paused: false)
        let two = StageTape(levels: [0.1], micLevels: [0.2], flags: [], newest: 4, paused: false)
        #expect(one != two)
        #expect(two != StageTape(levels: [0.1], micLevels: [0.2], micOff: true, flags: [], newest: 4, paused: false))
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

    @Test("the device menu's words have their Italian")
    func deviceMenuItalian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(String(localized: "Choose the microphone for this recording", bundle: it) == "Scegli il microfono per questa registrazione")
    }
}

extension TranscriberMockSuites {
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

                model.cancelCurrentWork()
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
            }
        }
    }
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
            model.cancelCurrentWork()
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
