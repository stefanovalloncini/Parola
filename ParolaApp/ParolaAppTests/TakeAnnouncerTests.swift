import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
private final class Heard {
    var lines: [String] = []
}

private typealias Moment = TakeAnnouncer.Moment

private func italianBundle() throws -> Bundle {
    let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
    return try #require(Bundle(path: path))
}

@Suite("What VoiceOver hears about a take")
struct TakeAnnouncementLineTests {
    @Test("capture starting, a pause and a resume are each said once")
    func captureAndPause() {
        let arming = Moment(takeID: 1, take: .arming)
        let recording = Moment(takeID: 1, take: .recording)
        let paused = Moment(takeID: 1, take: .paused)
        #expect(TakeAnnouncer.lines(from: arming, to: recording).map(\.text) == ["Recording"])
        #expect(TakeAnnouncer.lines(from: recording, to: recording).isEmpty)
        #expect(TakeAnnouncer.lines(from: recording, to: paused).map(\.text) == ["Paused"])
        #expect(TakeAnnouncer.lines(from: paused, to: recording).map(\.text) == ["Recording"])
        #expect(TakeAnnouncer.lines(from: Moment(), to: recording).map(\.text) == ["Recording"], "a take first seen recording still says so")
        #expect(TakeAnnouncer.lines(from: Moment(), to: arming).isEmpty)
    }

    @Test("a failure during the take says the recording stopped; one after Stop says only what failed")
    func failures() {
        let recording = Moment(takeID: 1, take: .recording)
        let failed = Moment(takeID: 1, take: .failed("The microphone stopped."))
        #expect(TakeAnnouncer.lines(from: recording, to: failed).map(\.text) == ["Recording stopped: The microphone stopped."])
        #expect(TakeAnnouncer.lines(from: failed, to: failed).isEmpty)
        let windingDown = Moment(takeID: 1, take: .windingDown)
        let transcriptionFailed = Moment(takeID: 1, take: .failed("Transcription failed: no words."))
        #expect(TakeAnnouncer.lines(from: windingDown, to: transcriptionFailed).map(\.text) == ["Transcription failed: no words."])
    }

    @Test("a notice about the failure just said isn't said again; any other failure or info notice is")
    func notices() {
        let failure = ExportNotice(
            message: "The microphone stopped.", failures: [], folder: nil, tone: .failure,
            actions: [ExportNotice.Action(title: "Show", handler: .showTake(1))]
        )
        let recording = Moment(takeID: 1, take: .recording)
        var failed = Moment(takeID: 1, take: .failed("The microphone stopped."))
        failed.notice = failure
        #expect(TakeAnnouncer.lines(from: recording, to: failed).map(\.text) == ["Recording stopped: The microphone stopped."])

        let info = ExportNotice(message: "Finish the recording first.", failures: [], folder: nil, tone: .info)
        #expect(TakeAnnouncer.lines(from: recording, to: Moment(takeID: 1, take: .recording, notice: info)).map(\.text) == ["Finish the recording first."])
        let exported = ExportNotice(message: "Exported 3 of 3", failures: [], folder: nil, tone: .success)
        #expect(TakeAnnouncer.lines(from: Moment(), to: Moment(notice: exported)).isEmpty)
        let other = ExportNotice(message: "Export failed: disk full", failures: [], folder: nil, tone: .failure)
        #expect(TakeAnnouncer.lines(from: Moment(), to: Moment(notice: other)).map(\.text) == ["Export failed: disk full"])
    }

    @Test("the saved toast says where the take went, once")
    func savedToast() {
        let saved = TakeSavedNotice(entryID: "E", category: .meeting)
        let landed = Moment(takeID: 1, take: .over, saved: saved)
        #expect(TakeAnnouncer.lines(from: Moment(takeID: 1, take: .windingDown), to: landed).map(\.text) == ["Saved to Meetings"])
        #expect(TakeAnnouncer.lines(from: landed, to: landed).isEmpty)
    }

    @Test("a failure cuts in at high priority, a failure notice too; capture, pause, the saved toast and an info notice wait their turn")
    func priorities() {
        let recording = Moment(takeID: 1, take: .recording)
        let failed = TakeAnnouncer.lines(from: recording, to: Moment(takeID: 1, take: .failed("The microphone stopped.")))
        #expect(failed.map(\.priority) == [.high])
        let paused = TakeAnnouncer.lines(from: recording, to: Moment(takeID: 1, take: .paused))
        #expect(paused.map(\.priority) == [.medium])
        let started = TakeAnnouncer.lines(from: Moment(takeID: 1, take: .arming), to: recording)
        #expect(started.map(\.priority) == [.medium])
        let saved = TakeAnnouncer.lines(from: Moment(), to: Moment(saved: TakeSavedNotice(entryID: "E", category: .meeting)))
        #expect(saved.map(\.priority) == [.medium])
        let info = ExportNotice(message: "Finish the recording first.", failures: [], folder: nil, tone: .info)
        #expect(TakeAnnouncer.lines(from: Moment(), to: Moment(notice: info)).map(\.priority) == [.medium])
        let exportFailed = ExportNotice(message: "Export failed: disk full", failures: [], folder: nil, tone: .failure)
        #expect(TakeAnnouncer.lines(from: Moment(), to: Moment(notice: exportFailed)).map(\.priority) == [.high])
    }

