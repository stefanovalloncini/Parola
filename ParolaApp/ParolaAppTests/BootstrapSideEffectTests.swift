import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Bootstrap side-effect sets + launch flag parsing")
struct BootstrapSideEffectTests {

    @Test(".all contains all 16 cases")
    func allHasSixteenCases() {
        #expect(BootstrapSideEffect.all.count == 16)
        let expected: Set<BootstrapSideEffect> = [
            .sparkle, .launchAtLogin, .menuBarExtra, .dockIconRegistration, .appIntentsDonation,
            .meetingDetector, .watchedFolders, .dictationHotkey, .micHotkey,
            .libraryPurgeOnLaunch, .refreshYtDlp, .liveCaptionsTranslateRestore,
            .automationBridge, .modelsPathSync, .diagnosticsLog, .staleWindowKeyPrune,
        ]
        #expect(BootstrapSideEffect.all == expected)
    }

    @Test(".testing is exactly {.automationBridge}")
    func testingIsBridgeOnly() {
        #expect(BootstrapSideEffect.testing == [.automationBridge])
    }

    /// A sandbox instance writing diagnostics would put a second process into the shared cache
    /// directory the real app owns.
    @Test("test mode installs no diagnostics sink")
    func testingExcludesDiagnosticsLog() {
        #expect(!BootstrapSideEffect.testing.contains(.diagnosticsLog))
    }

    @Test("only a launch that owns the dictation hotkey answers the system-wide dictation signal")
    func dictationSignalNeedsTheHotkeySideEffect() {
        #expect(AppDelegate.hearsDictationSignal(BootstrapSideEffect.all))
        #expect(!AppDelegate.hearsDictationSignal(BootstrapSideEffect.testing))
        #expect(!AppDelegate.hearsDictationSignal([]))
    }

    @Test(".testing is a subset of .all")
    func testingIsSubsetOfAll() {
        #expect(BootstrapSideEffect.testing.isSubset(of: BootstrapSideEffect.all))
    }

    @Test("AppBootstrap.test returns nil without --test-mode outside a test host")
    func testReturnsNilWithoutFlag() {
        let bootstrap = AppBootstrap.test(from: ["Parola", "--library=/tmp/x"], environment: [:])
        #expect(bootstrap == nil)
    }

    @Test("the unit-test host boots in test mode on its own suite, library and key store, with no side effects")
    func testHostGetsItsOwnSandbox() throws {
        let environment = ["XCTestConfigurationFilePath": ""]
        let bootstrap = try #require(AppBootstrap.test(from: ["Parola"], environment: environment))
        let sandbox = TestHostSandbox.current
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path

        #expect(bootstrap.mode == .test)
        #expect(bootstrap.sideEffects.isEmpty)
        #expect(bootstrap.defaultsSuite == sandbox.defaultsSuite)
        #expect(sandbox.defaultsSuite.hasPrefix(TestHostSandbox.namePrefix))
        #expect(bootstrap.library == sandbox.library)
        #expect(bootstrap.models == nil)
        #expect(sandbox.library.standardizedFileURL.path.hasPrefix(temporary))
        #expect(bootstrap.apiKeyStore is InMemoryAPIKeyStore)
    }

    @Test("only a normal launch prunes the stale window frames")
    func onlyANormalLaunchPrunes() throws {
        let host = try #require(AppBootstrap.testHost(environment: ["XCTestConfigurationFilePath": ""]))
        #expect(BootstrapSideEffect.all.contains(.staleWindowKeyPrune))
        #expect(!BootstrapSideEffect.testing.contains(.staleWindowKeyPrune))
        #expect(!host.sideEffects.contains(.staleWindowKeyPrune))
    }

    @Test("AppBootstrap.test parses every test-mode flag correctly")
    func testParsesAllFlags() throws {
        let args = [
            "Parola",
            "--test-mode",
            "--library=/tmp/foo",
            "--models=/tmp/bar",
            "--defaults-suite=t",
            "--enabled-features=batch",
        ]
        let bootstrap = try #require(AppBootstrap.test(from: args))

        if case .test = bootstrap.mode {} else {
            Issue.record("expected bootstrap.mode == .test, got \(bootstrap.mode)")
        }
        #expect(bootstrap.library?.path == "/tmp/foo")
        #expect(bootstrap.models?.path == "/tmp/bar")
        #expect(bootstrap.defaultsSuite == "t")
        #expect(bootstrap.enabledFeaturesOverride == [.batch])
        #expect(bootstrap.sideEffects == BootstrapSideEffect.testing)
    }

    /// Every flag the parser accepts must reach something; unread ones read as working and don't.
    @Test("--models is the only path flag beyond --library, and it lands on the model store")
    func modelsFlagIsWired() throws {
        let bootstrap = try #require(AppBootstrap.test(from: ["Parola", "--test-mode", "--models=/tmp/bar"]))
        #expect(bootstrap.models?.path == "/tmp/bar")
        #expect(ModelStore(modelsDirectory: bootstrap.models).directory.path == "/tmp/bar")
    }

    @Test("--show-introduction is a bare flag the sandbox can pass")
    func showIntroductionFlag() throws {
        let asked = try #require(AppBootstrap.test(from: ["Parola", "--test-mode", "--show-introduction"]))
        #expect(asked.showsIntroduction)

        let silent = try #require(AppBootstrap.test(from: ["Parola", "--test-mode"]))
        #expect(silent.showsIntroduction == false)
        #expect(AppBootstrap.normal.showsIntroduction == false)
    }

    @Test("AppBootstrap.test ignores unknown flags")
    func testIgnoresUnknownFlags() throws {
        let args = [
            "Parola",
            "--test-mode",
            "--library=/tmp/foo",
            "--mystery-flag=whatever",
            "--another-unknown=42",
        ]
        let bootstrap = try #require(AppBootstrap.test(from: args))

        #expect(bootstrap.library?.path == "/tmp/foo")
        #expect(bootstrap.models == nil)
        #expect(bootstrap.defaultsSuite == nil)
    }
}

