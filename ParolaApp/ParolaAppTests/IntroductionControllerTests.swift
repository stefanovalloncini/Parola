import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Introduction controller")
struct IntroductionControllerTests {

    private func makeController(
        defaults: UserDefaults,
        mode: AppBootstrap.Mode = .normal,
        showsInTestMode: Bool = false,
        hasEngineChoice: Bool = true,
        environment: [String: String] = [:]
    ) -> IntroductionController {
        IntroductionController(
            defaults: defaults,
            mode: mode,
            showsInTestMode: showsInTestMode,
            hasEngineChoice: hasEngineChoice,
            environment: environment
        )
    }

    @Test("the sequence carries every step when an engine choice is on offer")
    func sequenceWithEngine() {
        #expect(IntroductionStep.sequence(hasEngineChoice: true) == [.hello, .transcribe, .features, .engine, .ready])
    }

    @Test("the sequence drops the engine step when there is nothing to choose")
    func sequenceWithoutEngine() {
        #expect(IntroductionStep.sequence(hasEngineChoice: false) == [.hello, .transcribe, .features, .ready])
    }

    @Test("PAROLA_INTRODUCTION_STEP picks the opening step")
    func environmentPicksStep() {
        let controller = makeController(
            defaults: temporaryDefaults(),
            environment: ["PAROLA_INTRODUCTION_STEP": "features"]
        )
        #expect(controller.step == .features)
    }

    @Test("a step name outside the sequence is ignored")
    func unknownEnvironmentStepIgnored() {
        let controller = makeController(
            defaults: temporaryDefaults(),
            environment: ["PAROLA_INTRODUCTION_STEP": "nonsense"]
        )
        #expect(controller.step == .hello)

        let withoutEngine = makeController(
            defaults: temporaryDefaults(),
            hasEngineChoice: false,
            environment: ["PAROLA_INTRODUCTION_STEP": "engine"]
        )
        #expect(withoutEngine.step == .hello)
    }

    @Test("advance walks to the last step and stops there")
    func advanceStopsAtTheEnd() {
        let controller = makeController(defaults: temporaryDefaults())
        #expect(controller.stepIndex == 0)
        #expect(controller.canGoBack == false)

        for _ in 0..<10 { controller.advance() }

        #expect(controller.step == .ready)
        #expect(controller.isLastStep)
        #expect(controller.canGoBack)
    }

    @Test("back walks to the first step and stops there")
    func backStopsAtTheStart() {
        let controller = makeController(defaults: temporaryDefaults())
        controller.advance()
        controller.advance()
        #expect(controller.step == .features)

        for _ in 0..<10 { controller.back() }

        #expect(controller.step == .hello)
        #expect(controller.canGoBack == false)
        #expect(controller.isLastStep == false)
    }

    @Test("finish persists completion and rewinds the step")
    func finishPersists() {
        let defaults = temporaryDefaults()
        let controller = makeController(defaults: defaults)
        controller.advance()
        controller.finish()

        #expect(controller.isComplete)
        #expect(controller.isPresented == false)
        #expect(controller.step == .hello)
        #expect(defaults.bool(forKey: "introductionComplete"))
    }

    @Test("skip finishes too")
    func skipFinishes() {
        let defaults = temporaryDefaults()
        let controller = makeController(defaults: defaults)
        controller.advance()
        controller.skip()

        #expect(controller.isComplete)
        #expect(controller.step == .hello)
        #expect(defaults.bool(forKey: "introductionComplete"))
    }

    @Test("restart clears the persisted flag, so an abandoned introduction returns on the next launch")
    func restartClears() {
        let defaults = temporaryDefaults()
        let controller = makeController(defaults: defaults)
        controller.finish()
        controller.defer()

        controller.restart()

        #expect(controller.isComplete == false)
        #expect(controller.isDeferred == false)
        #expect(controller.step == .hello)
        #expect(controller.isPresented)
        #expect(defaults.bool(forKey: "introductionComplete") == false)
    }

    @Test("deferring hides the introduction without persisting anything")
    func deferDoesNotPersist() {
        let defaults = temporaryDefaults()
        let controller = makeController(defaults: defaults)
        controller.defer()

        #expect(controller.isPresented == false)
        #expect(controller.isComplete == false)
        #expect(defaults.object(forKey: "introductionComplete") == nil)
    }

    @Test("an old hasSeenWelcome counts as a finished introduction, written once under the new key")
    func migratesFromWelcome() {
        let defaults = temporaryDefaults()
        defaults.set(true, forKey: "hasSeenWelcome")
        let controller = makeController(defaults: defaults)

        #expect(controller.isComplete)
        #expect(defaults.bool(forKey: "introductionComplete"))
        #expect(defaults.object(forKey: "hasSeenWelcome") == nil)
    }

    @Test("a full reset brings the introduction back for someone who had seen the old welcome sheet")
    func resetAfterMigrationShowsItAgain() {
        let defaults = temporaryDefaults()
        defaults.set(true, forKey: "hasSeenWelcome")
        #expect(makeController(defaults: defaults).isComplete)

        defaults.removeObject(forKey: "introductionComplete")

        #expect(makeController(defaults: defaults).isComplete == false)
    }

