import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Bootstrap side-effect sets + launch flag parsing")
struct BootstrapSideEffectTests {

    @Test(".all contains all 14 cases")
    func allHasFourteenCases() {
        #expect(BootstrapSideEffect.all.count == 14)
        let expected: Set<BootstrapSideEffect> = [
            .sparkle, .launchAtLogin, .menuBarExtra, .dockIconRegistration, .appIntentsDonation,
            .meetingDetector, .watchedFolders, .dictationHotkey,
            .libraryPurgeOnLaunch, .refreshYtDlp, .liveCaptionsTranslateRestore,
            .automationBridge, .modelsPathSync, .diagnosticsLog,
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

    @Test(".testing is a subset of .all")
    func testingIsSubsetOfAll() {
        #expect(BootstrapSideEffect.testing.isSubset(of: BootstrapSideEffect.all))
    }

    @Test("AppBootstrap.test returns nil without --test-mode")
    func testReturnsNilWithoutFlag() {
        let bootstrap = AppBootstrap.test(from: ["Parola", "--library=/tmp/x"])
        #expect(bootstrap == nil)
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

