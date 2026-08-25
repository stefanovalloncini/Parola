import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Bridge state detail")
struct BridgeStateDetailTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer) {
        let model = AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            libraryURL: makeTempLibraryURL("statedetail")
        )
        return (model, try ParolaAutomationServer(model: model))
    }

    private func object(_ value: AutomationValue, _ key: String) throws -> [String: AutomationValue] {
        guard case .object(let fields) = value, let nested = fields[key] else {
            throw AutomationError.notFound(kind: "field", id: key)
        }
        guard case .object(let out) = nested else {
            throw AutomationError.notFound(kind: "object", id: key)
        }
        return out
    }

    @Test("a run in flight reports its fraction, stage and partial-text presence")
    func transcribingDetailCarriesProgress() throws {
        let (model, server) = try makeRig()
        model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/take.wav"))
        model.fileTranscribeFraction = 0.42
        model.fileTranscribeStage = .transcribing
        model.filePartialText = "half a sentence"

        let detail = try object(server.snapshotState(), "phaseDetail")

        #expect(detail["file"] == .string("/tmp/take.wav"))
        #expect(detail["progress"] == .double(0.42))
        #expect(detail["stage"] == .string("transcribing"))
        #expect(detail["hasPartialText"] == .bool(true))
    }

    @Test("a run that has reported nothing yet keeps the progress keys as null")
    func transcribingDetailBeforeAnyProgress() throws {
        let (model, server) = try makeRig()
        model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/take.wav"))

        let detail = try object(server.snapshotState(), "phaseDetail")

        #expect(detail["progress"] == .null)
        #expect(detail["stage"] == .null)
        #expect(detail["hasPartialText"] == .bool(false))
    }

    @Test("audio preparation is named apart from transcribing")
    func preparingAudioStageName() throws {
        let (model, server) = try makeRig()
        model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/take.wav"))
        model.fileTranscribeStage = .preparingAudio

        let detail = try object(server.snapshotState(), "phaseDetail")

        #expect(detail["stage"] == .string("preparingAudio"))
    }

    @Test("phases other than transcribing keep their own detail shape")
    func downloadDetailUnchanged() throws {
        let (model, server) = try makeRig()
        model.phase = .downloadingModel(name: "openai_whisper-tiny", progress: 0.5)

        let detail = try object(server.snapshotState(), "phaseDetail")

        #expect(detail["name"] == .string("openai_whisper-tiny"))
        #expect(detail["progress"] == .double(0.5))
        #expect(detail["hasPartialText"] == nil)
    }
}
