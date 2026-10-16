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
        for name in ["readAloud", "pauseReading", "resumeReading", "skipReading", "setReadingSpeed", "stopReading", "waitForReadingState", "installMockVoice", "listVoices", "chooseVoice", "previewVoice"] {
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

    @Test("listVoices names the voices that read a language, and the saved one")
    func listVoices() async throws {
        let rig = try makeRig()
        let listed = try await run(rig, "listVoices", ["language": .string("en-GB")])
        #expect(try field(listed, "language") == .string("en"))
        #expect(try field(listed, "saved") == .null)
        guard case .array(let voices) = try field(listed, "voices") else {
            Issue.record("listVoices has no voices")
            return
        }
        let ids = voices.compactMap { value -> String? in
            guard case .object(let fields) = value, case .string(let id)? = fields["voiceID"] else { return nil }
            return id
        }
        #expect(ids == ["apple:auto", "apple:com.parola.mock.en.premium", "apple:com.parola.mock.en.compact"])

        let none = try await run(rig, "listVoices", ["language": .string("fa")])
        #expect(try field(none, "voices") == .array([]))
    }

    @Test("chooseVoice saves a voice, refuses one that isn't installed, and the next read uses it")
    func chooseVoice() async throws {
        let rig = try makeRig()
        load(rig.model)
        let id = "apple:com.parola.mock.en.premium"

        let saved = try await run(rig, "chooseVoice", ["language": .string("en"), "voiceID": .string(id)])
        #expect(try field(saved, "saved") == .bool(true))
        #expect(rig.model.readAloudVoices["en"]?.rawValue == id)
        let listed = try await run(rig, "listVoices", ["language": .string("en")])
        #expect(try field(listed, "saved") == .string(id))

        let missing = try await run(rig, "chooseVoice", ["language": .string("en"), "voiceID": .string("apple:nope")])
        #expect(try field(missing, "saved") == .bool(false))
        #expect(rig.model.readAloudVoices["en"]?.rawValue == id)

        await #expect(throws: AutomationError.self) {
            _ = try await self.run(rig, "chooseVoice", ["language": .string("en"), "voiceID": .string("not a voice id/ ")])
        }

        _ = try await run(rig, "readAloud")
        _ = try await run(rig, "waitForReadingState", ["state": .string("reading")])
        guard case .object(let reading) = ParolaAutomationServer.readAloudState(rig.model) else { return }
        #expect(reading["voiceID"] == .string(id))
        _ = try await run(rig, "stopReading")
    }

    @Test("getState reports the open chooser, and chooseVoice answers it")
    func voicePromptState() async throws {
        let rig = try makeRig()
        load(rig.model)
        rig.model.presentVoiceChooser(for: .transcript)

        guard case .object(let open) = ParolaAutomationServer.readAloudState(rig.model),
              case .object(let prompt)? = open["voicePrompt"] else {
            Issue.record("no voicePrompt")
            return
        }
        #expect(prompt["language"] == .string("en"))
        #expect(prompt["state"] == .string("choose"))
        #expect(prompt["origin"] == .string("main"))

        _ = try await run(rig, "chooseVoice", ["language": .string("en"), "voiceID": .string("apple:auto")])
        _ = try await run(rig, "waitForReadingState", ["state": .string("reading")])
        guard case .object(let after) = ParolaAutomationServer.readAloudState(rig.model) else { return }
        #expect(after["voicePrompt"] == .null)
        _ = try await run(rig, "stopReading")
    }

    @Test("a language the mock voices don't read gives the no-voice prompt, and readAloud says why")
    func noVoicePrompt() async throws {
        let rig = try makeRig()
        load(rig.model)
        _ = try await run(rig, "installMockVoice", ["languages": .array([.string("it")])])

        let reply = try await run(rig, "readAloud")
        #expect(try field(reply, "started") == .bool(false))
        #expect(try field(reply, "reason") == .string("noVoice"))
        guard case .object(let state) = ParolaAutomationServer.readAloudState(rig.model),
              case .object(let prompt)? = state["voicePrompt"] else {
            Issue.record("no voicePrompt")
            return
        }
        #expect(prompt["state"] == .string("noVoice"))
        #expect(state["state"] == .string("noVoice"))

        _ = try await run(rig, "clearMocks", ["scope": .string("speech")])
        #expect(rig.model.readAloud.mockVoice?.languages == MockVoiceSettings.defaultLanguages)
    }

    @Test("previewVoice pauses a reading and is refused during a take")
    func previewVoice() async throws {
        let rig = try makeRig()
        load(rig.model)
        _ = try await run(rig, "readAloud")
        _ = try await run(rig, "waitForReadingState", ["state": .string("reading")])

        let preview = try await run(rig, "previewVoice", ["voiceID": .string("apple:auto")])
        #expect(try field(preview, "started") == .bool(true))
        #expect(rig.model.readAloud.state == .paused(.user))

        rig.model.installTestTake(source: .microphone, liveSource: StubSource())
        await waitUntil { rig.model.readAloud.state == .paused(.take) }
        let refused = try await run(rig, "previewVoice", ["voiceID": .string("apple:auto")])
        #expect(try field(refused, "started") == .bool(false))
        #expect(try field(refused, "reason") == .string("blocked"))
        rig.model.endTestTake()
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
