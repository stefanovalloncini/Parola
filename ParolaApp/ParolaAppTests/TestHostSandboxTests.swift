import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("The unit-test host runs in a sandbox")
struct TestHostSandboxTests {

    @Test("the host's defaults, library and keys are its own, never the user's")
    func hostIsSandboxed() throws {
        let host = try #require(AppDelegate.launchModel)
        let settingsStore = try #require(ManagedConfiguration.userSettingsStore)

        #expect(host.mode == .test)
        #expect(host.activeSideEffects.isEmpty)
        #expect(!AppDelegate.prunesStaleWindowKeys(host.activeSideEffects))
        #expect(host.defaults !== UserDefaults.standard)
        #expect(DefaultsStore.current !== UserDefaults.standard)
        #expect(settingsStore !== UserDefaults.standard)
        let library = host.library.libraryURL.standardizedFileURL.path
        #expect(library != LibraryStore.defaultLibraryURL.standardizedFileURL.path)
        #expect(library == TestHostSandbox.current.library.standardizedFileURL.path)
        #expect(host.apiKeyStore is InMemoryAPIKeyStore)
    }

    @Test("a setting the host writes never lands in the app's own defaults domain")
    func hostSettingsStayOutOfTheAppDomain() {
        let key = "parola-test-host-probe-\(UUID().uuidString)"
        DefaultsStore.current.set(true, forKey: key)
        defer { DefaultsStore.current.removeObject(forKey: key) }

        let written = DefaultsStore.current.object(forKey: key)
        let leaked = UserDefaults.standard.object(forKey: key)
        #expect(written != nil)
        #expect(leaked == nil)
    }

    @Test("a finished host's suite and folder are swept, a running host's and anything else stay")
    func sweepsOnlyFinishedHosts() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "parola-test-host-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appending(path: "Preferences", directoryHint: .isDirectory)
        let temporary = root.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let finished = TestHostSandbox.namePrefix + "999999"
        let running = TestHostSandbox.namePrefix + String(getpid())
        let finishedIsRunning = TestHostSandbox.isRunning(999_999)
        #expect(!finishedIsRunning)
        for name in [finished, running, "parola-test-D1A3", "app.parola.ParolaApp"] {
            try Data().write(to: preferences.appending(path: "\(name).plist"))
            try FileManager.default.createDirectory(
                at: temporary.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        TestHostSandbox.sweepLeftovers(preferences: preferences, temporary: temporary)

        let preferencesLeft = Set(try FileManager.default.contentsOfDirectory(atPath: preferences.path))
        let temporaryLeft = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path))
        #expect(preferencesLeft == ["\(running).plist", "parola-test-D1A3.plist", "app.parola.ParolaApp.plist"])
        #expect(temporaryLeft == [running, "parola-test-D1A3", "app.parola.ParolaApp"])
    }
}
