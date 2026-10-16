import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("clearMocks streaming scope", .serialized)
struct ClearStreamingMockTests {
    private func run(_ name: String, _ args: [String: AutomationValue] = [:]) async throws -> AutomationValue {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("clearstreaming"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let command = try #require(server.mockCommands().first { $0.name == name })
        return try await command.handler(try command.validate(AutomationArgs(args)), AutomationContext(model: model, server: server))
    }

    @Test("the streaming scope removes the streaming mock and listMocks says so")
    func clearsStreaming() async throws {
        MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
            failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
        ))
        defer { MockStreamingTranscriberRegistry.shared.clear() }
        #expect(MockStreamingTranscriberRegistry.shared.resolve() != nil)

        _ = try await run("clearMocks", ["scope": .string("streaming")])

        #expect(MockStreamingTranscriberRegistry.shared.resolve() == nil)
    }

    @Test("other scopes leave the streaming mock alone")
    func otherScopesKeepIt() async throws {
        MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
            failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom")
        ))
        defer { MockStreamingTranscriberRegistry.shared.clear() }

        _ = try await run("clearMocks", ["scope": .string("speech")])

        #expect(MockStreamingTranscriberRegistry.shared.resolve() != nil)
    }
}
