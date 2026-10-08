import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func armingTake(_ arming: RecordingSession.Arming = .startingCapture) -> RecordingSession {
    RecordingSession(takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: arming)
}

@Suite("Ending a starting take says Cancel Recording everywhere")
struct CancelRecordingWordsTests {
    @Test("the menu bar item, the Recording menu and every other surface read Cancel Recording while the take starts")
    func words() {
        var take = armingTake(.countIn(remaining: 3))
        #expect(TakeRemote.endTitle(for: take) == "Cancel Recording")
        #expect(RecordingStatusItem.menuTitles(for: take) == ["Cancel Recording", "Pause", "Add Marker", "Discard…", "Show Recording"])
        #expect(RecordingMenuState(take: take, showsRecording: true, composerFocused: false).cancels)
        _ = take.markCapturing(at: .now)
        #expect(TakeRemote.endTitle(for: take) == "Stop Recording")
        #expect(RecordingStatusItem.menuTitles(for: take).first == "Stop Recording")
        #expect(!RecordingMenuState(take: take, showsRecording: true, composerFocused: false).cancels)
        #expect(TakeRemote.endTitle(for: nil) == "Stop Recording")
    }
}

@MainActor
@Suite("Ending a starting take cancels it, from any surface", .serialized)
struct CancelRecordingActionTests {
    private func element(_ identifier: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix(identifier) == true }
    }

    @Test("the capsule and the pill name their button Cancel Recording while the take starts")
    func spokenWhileStarting() async throws {
        let model = makeRecordingModel("cancel-words-hosted")
        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        let counting = await waitUntil { model.recording?.isCountingIn == true }
        #expect(counting)
        let take = try #require(model.recording)
        let capsule = HostedWindow(
            SessionCapsuleFace(take: take, showsMeter: false, isOnScreen: false, showStage: {}, stop: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity),
            width: 400, height: 120
        )
        defer { capsule.close() }
        let pill = HostedWindow(RecordingPillFace(model: model, isOnScreen: false, onShowParola: {}, onStop: { _ in }, onSize: { _ in }))
        defer { pill.close() }
        let drawn = await waitUntil { element("Toolbar.Button.SessionStop", in: capsule) != nil && element("RecordingPill.Button.Stop", in: pill) != nil }
        #expect(drawn)

        #expect(element("Toolbar.Button.SessionStop", in: capsule)?.label == "Cancel Recording")
        #expect(element("RecordingPill.Button.Stop", in: pill)?.label == "Cancel Recording")
        model.cancelRecordingCountdown()
    }

    @Test("the pill's Cancel drawn while the take started leaves it alone once it records, and ends one still starting")
    func pillActsOnWhatItDrew() async throws {
        let audio = try tempWAV("cancel-pill-drawn")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("cancel-pill-drawn")
        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))

        TakeRemote.stopOrCancel(model, cancels: true)

        #expect(model.recording?.state == .recording, "the Cancel it showed never becomes a Stop")
        model.endTestTake()

        model.recordingCountInSeconds = 60
        model.startRecording(source: .microphone)
        let counting = await waitUntil { model.recordingCountdown != nil }
        #expect(counting)
        TakeRemote.stopOrCancel(model, cancels: true)
        #expect(model.recording == nil)
        #expect(model.exportNotice == nil)
    }

    @Test("the menu bar item's Cancel Recording ends a count-in, with no word")
    func statusItemCancels() async throws {
        let model = makeRecordingModel("cancel-status-item")
        model.recordingCountInSeconds = 60
        let item = RecordingStatusItem(statusBar: nil, appIsActive: { true })
        item.bind(model)
        model.startRecording(source: .microphone)
        let shown = await waitUntil { item.face?.controls.first?.title == "Cancel Recording" }
        #expect(shown)
        let control = try #require(item.face?.controls.first)

        _ = item.perform(control.action)

        #expect(model.recording == nil)
        #expect(model.recordingCountdown == nil)
    }
}

@Suite("What VoiceOver calls the Stage and its overview")
struct StageSpokenNamesTests {
    private func italian() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the overview's label names what its value is: the run's progress, or the take's length before it")
    func overview() {
        let english = Locale(identifier: "en_US")
        let reading = TakeOverview.spoken(elapsed: 754, progress: 0.42, locale: english)
        #expect(reading.label == "Transcription progress")
        #expect(reading.value == AppFormat.percent(0.42, locale: english))
        let before = TakeOverview.spoken(elapsed: 754, progress: nil, locale: english)
        #expect(before.label == "Recording length")
        #expect(before.value == "12 minutes, 34 seconds")
    }

