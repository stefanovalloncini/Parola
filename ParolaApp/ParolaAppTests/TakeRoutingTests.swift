import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A live session that kept its audio before it failed.
private actor KeptAudioSession: StreamingTranscriber {
    let audio: URL
    init(audio: URL) { self.audio = audio }
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
    func cancel() async {}
    func currentModel() async -> String? { nil }
    func recordingAudioURL() async -> URL? { audio }
}

/// A take whose file stopped taking writes partway.
private struct CutShortCapture: LiveAudioSource {
    let url: URL
    func start() async throws {}
    func prepare() async throws -> URL { throw CaptureInterrupted(url: url, reason: "the disk is full") }
    func cancel() async {}
}

@MainActor
private final class BeepCounter {
    var count = 0
}

/// A capture whose start waits until the test lets it go.
private actor HeldStartCapture: LiveAudioSource {
    nonisolated let levelMeter = LevelMeter()
    private let file: URL
    private var holds = true
    private var held: CheckedContinuation<Void, Never>?

    init(file: URL) { self.file = file }

    func start() async throws {
        if holds { await withCheckedContinuation { held = $0 } }
    }

    func prepare() async throws -> URL { file }

    func letGo() {
        holds = false
        held?.resume()
        held = nil
    }

    func cancel() async {}
}

@MainActor
@Suite("Take routing")
struct TakeRoutingTests {
    private func makeModel(_ label: String = "take-routing") -> AppModel {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL(label), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
        model.freeDiskSpaceProvider = { 50_000_000_000 }
        model.cardMetadataOperation = { _ in nil }
        return model
    }

    private func seedEntry(in model: AppModel, title: String, audio: URL? = nil) async throws -> LibraryEntry {
        let entry = try await model.library.add(
            transcript: Self.transcript("an older take"),
            audioSource: audio,
            title: title
        )
        await model.refreshLibraryAndWait()
        return entry
    }

