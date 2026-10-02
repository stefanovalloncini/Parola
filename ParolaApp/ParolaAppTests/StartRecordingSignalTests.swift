import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Start Recording signal", .serialized)
    struct StartRecordingSignalTests {
        @Test("the Start Recording intent's signal starts a microphone take with no window open")
        func signalStartsATake() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("start-signal")
                let folder = model.library.libraryURL.appendingPathComponent("fixtures", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let fixture = try makeTakeWAV("signal", in: folder, prefix: "parola-test")
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                model.useStreaming = false
                let center = NotificationCenter()
                let token = AppDelegate.observeStartRecording(for: model, on: center)
                defer { center.removeObserver(token) }

                center.post(name: .parolaStartRecording, object: nil)

                let capturing = await waitUntil { model.recording?.state == .recording }
                let source = model.recording?.source
                let window = model.mainWindow
                #expect(capturing)
                #expect(source == .microphone)
                #expect(window == nil)
                await model.discardTake()
            }
        }
    }
}

@Suite("Start Recording signal wiring")
struct StartRecordingSignalWiringTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/StartRecordingSignalTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("the app delegate hears the signal from launch, and the main window no longer does")
    func heardByTheApp() throws {
        #expect(try source("AppDelegate").contains("Self.observeStartRecording(for: model)"))
        #expect(try !source("Views/ContentView").contains("parolaStartRecording"))
    }
}