    @Test("the Stage reads right while it pauses, while it finishes, and when it never started")
    func stageTitle() throws {
        #expect(StagePage.accessibilityTitle(for: .live, from: "microphone") == "Recording from microphone")
        #expect(StagePage.accessibilityTitle(for: .paused, from: "microphone") == "Recording from microphone, paused")
        #expect(StagePage.accessibilityTitle(for: .finishing, from: "microphone") == "Finishing the recording")
        #expect(StagePage.accessibilityTitle(for: .starting, from: "microphone") == "Getting ready to record from microphone")
        #expect(StagePage.accessibilityTitle(for: .failed("x"), failedWhile: .starting, from: "microphone") == "Couldn't start the recording")
        #expect(StagePage.accessibilityTitle(for: .failed("x"), failedWhile: .recording, from: "microphone") == "The recording stopped")
        let it = try italian()
        let neverStarted = StagePage.accessibilityTitle(for: .failed("x"), failedWhile: .starting, from: "microfono", bundle: it)
        #expect(neverStarted == "Avvio della registrazione non riuscito")
        #expect(StagePage.accessibilityTitle(for: .paused, from: "microfono", bundle: it) == "Registrazione da microfono, in pausa")
        #expect(TakeOverview.spoken(elapsed: 1, progress: 0.5, bundle: it).label == "Avanzamento della trascrizione")
        #expect(TakeOverview.spoken(elapsed: 1, progress: nil, bundle: it).label == "Durata della registrazione")
    }
}

@Suite("A recording that fails says so, not that its transcription did")
struct RecordingFailureTitleTests {
    private func failed(after steps: (inout RecordingSession) -> Void) -> RecordingSession {
        var take = armingTake()
        steps(&take)
        take.fail("The disk is full.")
        return take
    }

    @Test("a failure is placed by what the take was doing: starting, recording up to its file closing, or transcribing")
    func failedWhile() {
        #expect(failed { _ in }.failedWhile == .starting)
        #expect(failed { $0.markCapturing(at: .now) }.failedWhile == .recording)
        #expect(failed { $0.markCapturing(at: .now); $0.pause(at: .now) }.failedWhile == .recording)
        #expect(failed { $0.markCapturing(at: .now); $0.finish(at: .now) }.failedWhile == .recording)
        #expect(failed { $0.markCapturing(at: .now); $0.finish(at: .now); $0.transcribing(progress: nil) }.failedWhile == .transcribing)
        var live = RecordingSession(takeID: 2, source: .microphone, category: .transcription, title: "R", isStreaming: true, arming: .startingCapture)
        live.markCapturing(at: .now)
        live.finish(at: .now)
        live.fail("The engine stopped.")
        #expect(live.failedWhile == .transcribing, "a live take's engine failing after Stop is its transcription's failure")
        var again = failed { _ in }
        again.fail("Another reason.")
        #expect(again.failedWhile == .starting, "a failure keeps the moment it first failed")
    }

    @Test("the banner titles a recording failure as one, in Italian too")
    func titles() throws {
        #expect(ErrorBanner.takeTitle(failedWhile: .starting) == "Couldn't start the recording")
        #expect(ErrorBanner.takeTitle(failedWhile: .recording) == "The recording stopped")
        #expect(ErrorBanner.takeTitle(failedWhile: .transcribing) == nil)
        #expect(ErrorBanner.takeTitle(failedWhile: nil) == nil)
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(ErrorBanner.takeTitle(failedWhile: .starting, bundle: it) == "Avvio della registrazione non riuscito")
        #expect(ErrorBanner.takeTitle(failedWhile: .recording, bundle: it) == "La registrazione si è interrotta")
    }

    @Test("a take that couldn't keep writing to disk reads The recording stopped on its Stage, not Couldn't transcribe")
    @MainActor
    func hostedBanner() async {
        var take = armingTake()
        take.markCapturing(at: .now)
        take.finish(at: .now)
        take.failure = RecordingSession.Failure(
            audioURL: URL(fileURLWithPath: "/tmp/take.wav"), save: nil, recovery: nil, title: "Recording 14:05",
            category: .transcription, source: .microphone, annotations: AppModel.TakeAnnotations()
        )
        take.fail("Parola couldn't keep writing the recording to disk.")
        let hosted = HostedWindow(ErrorBanner(message: "Parola couldn't keep writing the recording to disk.", take: take), width: 700, height: 300)
        defer { hosted.close() }
        await settle(for: .milliseconds(100))
        let words = HostedAccessibility.words(in: hosted.host)
        #expect(words.contains("The recording stopped"))
        let saysTranscribe = words.contains { $0.hasPrefix("Couldn't transcribe") }
        #expect(!saysTranscribe)
    }
}