    @Test("a welcome sheet nobody saw leaves the introduction pending")
    func migrationIgnoresUnseenWelcome() {
        let absent = temporaryDefaults()
        #expect(makeController(defaults: absent).isComplete == false)
        #expect(absent.object(forKey: "introductionComplete") == nil)

        let explicitlyFalse = temporaryDefaults()
        explicitlyFalse.set(false, forKey: "hasSeenWelcome")
        #expect(makeController(defaults: explicitlyFalse).isComplete == false)
        #expect(explicitlyFalse.object(forKey: "introductionComplete") == nil)
    }

    @Test("the new key wins over the old one")
    func migrationSkippedOnceTheNewKeyExists() {
        let defaults = temporaryDefaults()
        defaults.set(true, forKey: "hasSeenWelcome")
        defaults.set(false, forKey: "introductionComplete")

        #expect(makeController(defaults: defaults).isComplete == false)
    }

    @Test("a normal launch presents the introduction")
    func normalLaunchPresents() {
        let controller = makeController(defaults: temporaryDefaults(), mode: .normal)
        #expect(controller.isSuppressed == false)
        #expect(controller.isPresented)
    }

    @Test("test mode suppresses the introduction unless the launch asks for it")
    func testModeSuppression() {
        let silent = makeController(defaults: temporaryDefaults(), mode: .test, showsInTestMode: false)
        #expect(silent.isSuppressed)
        #expect(silent.isPresented == false)

        let asked = makeController(defaults: temporaryDefaults(), mode: .test, showsInTestMode: true)
        #expect(asked.isSuppressed == false)
        #expect(asked.isPresented)
    }

    @Test("an explicit restart overrules a suppressed launch")
    func restartLiftsSuppression() {
        let controller = makeController(defaults: temporaryDefaults(), mode: .test, showsInTestMode: false)
        #expect(controller.isPresented == false)

        controller.restart()

        #expect(controller.isSuppressed == false)
        #expect(controller.isPresented)
    }

    @Test("the controller remembers which way the last move went")
    func tracksDirection() {
        let controller = makeController(defaults: temporaryDefaults())
        controller.advance()
        #expect(controller.isMovingBack == false)

        controller.back()
        #expect(controller.isMovingBack)

        controller.advance()
        #expect(controller.isMovingBack == false)
    }

    @Test("a unit-test process never sees the introduction")
    func xcTestSuppression() {
        let controller = makeController(
            defaults: temporaryDefaults(),
            environment: ["XCTestConfigurationFilePath": "/tmp/whatever.xctestconfiguration"]
        )
        #expect(controller.isSuppressed)
        #expect(controller.isPresented == false)
    }

    @Test("reloadFromDefaults follows a reset that cleared the key")
    func reloadAfterReset() {
        let defaults = temporaryDefaults()
        let controller = makeController(defaults: defaults)
        controller.finish()
        #expect(controller.isPresented == false)

        defaults.removeObject(forKey: "introductionComplete")
        controller.reloadFromDefaults()

        #expect(controller.isComplete == false)
        #expect(controller.isPresented)
    }
}

@MainActor
@Suite("Introduction backstops")
struct IntroductionBackstopTests {
    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("introduction-backstop")
        )
    }

    /// `.exporting` parks the arrival before any transcription starts, so the test only proves the defer.
    @Test("a file arriving from the menu bar or an intent steps out of the introduction")
    func transcribeDefers() {
        let model = makeModel()
        model.introduction.restart()
        model.phase = .exporting(progress: 0)
        #expect(model.introduction.isPresented)

        model.transcribe(fileURL: URL(fileURLWithPath: "/tmp/parola-introduction-backstop.wav"))

        #expect(model.introduction.isDeferred)
        #expect(model.introduction.isPresented == false)
    }

    @Test("a recording started from outside the window steps out of the introduction")
    func recordingDefers() {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("introduction-backstop-record"),
            features: []
        )
        model.introduction.restart()
        #expect(model.introduction.isPresented)

        model.startRecording(source: .microphone)

        #expect(model.introduction.isDeferred)
        #expect(model.introduction.isPresented == false)
    }

    /// The menu bar extra keeps both items live during the introduction, so each has to step out of it itself.
    @Test("a transcript picked in the menu bar extra steps out of the introduction")
    func loadEntryDefers() {
        let model = makeModel()
        model.introduction.restart()
        #expect(model.introduction.isPresented)

        model.loadEntry("missing")

        #expect(model.introduction.isDeferred)
        #expect(model.introduction.isPresented == false)
    }

    @Test("live captions started from outside the window step out of the introduction")
    func liveCaptionsDefer() {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("introduction-backstop-captions"),
            features: []
        )
        model.introduction.restart()
        #expect(model.introduction.isPresented)

        model.toggleLiveCaptions()

        #expect(model.introduction.isDeferred)
        #expect(model.introduction.isPresented == false)
    }
}

@MainActor
@Suite("Introduction persistence keys")
struct IntroductionSettingsKeyTests {

    @Test("a full reset or backup covers the introduction flag")
    func unscopedKeysCarryIt() {
        #expect(UnscopedSettingsKeys.all.contains("introductionComplete"))
    }

    @Test("the bridge can write the introduction flag")
    func bridgeCanWriteIt() {
        #expect(ParolaAutomationServer.writableSettingKeys.contains("introductionComplete"))
    }
}
