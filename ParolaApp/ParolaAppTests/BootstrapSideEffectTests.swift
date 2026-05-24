import Foundation
import Testing
@testable import Parola

@Suite("Bootstrap side-effect sets + launch flag parsing")
struct BootstrapSideEffectTests {

    @Test(".all contains all 12 cases")
    func allHasTwelveCases() {
        #expect(BootstrapSideEffect.all.count == 12)
        let expected: Set<BootstrapSideEffect> = [
            .sparkle, .launchAtLogin, .menuBarExtra, .dockIconRegistration, .appIntentsDonation,
            .meetingDetector, .watchedFolders, .dictationHotkey,
            .libraryPurgeOnLaunch, .refreshYtDlp, .liveCaptionsTranslateRestore,
            .automationBridge,
        ]
        #expect(BootstrapSideEffect.all == expected)
    }

    @Test(".testing is exactly {.automationBridge}")
    func testingIsBridgeOnly() {
        #expect(BootstrapSideEffect.testing == [.automationBridge])
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
            "--cache-dir=/tmp/baz",
            "--defaults-suite=t",
            "--bridge-port=58213",
            "--bridge-token=abc123",
        ]
        let bootstrap = try #require(AppBootstrap.test(from: args))

        if case .test = bootstrap.mode {} else {
            Issue.record("expected bootstrap.mode == .test, got \(bootstrap.mode)")
        }
        #expect(bootstrap.library?.path == "/tmp/foo")
        #expect(bootstrap.models?.path == "/tmp/bar")
        #expect(bootstrap.cacheDir?.path == "/tmp/baz")
        #expect(bootstrap.defaultsSuite == "t")
        #expect(bootstrap.bridgePort == 58213)
        #expect(bootstrap.bridgeToken == "abc123")
        #expect(bootstrap.sideEffects == BootstrapSideEffect.testing)
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
        #expect(bootstrap.bridgeToken == nil)
    }
}