    @Test("an announcement carries its words and a priority, as AppKit asks of every one")
    func announcementCarriesPriority() {
        let high = announcementInfo("Recording stopped: X", priority: .high)
        #expect(high[.announcement] as? String == "Recording stopped: X")
        #expect(high[.priority] as? Int == NSAccessibilityPriorityLevel.high.rawValue)
        let medium = announcementInfo("Paused", priority: .medium)
        #expect(medium[.priority] as? Int == NSAccessibilityPriorityLevel.medium.rawValue)
    }

    @Test("the lines read in Italian")
    func italian() throws {
        let it = try italianBundle()
        let recording = Moment(takeID: 1, take: .recording)
        #expect(TakeAnnouncer.lines(from: Moment(takeID: 1, take: .arming), to: recording, bundle: it).map(\.text) == ["Registrazione"])
        #expect(TakeAnnouncer.lines(from: recording, to: Moment(takeID: 1, take: .paused), bundle: it).map(\.text) == ["In pausa"])
        #expect(TakeAnnouncer.lines(from: recording, to: Moment(takeID: 1, take: .failed("X")), bundle: it).map(\.text) == ["Registrazione interrotta: X"])
    }
}

@MainActor
@Suite("VoiceOver hears the take with no window open", .serialized)
struct TakeAnnouncerTests {
    @Test("the take's start, pause, resume, a notice and the saved toast are announced with the main window closed")
    func announcesWithoutAWindow() async throws {
        let audio = try tempWAV("announcer")
        defer { try? FileManager.default.removeItem(at: audio) }
        let model = makeRecordingModel("announcer")
        model.mainWindowPresenceOverride = .closed
        let heard = Heard()
        let announcer = TakeAnnouncer { heard.lines.append($0.text) }
        announcer.bind(model)

        model.installTestTake(source: .microphone, liveSource: StubSource(url: audio))
        let started = await waitUntil { heard.lines == ["Recording"] }
        #expect(started)
        #expect(model.pauseTake())
        let paused = await waitUntil { heard.lines.last == "Paused" }
        #expect(paused)
        #expect(model.resumeTake())
        let resumed = await waitUntil { heard.lines == ["Recording", "Paused", "Recording"] }
        #expect(resumed)
        model.noteRunWaitsForTake()
        let noticed = await waitUntil { heard.lines.last == "Finish the recording first." }
        #expect(noticed)
        model.endTestTake()

        model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)
        let saved = await waitUntil { heard.lines.last == "Saved to Transcriptions" }
        #expect(saved)
        withExtendedLifetime(announcer) {}
    }

    @Test("a count-in that fails is announced with its reason")
    func announcesAFailure() async throws {
        let model = makeRecordingModel("announcer-failure")
        model.recordingCountInSeconds = 60
        let heard = Heard()
        let announcer = TakeAnnouncer { heard.lines.append($0.text) }
        announcer.bind(model)
        model.startRecording(source: .microphone)
        let counting = await waitUntil { model.recordingCountdown != nil }
        #expect(counting)

        model.failCountIn("Parola can't use the microphone.")

        let said = await waitUntil { heard.lines == ["Recording stopped: Parola can't use the microphone."] }
        #expect(said)
        model.forgetTakeSession()
        withExtendedLifetime(announcer) {}
    }

    @Test("with VoiceOver running the saved toast waits to be dismissed")
    func toastStaysUnderVoiceOver() async {
        let model = makeRecordingModel("announcer-toast")
        model.voiceOverIsRunning = true
        model.takeSavedLifetime = .milliseconds(50)

        model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)
        model.takeSavedCameOnScreen()

        await settle(for: .milliseconds(400))
        #expect(model.takeSavedNotice != nil)
        model.dismissTakeSaved()
        #expect(model.takeSavedNotice == nil)
    }

    @Test("turning VoiceOver off lets a toast it held go on its own, without a hover to wake it")
    func toastGoesWhenVoiceOverStops() async {
        let model = makeRecordingModel("announcer-toast-off")
        model.voiceOverIsRunning = true
        model.takeSavedLifetime = .milliseconds(50)
        model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)
        model.takeSavedCameOnScreen()
        await settle(for: .milliseconds(300))
        #expect(model.takeSavedNotice != nil)

        model.voiceOverIsRunning = false

        let gone = await waitUntil { model.takeSavedNotice == nil }
        #expect(gone)
    }

    @Test("a model nobody binds, as every test's is, starts with VoiceOver off; the app's follows the system")
    func voiceOverStartsOff() {
        let test = makeRecordingModel("announcer-voiceover-default")
        #expect(!test.voiceOverIsRunning)
        let plain = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("announcer-voiceover-plain"))
        #expect(!plain.voiceOverIsRunning)

        let followed = makeRecordingModel("announcer-voiceover-followed")
        let observation = AppDelegate.followVoiceOver(for: followed)
        #expect(followed.voiceOverIsRunning == NSWorkspace.shared.isVoiceOverEnabled)
        withExtendedLifetime(observation) {}
    }
}

@Suite("VoiceOver announcer wiring")
struct TakeAnnouncerWiringTests {
    @Test("the app delegate binds the announcer, so it hears the take with no window open")
    func delegateBindsIt() throws {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/TakeAnnouncerTests.swift", with: "ParolaApp/AppDelegate.swift")
        let delegate = try String(contentsOfFile: path, encoding: .utf8)
        #expect(delegate.contains("takeAnnouncer.bind(model)"))
        #expect(delegate.contains("voiceOverObservation = Self.followVoiceOver(for: model)"))
    }
}