@Suite("A take's last English-only failures read in Italian")
struct TakeFailureItalianTests {
    private func italian() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the refusal for want of disk space reads in Italian")
    func diskRefusal() throws {
        #expect(AppModel.diskSpaceRefusalMessage(bundle: try italian())
            == "Non c'è abbastanza spazio libero su disco per registrare. Libera almeno 200 MB e riprova.")
    }

    @Test("Mac audio that never started says so whole, in either language, with no English prefix")
    func systemAudioTimeout() throws {
        let english = SystemAudioDidNotStart.message()
        for granted in [true, false] {
            let message = AppModel.recordingFailureMessage(for: SystemAudioDidNotStart(), source: .systemAudio, screenRecordingGranted: granted)
            #expect(message == english)
        }
        #expect(!english.contains("Audio capture unavailable"))
        #expect(SystemAudioDidNotStart.message(bundle: try italian())
            == "Parola non è riuscita ad avviare la registrazione dell'audio di sistema. Apri Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e audio di sistema → Solo registrazione audio di sistema e consenti l'accesso a Parola, poi riprova.")
    }

    @Test("the take's start throws that failure when Mac audio never comes up")
    func throwSite() throws {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/TakeNitsTests.swift", with: "ParolaApp/AppModel.swift")
        let model = try String(contentsOfFile: path, encoding: .utf8)
        let throwsIt = model.contains("throw SystemAudioDidNotStart()")
        let keepsTheEnglish = model.contains("system audio capture did not start")
        #expect(throwsIt)
        #expect(!keepsTheEnglish)
    }
}

@MainActor
@Suite("⌘Q's Discard during a take")
struct QuitDiscardTests {
    @Test("the quit alert's Discard… reads as every other Discard that asks again")
    func buttons() {
        let alert = AppDelegate.quitAlert()
        #expect(alert.buttons.map(\.title) == ["Stop and Save", "Keep Recording", "Discard…"])
        #expect(alert.messageText == "A recording is in progress")
    }

    @Test("Discard… asks the shared question before the take is deleted; a no keeps it recording, and nothing else asks")
    func asksAgain() {
        var asked = 0
        #expect(AppDelegate.confirmingDiscard(.discard) { asked += 1; return false } == .keepRecording)
        #expect(AppDelegate.confirmingDiscard(.discard) { asked += 1; return true } == .discard)
        #expect(AppDelegate.confirmingDiscard(.stopAndSave) { asked += 1; return true } == .stopAndSave)
        #expect(AppDelegate.confirmingDiscard(.keepRecording) { asked += 1; return true } == .keepRecording)
        #expect(asked == 2)
    }
}

@MainActor
@Suite("The notice's sign for VoiceOver", .serialized)
struct NoticeIconSpeechTests {
    private func words(_ notice: ExportNotice) async -> [String] {
        let model = makeRecordingModel("notice-icon")
        let hosted = HostedWindow(ExportNoticeStrip(notice: notice).environment(model), width: 700, height: 120)
        defer { hosted.close() }
        await settle(for: .milliseconds(100))
        return HostedAccessibility.words(in: hosted.host)
    }

    @Test("a failure's sign reads Error; a success's or an info's isn't read at all")
    func spokenOnlyForFailure() async throws {
        #expect(ExportNoticeStrip.iconIsSpoken(.failure))
        #expect(!ExportNoticeStrip.iconIsSpoken(.info))
        #expect(!ExportNoticeStrip.iconIsSpoken(.success))
        let failure = await words(ExportNotice(message: "Export failed: disk full", failures: [], folder: nil, tone: .failure))
        #expect(failure.contains("Error"))
        #expect(!failure.contains("Warning"), "the system's own name for the sign")
        let info = await words(ExportNotice(message: "Finish the recording first.", failures: [], folder: nil, tone: .info))
        #expect(!info.contains("Error"))
        #expect(!info.contains("Info"), "the system's own name for the sign")
        let success = await words(ExportNotice(message: "Exported 3 of 3", failures: [], folder: nil, tone: .success))
        #expect(!success.contains("Selected"), "a check mark that reads Selected says something untrue")
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: "Error", bundle: italian) == "Errore")
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A newer take never lands into an older take's transcript", .serialized)
    struct StaleLandingGateTests {
        @Test("while an older take's save is on its way, a newer take that lands is not that transcript's take")
        func newerTakeIsNotTheOlderTranscript() async throws {
            let audio = try makeTakeWAV("stale-landing-gate", seconds: 1)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "the older take")])
                let model = makeRecordingModel("stale-landing-gate")
                let save = FetchGate()
                model.beforeLandingSave = { await save.wait() }
                recordAndStop(model, audio: audio, seconds: 1)
                let onScreen = await waitUntil { model.route == .transcript && model.transcript != nil }
                #expect(onScreen)
                let older = StageLanding.transcriptIsTheTake(model)
                #expect(older, "the older take is over its own working file")

                model.installTestTake(source: .microphone)
                let newer = try #require(model.recording?.takeID)
                model.updateSession(of: newer) { session in
                    session.finish(at: Date())
                    session.land(entryID: nil)
                }

                let newerIsTheTranscript = StageLanding.transcriptIsTheTake(model)
                #expect(!newerIsTheTranscript, "the newer take's pieces would fly into the older take's transcript")
                await save.open()
                _ = await landedEntry(model)
                model.endTestTake()
            }
        }
    }
}
