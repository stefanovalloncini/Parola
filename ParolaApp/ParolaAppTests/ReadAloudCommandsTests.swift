import Foundation
import ParolaCore
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Bridge Read Aloud commands", .serialized)
struct ReadAloudCommandsTests {
    private struct Rig {
        let model: AppModel
        let server: ParolaAutomationServer
        let context: AutomationContext
        let commands: [String: AutomationCommand]
    }

    private func makeRig(mode: AppBootstrap.Mode = .test) throws -> Rig {
        let bootstrap = AppBootstrap(
            mode: mode,
            library: makeTempLibraryURL("readaloudcommands"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        var commands = Dictionary(uniqueKeysWithValues: server.readAloudCommands().map { ($0.name, $0) })
        for command in server.mockCommands() { commands[command.name] = command }
        return Rig(model: model, server: server, context: context, commands: commands)
    }

    private func load(_ model: AppModel, segments: Int = 4) {
        model.transcript = Transcript(
            segments: (0..<segments).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "Segment \($0) is here.")
            },
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
    }

    private func run(_ rig: Rig, _ name: String, _ args: [String: AutomationValue] = [:]) async throws -> AutomationValue {
        let command = try #require(rig.commands[name])
        return try await command.handler(try command.validate(AutomationArgs(args)), rig.context)
    }

    private func field(_ value: AutomationValue, _ key: String) throws -> AutomationValue {
        guard case .object(let fields) = value, let found = fields[key] else {
            throw AutomationError.notFound(kind: "field", id: key)
        }
        return found
    }

    @Test("the server lists every Read Aloud command")
    func catalog() throws {
        let rig = try makeRig()
        let names = Set(rig.server.commandNames())
        for name in ["readAloud", "pauseReading", "resumeReading", "skipReading", "setReadingSpeed", "stopReading", "waitForReadingState", "installMockVoice"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test("read, pause, resume, skip and stop drive the reading, and getState describes it")
    func driveAReading() async throws {
        let rig = try makeRig()
        load(rig.model)

        let started = try await run(rig, "readAloud")
        #expect(try field(started, "started") == .bool(true))
        let waited = try await run(rig, "waitForReadingState", ["state": .string("reading")])
        #expect(try field(waited, "matched") == .bool(true))

        guard case .object(let state) = rig.server.snapshotState(), case .object(let reading)? = state["readAloud"] else {
            Issue.record("getState has no readAloud")
            return
        }
        #expect(reading["state"] == .string("reading"))
        #expect(reading["source"] == .string("transcript"))
        #expect(reading["unitCount"] == .int(4))
        #expect(reading["unitIndex"] == .int(0))
        #expect(reading["language"] == .string("en"))
        #expect(reading["voiceID"] == .string("apple:auto"))
        #expect(reading["engine"] == .string("apple"))
        #expect(reading["speed"] == .double(1))
        #expect(reading["blockedReason"] == .null)
        #expect(reading["pausedBy"] == .null)

        _ = try await run(rig, "pauseReading")
        let paused = try await run(rig, "waitForReadingState", ["state": .string("paused"), "pausedBy": .string("user")])
        #expect(try field(paused, "matched") == .bool(true))

        let resumed = try await run(rig, "resumeReading")
        #expect(try field(resumed, "resumed") == .bool(true))
        _ = try await run(rig, "skipReading", ["by": .int(1)])
        let advanced = try await run(rig, "waitForReadingState", ["state": .string("reading"), "unitIndex": .int(1)])
        #expect(try field(advanced, "matched") == .bool(true))

        _ = try await run(rig, "stopReading")
        #expect(rig.model.readAloud.state == .idle)
    }

    @Test("a take refuses Read and Resume with the reason")
    func refusalDuringTake() async throws {
        let rig = try makeRig()
        load(rig.model)
        _ = try await run(rig, "readAloud")
        _ = try await run(rig, "waitForReadingState", ["state": .string("reading")])

        rig.model.installTestTake(source: .microphone, liveSource: StubSource())
        _ = try await run(rig, "waitForReadingState", ["state": .string("paused"), "pausedBy": .string("take")])

        let read = try await run(rig, "readAloud")
        #expect(try field(read, "started") == .bool(false))
        #expect(try field(read, "blockedReason") == .string("take"))
        let resume = try await run(rig, "resumeReading")
        #expect(try field(resume, "resumed") == .bool(false))
        #expect(try field(resume, "blockedReason") == .string("take"))

        rig.model.endTestTake()
        _ = try await run(rig, "stopReading")
    }

    @Test("the speed is one of five, and the setting is writable")
    func speed() async throws {
        let rig = try makeRig()
        let set = try await run(rig, "setReadingSpeed", ["rate": .double(1.25)])
        #expect(try field(set, "speed") == .double(1.25))
        #expect(rig.model.readAloudRate == 1.25)
        #expect(ParolaAutomationServer.writableSettingKeys.contains("readAloudRate"))

        await #expect(throws: AutomationError.self) {
            _ = try await self.run(rig, "setReadingSpeed", ["rate": .double(3)])
        }
    }

    @Test("a mock voice sets how long a sentence lasts and where one fails; clearMocks speech puts it back")
    func mockVoice() async throws {
        let rig = try makeRig()
        load(rig.model)

        let installed = try await run(rig, "installMockVoice", ["msPerUnit": .int(40), "failAtUnit": .int(1)])
        #expect(try field(installed, "installed") == .bool(true))
        let listed = try await run(rig, "listMocks")
        guard case .object(let speech) = try field(listed, "speech") else {
            Issue.record("listMocks has no speech")
            return
        }
        #expect(speech["msPerUnit"] == .int(40))
        #expect(speech["failAtUnit"] == .int(1))

        _ = try await run(rig, "readAloud")
        let failed = try await run(rig, "waitForReadingState", ["state": .string("failed")])
        #expect(try field(failed, "matched") == .bool(true))

        _ = try await run(rig, "clearMocks", ["scope": .string("speech")])
        guard case .object(let cleared) = try field(try await run(rig, "listMocks"), "speech") else { return }
        #expect(cleared["installed"] == .bool(false))
        #expect(cleared["msPerUnit"] == .int(MockVoiceSettings.defaultMsPerUnit))
        _ = try await run(rig, "stopReading")
    }

    @Test("installing a mock voice is for test mode only")
    func mockVoiceNeedsTestMode() async throws {
        let rig = try makeRig(mode: .normal)
        await #expect(throws: AutomationError.self) {
            _ = try await self.run(rig, "installMockVoice")
        }
    }

    private struct StubSource: AudioSource {
        func prepare() async throws -> URL { URL(fileURLWithPath: "/tmp/stub-\(UUID()).wav") }
        func cancel() async {}
        func estimatedDuration() async -> Double? { nil }
    }
}
