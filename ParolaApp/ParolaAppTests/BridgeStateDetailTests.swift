import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge state detail")
struct BridgeStateDetailTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer) {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
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

    @Test("favoriteSegments and favoritesOnly reflect the selected entry and the filter")
    func favoriteSegmentsInState() throws {
        let (model, server) = try makeRig()
        model.libraryEntries = [
            LibraryEntry(
                id: "a",
                bundleURL: URL(fileURLWithPath: "/tmp/BridgeStateDetailTests/a.parola"),
                manifest: ParolaDocument.Manifest(
                    originalAudioName: "a.m4a", modelName: "stub", language: "en", favoriteSegments: [3, 1]
                )
            ),
        ]
        model.selectedEntryID = "a"
        model.favoritesOnly = true

        guard case .object(let fields) = server.snapshotState() else {
            Issue.record("getState should return an object")
            return
        }

        #expect(fields["favoriteSegments"] == .array([.int(1), .int(3)]))
        #expect(fields["favoritesOnly"] == .bool(true))
    }
}
