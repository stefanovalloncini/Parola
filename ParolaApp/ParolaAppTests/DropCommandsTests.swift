import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge drop commands")
struct DropCommandsTests {

    private func makeRig(
        mode: AppBootstrap.Mode = .test
    ) throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let bootstrap = AppBootstrap(
            mode: mode,
            library: makeTempLibraryURL("dropcommands"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.batchCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func makeMediaFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropCommandsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    @Test("dropFiles on the queue half enqueues the files")
    func dropFilesQueueHalf() async throws {
        let (model, server, context, commands) = try makeRig()
        model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/running.wav"), status: .transcribing)]
        let file = try makeMediaFile("clip.mkv")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let command = try #require(commands["dropFiles"])
        let args = try command.validate(AutomationArgs([
            "paths": .array([.string(file.path)]),
            "half": .string("queue"),
        ]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(result == .object([
            "half": .string("queue"),
            "count": .int(1),
            "route": .string("batch"),
        ]))
        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "clip.mkv"])
    }

    @Test("dropFiles defaults to the transcribe half")
    func dropFilesDefaultsToNow() async throws {
        let (model, server, context, commands) = try makeRig()
        model.fileTranscribeTask = Task {}
        let file = try makeMediaFile("clip.wav")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let command = try #require(commands["dropFiles"])
        let args = try command.validate(AutomationArgs(["paths": .array([.string(file.path)])]))

        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.route == .transcript)
        #expect(model.deferredArrivals == [file])
        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
    }

    @Test("dropFiles rejects a path that isn't there")
    func dropFilesRejectsMissingPath() async throws {
        let (_, server, context, commands) = try makeRig()
        let command = try #require(commands["dropFiles"])
        let args = try command.validate(AutomationArgs(["paths": .array([.string("/tmp/does-not-exist.wav")])]))

        await #expect(throws: AutomationError.self) {
            _ = try await command.handler(args, context)
        }
        withExtendedLifetime(server) {}
    }

    @Test("previewDropZone shapes the overlay and getState reports it")
    func previewShapesTheOverlay() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["previewDropZone"])
        let args = try command.validate(AutomationArgs([
            "payload": .string("media"),
            "count": .int(4),
            "half": .string("queue"),
        ]))

        _ = try await command.handler(args, context)

        #expect(model.dropDragPayload == .media(count: 4))
        #expect(model.dropHighlight == .queue)
        #expect(model.dropZonePlan == .split(count: 4))

        guard case .object(let state) = server.snapshotState() else {
            Issue.record("getState returned no object")
            return
        }
        #expect(state["dropPayload"] == .string("media"))
        #expect(state["dropPayloadCount"] == .int(4))
        #expect(state["dropHighlight"] == .string("queue"))
        #expect(state["dropZones"] == .string("split"))
    }

    @Test("previewDropZone with an empty payload clears the overlay")
    func previewClears() async throws {
        let (model, server, context, commands) = try makeRig()
        model.dropDragPayload = .media(count: 2)
        model.dropHighlight = .now
        let command = try #require(commands["previewDropZone"])
        let args = try command.validate(AutomationArgs(["payload": .string("")]))

        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.dropDragPayload == nil)
        #expect(model.dropHighlight == nil)
        #expect(model.dropZonePlan == .none)
    }

    @Test("previewDropZone stays out of a normal build")
    func previewNeedsTestMode() async throws {
        let (_, server, context, commands) = try makeRig(mode: .normal)
        let command = try #require(commands["previewDropZone"])
        let args = try command.validate(AutomationArgs(["payload": .string("media")]))

        await #expect(throws: AutomationError.self) {
            _ = try await command.handler(args, context)
        }
        withExtendedLifetime(server) {}
    }
}
