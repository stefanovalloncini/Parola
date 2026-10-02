import AppKit
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

    @Test("someone who leaves the Stage during a count-in keeps their page when the take begins")
    func countInLeftKeepsThePage() async throws {
        let file = try tempWAV("count-in-left")
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = HeldStartCapture(file: file)
        let model = makeModel()
        model.useStreaming = false
        model.takeCaptureOverride = { _ in capture }
        model.recordingCountInSeconds = 1
        model.startRecording(source: .microphone)
        #expect(model.route == .recording)

        model.openStatistics()
        let began = await waitUntil { model.activeTake != nil }

        #expect(began)
        #expect(model.route == .statistics)
        #expect(model.takeIsRunning)
        model.cancelCurrentWork()
        await capture.letGo()
        await waitUntil { !model.recordingActive }
    }

    @Test("a reset clears a take left on its Stage and goes back to the library")
    func resetForgetsAFailedTake() async {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        await model.handleStreamingEvent(.failed("The model stopped."))
        #expect(model.route == .recording)

        model.cancelAllTasks()
        model.forgetTakeSession()

        #expect(model.recording == nil)
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

    // MARK: - Where the main window is

    @Test("the main window's presence reads the real window: none is closed, one out of sight is hidden")
    func mainWindowPresence() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("presence"))
        #expect(model.mainWindowPresence == .closed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        model.mainWindow = window
        #expect(model.mainWindowPresence == .hidden)
        withExtendedLifetime(window) {}
    }

    @Test("a take that stops while its window is minimized or hidden still lands on its Stage")
    func hiddenWindowKeepsTheStage() async throws {
        let model = makeModel()
        model.mainWindowPresenceOverride = .hidden
        model.installTestTake(source: .microphone)
        #expect(model.stageIsVisible)

        await model.handleStreamingEvent(.finished(Self.transcript("said while minimized")))

        #expect(model.route == .transcript)
        #expect(model.transcript?.text == "said while minimized")
        #expect(model.arrivalNotice == nil)
        await waitUntil { !model.hasPendingTakeWork }
    }

    @Test("a take that stops after the main window closed lands in the library with a toast")
    func closedWindowLandsInTheBackground() async throws {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        model.mainWindowPresenceOverride = .closed
        #expect(!model.stageIsVisible)

        await model.handleStreamingEvent(.finished(Self.transcript("said with the window closed")))

        #expect(model.transcript == nil)
        #expect(model.route == .transcript)
        let announced = await waitUntil { model.arrivalNotice?.origin == .take }
        #expect(announced)
    }

    @Test("a toast raised while the window is out of sight waits for the user before it counts down, and its window tells it, not a poll")
    func toastWaitsToBeSeen() async throws {
        let model = makeModel()
        let notice = ArrivalNotice(failed: URL(fileURLWithPath: "/tmp/memo.wav"), reason: "unreadable")
        model.arrivalNotice = notice
        let hosted = HostedWindow(ArrivalToast(notice: notice, dismissAfter: .milliseconds(300)).environment(model), width: 600, height: 120)
        defer { hosted.close() }
        func reader(in view: NSView) -> WindowShownReader.ReaderView? {
            view as? WindowShownReader.ReaderView ?? view.subviews.lazy.compactMap(reader(in:)).first
        }
        let found = reader(in: hosted.host)
        let shown = try #require(found)
        hosted.window.orderOut(nil)
        shown.onChange?(false)

        await settle(for: .milliseconds(600))
        #expect(model.arrivalNotice == notice, "nobody has seen it yet")

        shown.onChange?(true)
        let dismissed = await waitUntil { model.arrivalNotice == nil }
        #expect(dismissed)
    }

    @Test("the arrival toast's countdown leaves a toast that changed meanwhile")
    func arrivalCountdownKeepsANewerToast() async {
        let model = makeModel()
        let first = ArrivalNotice(failed: URL(fileURLWithPath: "/tmp/one.wav"), reason: "unreadable")
        let second = ArrivalNotice(failed: URL(fileURLWithPath: "/tmp/two.wav"), reason: "unreadable")
        model.arrivalNotice = first
        let countdown = Task { await model.dismissArrivalNotice(first, after: .milliseconds(50)) }
        model.arrivalNotice = second
        await countdown.value
        #expect(model.arrivalNotice == second)
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
        let take = try #require(model.recording?.takeID)
        let notice = try #require(model.exportNotice)
        let titles = notice.actions.map(\.title)
        let handlers = notice.actions.map(\.handler)
        #expect(titles == ["Retry", "Show"])
        #expect(handlers == [.retryTake(take), .showTake(take)])

        model.phase = .idle
        #expect(model.recording?.failure?.audioURL == audio, "a phase change never costs a take its Retry")

        let show = try #require(notice.actions.last)
        model.performNoticeAction(show)
        #expect(model.route == .recording, "Show goes back to the failed take's Stage")
        #expect(model.exportNotice == nil)
        await waitUntil { !model.hasPendingTakeWork }
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
        await waitUntil { !model.hasPendingTakeWork }
    }

    @Test("a failed take's notice goes when the next take starts")
    func failureNoticeGoesWithItsTake() async throws {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        model.goHome()
        await model.handleStreamingEvent(.failed("The model stopped."))
        let titles = model.exportNotice?.actions.map(\.title)
        #expect(titles == ["Show"], "nothing kept, so nothing to retry")

        model.installTestTake(source: .microphone)

        #expect(model.exportNotice == nil)
    }

    @Test("new work started while a failed take shows gives the page back to it")
    func newWorkLeavesAFailedStage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parola-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let subtitles = folder.appendingPathComponent("talk.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nsubtitled words\n".write(to: subtitles, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.installTestTake(source: .microphone)
        await model.handleStreamingEvent(.failed("The model stopped."))
        #expect(model.route == .recording)

        model.importSubtitle(fileURL: subtitles)

        #expect(model.route == .transcript)
        #expect(model.transcript?.text == "subtitled words")
        let kept: Bool = if case .failed = model.recording?.state { true } else { false }
        #expect(kept, "the failed take stays for its Retry")

        #expect(model.showStage())
        let gate = FetchGate()
        model.linkFetcher = ScriptedLinkFetcher(fixture: folder.appendingPathComponent("never.wav"), gate: gate)
        #expect(model.transcribeYouTube(urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .started)
        #expect(model.route == .transcript)
        model.cancelCurrentWork()
        await gate.open()
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

    @Test("a notice with buttons stays when a run asked for during a take waits")
    func waitingRunKeepsAnActionableNotice() {
        let model = makeModel()
        let saved = ExportNotice(
            message: "Saved the previous recording without transcribing it.", failures: [], folder: nil, tone: .info,
            actions: [ExportNotice.Action(title: "Open", handler: .openEntry("entry-1"))]
        )
        model.exportNotice = saved
        model.installTestTake(source: .microphone)

        model.transcribe(fileURL: URL(fileURLWithPath: "/tmp/parola-take-routing-waits.wav"))

        #expect(model.exportNotice?.id == saved.id)
    }

    @Test("a failure waiting behind the Stage stays when a run asked for during the take waits, and is there after the take")
    func waitingRunKeepsAFailure() {
        let model = makeModel()
        let failure = ExportNotice(message: "Auto-export couldn't write to its folder.", failures: [], folder: nil, tone: .failure)
        model.exportNotice = failure
        model.installTestTake(source: .microphone)

        model.transcribe(fileURL: URL(fileURLWithPath: "/tmp/parola-take-routing-failure-waits.wav"))
        #expect(model.exportNotice?.id == failure.id)

        model.endTestTake()
        #expect(model.exportNotice?.id == failure.id, "the failure went with the take it had nothing to do with")
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

    @Test("the notice that a run waits for the take goes when the take stops, so it never shows after the recording it speaks of")
    func waitNoticeGoesWhenTheTakeStops() {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        model.transcribe(fileURL: URL(fileURLWithPath: "/tmp/parola-take-routing-after-stop.wav"))
        #expect(model.exportNotice?.message == "Finish the recording first.")

        model.endTestTake()

        #expect(model.exportNotice == nil)

        let other = ExportNotice(message: "Auto-export couldn't write to its folder.", failures: [], folder: nil, tone: .failure)
        model.installTestTake(source: .microphone)
        model.exportNotice = other
        model.endTestTake()
        #expect(model.exportNotice?.id == other.id, "a notice about something else stays")
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

        @Test("a take that fails while the library shows offers Retry and Show, and Retry lands it as the take would have")
        func noticeRetryLandsTheTake() async throws {
            let wav = try tempWAV("notice-retry")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeRecordingModel("take-landing-notice-retry")
                model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
                model.goHome()
                model.stopRecordingAndTranscribe()
                let failed = await waitUntil { model.recording?.failure != nil && !model.hasPendingTakeWork }
                #expect(failed)
                let take = try #require(model.recording?.takeID)
                let notice = try #require(model.exportNotice)
                let titles = notice.actions.map(\.title)
                let handlers = notice.actions.map(\.handler)
                #expect(notice.tone == .failure)
                #expect(titles == ["Retry", "Show"])
                #expect(handlers == [.retryTake(take), .showTake(take)])
                #expect(!notice.autoDismisses)
                let saved = try #require(await landedEntry(model))
                #expect(saved.title.hasSuffix("(transcription failed)"))

                await installMockTranscriber(segments: [(0, 1, "second time lucky")])
                await model.unloadTranscriptionSession()
                let retry = try #require(notice.actions.first)
                model.performNoticeAction(retry)
                let landed = await waitUntil { model.selectedEntryID == saved.id && model.transcript?.text == "second time lucky" }

                #expect(landed)
                #expect(model.exportNotice == nil)
                #expect(model.recording == nil, "Retry hands the take to its entry")
                await model.awaitLandingSteps()
                let entries = await model.library.list()
                #expect(entries.count == 1, "Retry fills in the entry the failure saved")
                #expect(entries.first?.title.hasSuffix("(transcription failed)") == false)
            }
        }

        @Test("a meeting that starts while a take transcribes out of sight raises no prompt")
        func meetingPromptWaitsForTheTakesTranscription() async throws {
            let wav = try tempWAV("meeting-transcribing")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "held")], gate: gate)
                let model = makeRecordingModel("take-landing-meeting")
                model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
                model.goHome()
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.state == .transcribing(progress: nil) }
                #expect(transcribing)
                #expect(model.phase == .idle)
                model.meetingDetector.isEnabled = true

                model.meetingDetector.fire(appName: "Acme Conference")

                #expect(model.meetingDetectedApp == nil)
                await gate.open()
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

        @Test("an older take's run that ends while a newer take counts in lands in the library and leaves the Stage to the newer take")
        func olderTakeLandsBehindANewerStage() async throws {
            let older = try tempWAV("older-take")
            let fixture = try tempWAV("newer-take-mic")
            defer {
                try? FileManager.default.removeItem(at: older)
                try? FileManager.default.removeItem(at: fixture)
            }
            try await withMocksCleared([.transcriber, .audioSource]) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "the older take")], gate: gate)
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeRecordingModel("take-landing-older")
                model.selectedModel = "openai_whisper-tiny"
                recordAndStop(model, audio: older, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                model.recordingCountInSeconds = 3
                model.startRecording(source: .microphone)
                let newer = try #require(model.recording?.takeID)

                await gate.open()

                let announced = await waitUntil { model.arrivalNotice?.origin == .take }
                #expect(announced, "the older take lands in the library with a toast")
                let saved = try #require(await landedEntry(model))
                #expect(saved.title.hasPrefix("Recording "))
                #expect(model.route == .recording)
                #expect(model.recording?.takeID == newer)
                #expect(model.transcript == nil, "the older take never loads over the newer take's Stage")
                let recording = await waitUntil(timeoutMs: 10_000) {
                    model.recording?.takeID == newer && model.recording?.isCapturing == true
                }
                #expect(recording)
                #expect(model.route == .recording, "the newer take records on its Stage")
                await model.discardTake()
            }
        }

        @Test("an older take that fails while a newer take counts in says so, and its Retry and Show act on what it saved")
        func olderTakeFailsBehindANewerStage() async throws {
            let older = try tempWAV("older-failing-take")
            let fixture = try tempWAV("newer-take-mic-2")
            defer {
                try? FileManager.default.removeItem(at: older)
                try? FileManager.default.removeItem(at: fixture)
            }
            try await withMocksCleared([.transcriber, .audioSource]) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom"), gate: gate
                ))
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeRecordingModel("take-landing-older-fails")
                model.selectedModel = "openai_whisper-tiny"
                recordAndStop(model, audio: older, seconds: 2)
                let transcribing = await waitUntil { ContentRoutes.stageTranscription(for: model) != nil }
                #expect(transcribing)
                model.recordingCountInSeconds = 3
                model.startRecording(source: .microphone)
                let newer = try #require(model.recording?.takeID)

                await gate.open()

                let notice = try #require(await waitForNotice(model))
                #expect(notice.tone == .failure)
                #expect(notice.message.hasSuffix("The audio was saved to your library."))
                #expect(notice.actions.map(\.title) == ["Retry", "Show"])
                #expect(model.route == .recording)
                #expect(model.recording?.takeID == newer)
                let saved = try #require(await landedEntry(model))
                #expect(saved.title.hasSuffix("(transcription failed)"))
                model.cancelRecordingCountdown()
                #expect(model.recording == nil)
                #expect(model.exportNotice?.id == notice.id, "the notice outlives the newer take's session")

                let show = try #require(notice.actions.last)
                model.performNoticeAction(show)
                let shown = await waitUntil { model.selectedEntryID == saved.id }
                #expect(shown)

                await installMockTranscriber(segments: [(0, 1, "second time lucky")])
                await model.unloadTranscriptionSession()
                let retry = try #require(notice.actions.first)
                model.performNoticeAction(retry)
                let retried = await waitUntil { model.selectedEntryID == saved.id && model.transcript?.text == "second time lucky" }
                #expect(retried)
                await model.awaitLandingSteps()
                let entries = await model.library.list()
                #expect(entries.count == 1, "Retry fills in the entry the failure saved")
                #expect(entries.first?.title.hasSuffix("(transcription failed)") == false)
            }
        }

        @Test("a Stop intent answers with its own take's words, not with an older take's that lands meanwhile")
        func stopIntentAnswersForItsOwnTake() async throws {
            let older = try tempWAV("intent-older-take")
            defer { try? FileManager.default.removeItem(at: older) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the older take's words")])
                let model = makeRecordingModel("intent-own-take")
                let held = FetchGate()
                let reached = FetchGate()
                model.postProcessOperation = { transcript in
                    guard transcript.text == "the older take's words" else { return transcript }
                    await reached.open()
                    await held.wait()
                    return transcript
                }
                recordAndStop(model, audio: older, seconds: 1)
                await reached.wait()
                await installMockTranscriber(segments: [(0, 1, "the newer take's words")], delayMs: 1_000)
                await model.unloadTranscriptionSession()
                try await startMeteredTake(model)
                let answer = Task { @MainActor () -> String in
                    do { return try await model.stopRecordingFromIntent() } catch { return "threw \(error)" }
                }
                await settle(for: .milliseconds(300))

                await held.open()

                let text = await answer.value
                #expect(text == "the newer take's words")
                await waitUntil(timeoutMs: 10_000) { !model.hasPendingTakeWork }
            }
        }

        @Test("a take started over a file run hands the run's phase back, so the Library shows the library while it records")
        func takeOverAFileRunFreesThePage() async throws {
            let wav = try tempWAV("run-under-a-take")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "the file's words")], gate: gate)
                let model = makeRecordingModel("take-over-file-run")
                model.transcribe(fileURL: wav)
                let running = await waitUntil { model.fileTranscribeTask != nil && model.phase != .idle }
                #expect(running)

                try await startMeteredTake(model)

                #expect(model.phase == .idle, "the cancelled run's phase: \(model.phase)")
                model.goHome()
                #expect(model.isBrowsingLibrary)
                #expect(ContentRoutes.routeID(for: model) == .library)
                await gate.open()
                await model.discardTake()
            }
        }

        @Test("a take started over a link's download hands its phase back too")
        func takeOverALinkFreesThePage() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let gate = FetchGate()
            let model = makeRecordingModel("take-over-link")
            model.linkFetcher = ScriptedLinkFetcher(fixture: fixture, gate: gate)
            #expect(model.transcribeYouTube(urlString: "https://youtu.be/dQw4w9WgXcQ") == .started)
            let fetching = await waitUntil { model.phase == .fetchingLink(title: "A talk", progress: 0.5) }
            #expect(fetching)

            try await startMeteredTake(model)

            #expect(model.phase == .idle, "the cancelled link's phase: \(model.phase)")
            model.goHome()
            #expect(model.isBrowsingLibrary)
            await gate.open()
            await model.discardTake()
        }

        private static let downloading = AppModel.Phase.downloadingModel(name: "openai_whisper-tiny", progress: 0.4)

        /// A model download from Settings that reports 40 % and waits for the test, then fails if `fails`.
        private func holdDownload(_ model: AppModel, until gate: FetchGate, fails: Bool = false) async -> Bool {
            model.modelDownloadOperation = { _, progress in
                progress(0.4)
                await gate.wait()
                if fails { throw URLError(.badServerResponse) }
            }
            guard model.downloadModel("openai_whisper-tiny") else { return false }
            return await waitUntil { model.phase == Self.downloading }
        }

        @Test("Record goes ahead over a model download, which keeps going off the take's pages and ends without touching the take")
        func downloadBehindATake() async throws {
            let model = makeRecordingModel("download-behind-take")
            let gate = FetchGate()
            let downloading = await holdDownload(model, until: gate)
            #expect(downloading)

            try await startMeteredTake(model)

            #expect(model.phase == Self.downloading, "Settings still shows the download: \(model.phase)")
            #expect(ContentRoutes.routeID(for: model) == .stage)
            model.goHome()
            #expect(model.isBrowsingLibrary)
            #expect(ContentRoutes.routeID(for: model) == .library)
            let take = model.recording?.takeID

            await gate.open()

            let ended = await waitUntil { model.phase == .idle }
            #expect(ended)
            #expect(model.recording?.takeID == take)
            #expect(model.recording?.state == .recording)
            #expect(model.isBrowsingLibrary)
            await model.discardTake()
        }

        @Test("the mic hotkey starts a take over a model download")
        func hotkeyRecordsOverADownload() async throws {
            let model = makeRecordingModel("hotkey-over-download")
            let gate = FetchGate()
            let downloading = await holdDownload(model, until: gate)
            #expect(downloading)
            model.useStreaming = false
            model.takeCaptureOverride = { _ in StubSource(url: URL(fileURLWithPath: "/dev/null")) }

            model.toggleMicRecording()

            #expect(model.recording != nil)
            #expect(model.recordingActive)
            await gate.open()
            await model.discardTake()
            await waitUntil { !model.recordingActive }
        }

        @Test("a meeting that starts during a model download raises its prompt, since Record goes ahead over a download")
        func meetingPromptDuringADownload() async throws {
            let model = makeRecordingModel("meeting-prompt-during-download")
            let gate = FetchGate()
            let downloading = await holdDownload(model, until: gate)
            #expect(downloading)
            model.meetingDetector.isEnabled = true

            model.meetingDetector.fire(appName: "Acme Conference")

            #expect(model.meetingDetectedApp == "Acme Conference")
            await gate.open()
        }

        @Test("a model download that ends while a take transcribes out of sight hands its bar back")
        func downloadEndsUnderATakesRun() async throws {
            try await withMocksCleared(.transcriber) {
                let run = MockTranscriberGate()
                await installMockTranscriber(segments: [(0, 1, "the take's words")], gate: run)
                let model = makeRecordingModel("download-under-take-run")
                let gate = FetchGate()
                let downloading = await holdDownload(model, until: gate)
                #expect(downloading)
                try await startMeteredTake(model)
                model.goHome()
                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.recording?.isTranscribing == true }
                #expect(transcribing)

                await gate.open()

                let handedBack = await waitUntil { model.phase == .idle }
                #expect(handedBack, "the download's bar: \(model.phase)")
                await run.open()
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("a take that lands on its Stage during a model download shows its transcript and leaves Settings the download's bar")
        func takeLandsBesideADownload() async throws {
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the take's words")])
                let model = makeRecordingModel("take-lands-beside-download")
                let gate = FetchGate()
                let downloading = await holdDownload(model, until: gate)
                #expect(downloading)
                try await startMeteredTake(model)

                model.stopRecordingAndTranscribe()

                let landed = await waitUntil { model.transcript?.text == "the take's words" && model.recording?.isOver == true }
                #expect(landed)
                #expect(model.phase == Self.downloading, "Settings keeps its bar, and its buttons stay off: \(model.phase)")
                #expect(model.transcriptRoutePhase == .ready)
                #expect(ContentRoutes.routeID(for: model) == .phase, "the transcript page")
                await gate.open()
                let handedBack = await waitUntil { model.phase == .ready }
                #expect(handedBack)
                #expect(model.transcript?.text == "the take's words")
                await waitUntil { !model.hasPendingTakeWork }
            }
        }

        @Test("a live take that lands on its Stage during a model download leaves Settings the download's bar too")
        func liveTakeLandsBesideADownload() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the live take's words")], partials: ["the live"], delayMs: 300
                ))
                let model = makeRecordingModel("live-take-lands-beside-download")
                let gate = FetchGate()
                let downloading = await holdDownload(model, until: gate)
                #expect(downloading)
                model.useStreaming = true
                model.selectedModel = "openai_whisper-tiny"
                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)

                model.stopRecordingAndTranscribe()

                let landed = await waitUntil { model.transcript?.text == "the live take's words" && model.recording?.isOver == true }
                #expect(landed)
                #expect(model.phase == Self.downloading, "\(model.phase)")
                #expect(model.transcriptRoutePhase == .ready)
                await gate.open()
                await waitUntil { model.phase == .ready && !model.hasPendingTakeWork }
            }
        }

        @Test("a model download that fails after a take landed on its Stage leaves the take's transcript on screen")
        func failedDownloadLeavesALandedTake() async throws {
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the take's words")])
                let model = makeRecordingModel("download-fails-after-take")
                let gate = FetchGate()
                let downloading = await holdDownload(model, until: gate, fails: true)
                #expect(downloading)
                try await startMeteredTake(model)
                model.stopRecordingAndTranscribe()
                let landed = await waitUntil { model.transcript?.text == "the take's words" && model.recording?.isOver == true }
                #expect(landed)

                await gate.open()

                let failed = await waitUntil { model.modelActionError != nil }
                #expect(failed)
                #expect(model.phase == .ready)
                #expect(model.transcriptRoutePhase == .ready)
                #expect(model.transcript?.text == "the take's words")
                await waitUntil { !model.hasPendingTakeWork }
            }
        }
    }
}