    private static func transcript(_ text: String) -> Transcript {
        Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)], language: "en", modelName: "stub")
    }

    // MARK: - The Stage is a page

    @Test("starting a take shows the Stage, and the library is one click away while it records")
    func browseDuringTake() throws {
        let wav = try tempWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeModel()
        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
        #expect(model.route == .recording)
        #expect(model.stageIsVisible)
        #expect(ContentRoutes.routeID(for: model) == .stage)

        model.goHome()
        #expect(model.isBrowsingLibrary)
        #expect(!model.stageIsVisible)
        #expect(model.recording?.isCapturing == true)

        model.openStatistics()
        #expect(model.route == .statistics)
        model.openRecentlyDeleted()
        #expect(model.route == .recentlyDeleted)
        #expect(model.recording?.isCapturing == true)

        #expect(model.showStage())
        #expect(model.route == .recording)
        #expect(model.phase == .idle, "the take never writes the phase")
    }

    @Test("opening an entry during a take is allowed and leaves the take running")
    func openEntryDuringTake() async throws {
        let wav = try tempWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeModel()
        let beeps = BeepCounter()
        model.refusalBeep = { beeps.count += 1 }
        let entry = try await seedEntry(in: model, title: "Weekly sync")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))

        let opened = try await model.openEntry(entry.id)

        #expect(opened.text == "an older take")
        #expect(model.selectedEntryID == entry.id)
        #expect(model.route == .transcript)
        #expect(model.recording?.isCapturing == true)
        #expect(model.activeTake != nil)

        model.clearLoadedEntry()
        #expect(model.openEntryFromLibrary(entry.id, inNewWindow: false))
        let reopened = await waitUntil { model.selectedEntryID == entry.id }
        #expect(reopened)
        #expect(beeps.count == 0)
    }

    @Test("a take that lands while another page shows is saved without taking the screen")
    func backgroundLanding() {
        let policy = RunLanding.Kind.backgroundTake.policy
        let recording = RunLanding.Kind.recording.policy
        #expect(policy.selection == .none)
        #expect(policy.announces)
        #expect(policy.card == recording.card)
        #expect(policy.export == recording.export)
        #expect(policy.autoSend == recording.autoSend)
        #expect(policy.sound == recording.sound)
    }

    @Test("the Stage shows only while a take has a session, and the page comes back when it ends")
    func stageFollowsTheSession() {
        let model = makeModel()
        #expect(!model.showStage())
        #expect(model.route == .transcript, "no take, no Stage")

        model.installTestTake(source: .microphone)
        #expect(model.route == .recording)

        model.endTestTake()
        #expect(model.recording == nil)
        #expect(model.route == .transcript)
        #expect(model.isBrowsingLibrary)
    }

    @Test("a count-in shows the Stage from its first number")
    func countInShowsTheStage() {
        let model = makeModel()
        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        #expect(model.recordingCountdown == 60)
        #expect(model.route == .recording)

        model.cancelRecordingCountdown()
        #expect(model.route == .transcript)
    }

    @Test("a reset ends a count-in along with everything else")
    func resetEndsACountIn() {
        let model = makeModel()
        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        #expect(model.takeIsRunning)

        model.cancelAllTasks()

        #expect(model.recordingCountdown == nil)
        #expect(!model.takeIsRunning)
        #expect(model.recording == nil)
    }

    // MARK: - Landing

    @Test("a live take that finishes on its Stage opens as the transcript")
    func liveTakeLandsInPlace() async throws {
        let model = makeModel()
        model.installTestTake(source: .microphone)

        await model.handleStreamingEvent(.finished(Self.transcript("said on the stage")))

        #expect(model.route == .transcript)
        #expect(model.phase == .ready)
        #expect(model.transcript?.text == "said on the stage")
        let saved = await landedEntry(model)
        #expect(saved?.title.hasPrefix("Recording ") == true)
        #expect(model.arrivalNotice == nil)
        #expect(!model.showStage(), "a take in the library has nothing left on its Stage")
    }

    @Test("a live take that finishes while the library shows is saved with a toast and leaves the page alone")
    func liveTakeLandsInTheBackground() async throws {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        model.goHome()

        await model.handleStreamingEvent(.finished(Self.transcript("said while browsing")))

        #expect(model.transcript == nil)
        #expect(model.route == .transcript)
        #expect(model.isBrowsingLibrary)
        #expect(!model.takeIsRunning)
        let saved = try #require(await landedEntry(model))
        let announced = await waitUntil { model.arrivalNotice?.state == .saved(saved.id) }
        #expect(announced)
        let notice = try #require(model.arrivalNotice)
        #expect(notice.origin == .take)
        #expect(notice.savedTitle() == "Saved \(notice.name)")
        #expect(notice.name.hasPrefix("Recording "))
    }

    @Test("the toast for a take saved out of sight reads in Italian too")
    func backgroundToastInItalian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(ArrivalNotice.savedTitle(name: "Riunione", origin: .take, bundle: italian) == "Salvato Riunione")
    }

    // MARK: - Failures

    @Test("a take that fails while an entry is open leaves the entry alone, and its Retry outlives the phase")
    func failedTakeKeepsThePage() async throws {
        let audio = try tempWAV("kept")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeModel()
        let entry = try await seedEntry(in: model, title: "Weekly sync")
        model.installTestTake(source: .microphone)
        _ = try await model.openEntry(entry.id)
        #expect(model.phase == .ready)

        await model.handleStreamingEvent(.failed("The model stopped."), session: KeptAudioSession(audio: audio))

        #expect(model.phase == .ready)
        #expect(model.selectedEntryID == entry.id)
        #expect(model.transcript?.text == "an older take")
        #expect(model.route == .transcript)
        let failed: Bool = if case .failed = model.recording?.state { true } else { false }
        #expect(failed)
        #expect(model.recording?.failure?.audioURL == audio)
        #expect(model.exportNotice?.tone == .failure, "a failure off the Stage is told where the user is")

        model.phase = .idle
        #expect(model.recording?.failure?.audioURL == audio, "a phase change never costs a take its Retry")
    }

    @Test("a take that fails on its Stage shows it there, and Dismiss gives the page back")
    func failedTakeOnTheStage() async throws {
        let audio = try tempWAV("kept-on-stage")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeModel()
        model.installTestTake(source: .microphone)

        await model.handleStreamingEvent(.failed("The model stopped."), session: KeptAudioSession(audio: audio))

        #expect(model.route == .recording)
        #expect(model.phase == .idle)
        #expect(model.exportNotice == nil)
        #expect(model.recording?.failure?.audioURL == audio)
        #expect(model.recording?.failure?.title.hasPrefix("Recording ") == true)

        model.dismissTakeFailure()

        #expect(model.recording == nil)
        #expect(model.route == .transcript)
    }

    @Test("a take cut short while an entry is open leaves the entry alone")
    func cutShortTakeKeepsThePage() async throws {
        let wav = try tempWAV("cut-short")
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeModel()
        let entry = try await seedEntry(in: model, title: "Weekly sync")
        model.installTestTake(source: .microphone, liveSource: CutShortCapture(url: wav))
        _ = try await model.openEntry(entry.id)

        model.stopRecordingAndTranscribe()
        let failed = await waitUntil { if case .failed = model.recording?.state { true } else { false } }

        #expect(failed)
        #expect(model.phase == .ready)
        #expect(model.selectedEntryID == entry.id)
        #expect(model.recording?.failure?.audioURL == wav)
        await waitUntil { !model.hasPendingTakeWork }
    }

    @Test("a start that drops its capture after a stop leaves the page another run took")
    func droppedStartLeavesThePage() async throws {
        let file = try tempWAV("held-start")
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = HeldStartCapture(file: file)
        let model = makeModel()
        model.useStreaming = false
        model.takeCaptureOverride = { _ in capture }
        model.startRecording(source: .microphone)
        let starting = await waitUntil { model.activeTake?.captureRequested == true }
        #expect(starting)

        model.cancelCurrentWork()
        #expect(model.stopHeldForStartup)
        model.transcript = Self.transcript("opened meanwhile")
        model.phase = .ready
        await capture.letGo()

        let settled = await waitUntil { !model.recordingActive }
        #expect(settled)
        #expect(model.phase == .ready)
        #expect(model.transcript?.text == "opened meanwhile")
    }

    // MARK: - What waits for a take

    @Test("a meeting that starts during a take never raises the prompt over it")
    func meetingPromptWaitsForTheTake() {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        model.meetingDetector.isEnabled = true

        model.meetingDetector.fire(appName: "Acme Conference")

        #expect(model.meetingDetectedApp == nil)
        #expect(model.detectedMeetingAppName == "Acme Conference", "the Record menu still offers it")
    }

    @Test("Live Captions that can't start during a take leave the phase alone")
    func liveCaptionsRefusalWaitsForTheTake() {
        let model = makeModel()
        let captions = LiveCaptionsController(showsPanel: false)
        model.liveCaptions = captions
        model.selectedModel = "nvidia_parakeet-tdt-0.6b-v3"
        #expect(model.liveCaptionsUnavailableReason != nil)
        model.installTestTake(source: .microphone)

        model.toggleLiveCaptions()

        #expect(model.phase == .idle)
        withExtendedLifetime(captions) {}
    }

    @Test("a file opened during a take waits for it, and says so")
    func fileOpenWaitsForTheTake() {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        let file = URL(fileURLWithPath: "/tmp/parola-take-routing-arrival.wav")

        model.transcribe(fileURL: file)

        #expect(model.deferredArrivals == [file])
        #expect(model.exportNotice?.message == "Finish the recording first.")
        #expect(model.exportNotice?.tone == .info)
        #expect(model.route == .recording)
    }

    @Test("running an entry again during a take is refused, and says so")
    func rerunWaitsForTheTake() async throws {
        let audio = try tempWAV("entry-audio")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeModel()
        let entry = try await seedEntry(in: model, title: "Weekly sync", audio: audio)
        _ = try await model.openEntry(entry.id)
        #expect(model.canRetranscribeSelectedEntry)
        model.installTestTake(source: .microphone)

        model.transcribeLoadedEntry()

        #expect(model.retranscribeRequest == nil)
        #expect(model.fileTranscribeTask == nil)
        #expect(model.exportNotice?.message == "Finish the recording first.")
    }

    @Test("the Transcribe File shortcut is refused while a take records")
    func transcribeFileIntentWaitsForTheTake() async throws {
        let audio = try tempWAV("intent-file")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeModel()
        model.installTestTake(source: .microphone)

        var refusal: IntentActionError?
        do {
            _ = try await model.transcribeFileFromIntent(audio)
        } catch let error as IntentActionError {
            refusal = error
        }

        #expect(refusal == .recordingInProgress)
        #expect(model.fileTranscribeTask == nil)
    }

    // MARK: - Bridge

    @Test("the bridge shows the Stage only while a take has a session")
    func bridgeRouteToTheStage() async throws {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.settingsCommands().map { ($0.name, $0) })
        let command = try #require(commands["setRoute"])
        let args = try command.validate(AutomationArgs(["route": .string("recording")]))

        var refused = false
        do {
            _ = try await command.handler(args, context)
        } catch is AutomationError {
            refused = true
        }
        #expect(refused)
        #expect(model.route == .transcript)

        model.installTestTake(source: .microphone)
        model.goHome()
        _ = try await command.handler(args, context)
        #expect(model.route == .recording)
        withExtendedLifetime(server) {}
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Take landing", .serialized)
    struct TakeLandingTests {
        private func seedEntry(in model: AppModel, audio: URL) async throws -> LibraryEntry {
            let entry = try await model.library.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                    language: "en",
                    modelName: "stub"
                ),
                audioSource: audio,
                title: "Weekly sync"
            )
            await model.refreshLibraryAndWait()
            return entry
        }

        @Test("a take stopped on its Stage opens as the transcript")
        func fileTakeLandsInPlace() async throws {
            let wav = try tempWAV("stage-take")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "said on the stage")])
                let model = makeRecordingModel("take-landing-stage")
                model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))

                model.stopRecordingAndTranscribe()
                let landed = await waitUntil { model.transcript?.text == "said on the stage" }

                #expect(landed)
                #expect(model.route == .transcript)
                #expect(model.phase == .ready)
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("a Retry from the working file that fails again says so in the page's banner, with Retry")
        func retryFromTheWorkingFileFailsInTheBanner() async throws {
            let wav = try tempWAV("retry-again")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeRecordingModel("take-landing-retry-again")
                model.beforeLandingSave = { throw URLError(.cannotWriteToFile) }
                model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
                model.stopRecordingAndTranscribe()
                let failed = await waitUntil { model.recording?.failure != nil && !model.hasPendingTakeWork }
                #expect(failed)
                let title = try #require(model.recording?.failure?.title)

                model.retryFailedTake()
                let failedAgain = await waitUntil { model.canRetryFailedTranscription && !model.hasPendingTakeWork }

                #expect(failedAgain)
                #expect(model.recording == nil)
                #expect(model.route == .transcript)
                #expect(model.failedSourceName == title)
                #expect(model.failedTakeRetry?.audioURL == wav)
            }
        }

        @Test("a take stopped from another page transcribes out of sight and leaves the open entry and its player alone")
        func fileTakeLandsInTheBackground() async throws {
            let wav = try tempWAV("background-take")
            let entryAudio = try tempWAV("entry")
            defer {
                try? FileManager.default.removeItem(at: wav)
                try? FileManager.default.removeItem(at: entryAudio)
            }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "said while reading")])
                let model = makeRecordingModel("take-landing-background")
                let entry = try await seedEntry(in: model, audio: entryAudio)
                model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
                _ = try await model.openEntry(entry.id)
                let playing = model.sourceFileURL

                model.stopRecordingAndTranscribe()
                let announced = await waitUntil { model.arrivalNotice != nil }

                #expect(announced)
                #expect(model.arrivalNotice?.origin == .take)
                #expect(model.selectedEntryID == entry.id)
                #expect(model.transcript?.text == "an older take")
                #expect(model.sourceFileURL == playing)
                #expect(model.phase == .ready)
                #expect(model.route == .transcript)
                let saved = await model.library.list()
                #expect(saved.count == 2)
                await waitUntil { !model.hasPendingTakeWork }
            }
        }
    }
}
