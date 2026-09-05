import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Bridge YouTube commands")
struct YouTubeCommandsTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("youtubecommands"),
            defaultsOverride: UserDefaults(suiteName: "test-\(UUID())")!,
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let pairs = (server.transcriptCommands() + server.windowCommands()).map { ($0.name, $0) }
        return (model, server, context, Dictionary(uniqueKeysWithValues: pairs))
    }

    private static let link = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    @Test("transcribeYouTube owns up to parking a link handed over during a take")
    func transcribeYouTubeReportsParked() async throws {
        let (model, server, context, commands) = try makeRig()
        model.phase = .recording(source: .microphone)
        let command = try #require(commands["transcribeYouTube"])
        let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(result == .object(["started": .bool(false), "parked": .bool(true)]))
        #expect(model.deferredLinks == [.transcribe(Self.link)])
        #expect(model.phase == .recording(source: .microphone))
    }

    @Test("transcribeYouTube reports a run it really started")
    func transcribeYouTubeReportsStarted() async throws {
        MockMediaFetcherRegistry.shared.install(URL(fileURLWithPath: "/tmp/missing-\(UUID()).wav"))
        defer { MockMediaFetcherRegistry.shared.clear() }
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["transcribeYouTube"])
        let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}
        model.cancelCurrentWork()

        #expect(result == .object(["started": .bool(true), "parked": .bool(false)]))
        #expect(model.deferredLinks.isEmpty)
    }

    @Test("fetchYouTubeSubs owns up to parking a fetch handed over during a take")
    func fetchYouTubeSubsReportsParked() async throws {
        let (model, server, context, commands) = try makeRig()
        model.phase = .recording(source: .microphone)
        let command = try #require(commands["fetchYouTubeSubs"])
        let args = try command.validate(AutomationArgs(["url": .string(Self.link)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(result == .object(["started": .bool(false), "parked": .bool(true)]))
        #expect(model.deferredLinks == [.subtitles(Self.link)])
        #expect(model.phase == .recording(source: .microphone))
    }

    @Test("a URL yt-dlp cannot take is neither started nor parked")
    func fetchYouTubeSubsReportsRefusal() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["fetchYouTubeSubs"])
        let args = try command.validate(AutomationArgs(["url": .string("https://example.com/clip")]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(result == .object(["started": .bool(false), "parked": .bool(false)]))
        #expect(model.deferredLinks.isEmpty)
    }
}
