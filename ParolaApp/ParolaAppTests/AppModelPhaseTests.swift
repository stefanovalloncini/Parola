import Foundation
import Testing
@testable import Parola

@Suite("AppModel.Phase")
struct AppModelPhaseTests {
    @Test("idle equals idle")
    func idleEquality() {
        #expect(AppModel.Phase.idle == .idle)
    }

    @Test("downloadingModel compares on name and progress")
    func downloadingEquality() {
        let a = AppModel.Phase.downloadingModel(name: "tiny", progress: 0.5)
        let b = AppModel.Phase.downloadingModel(name: "tiny", progress: 0.5)
        let c = AppModel.Phase.downloadingModel(name: "tiny", progress: 0.6)
        let d = AppModel.Phase.downloadingModel(name: "base", progress: 0.5)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("transcribing compares on file URL")
    func transcribingEquality() {
        let a = AppModel.Phase.transcribing(file: URL(fileURLWithPath: "/tmp/a.wav"))
        let b = AppModel.Phase.transcribing(file: URL(fileURLWithPath: "/tmp/a.wav"))
        let c = AppModel.Phase.transcribing(file: URL(fileURLWithPath: "/tmp/b.wav"))
        #expect(a == b)
        #expect(a != c)
    }

    @Test("recording compares on source")
    func recordingEquality() {
        #expect(AppModel.Phase.recording(source: .microphone) == .recording(source: .microphone))
        #expect(AppModel.Phase.recording(source: .microphone) != .recording(source: .systemAudio))
    }

    @Test("failed compares on message")
    func failedEquality() {
        let a = AppModel.Phase.failed(message: "boom")
        let b = AppModel.Phase.failed(message: "boom")
        let c = AppModel.Phase.failed(message: "other")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("distinct cases never compare equal")
    func distinctCases() {
        #expect(AppModel.Phase.idle != .ready)
        #expect(AppModel.Phase.ready != .loadingModel(name: "tiny"))
        #expect(AppModel.Phase.idle != .downloadingModel(name: "tiny", progress: 0))
    }

    @Test("RecordSource labels are stable strings")
    func recordSourceLabels() {
        #expect(AppModel.RecordSource.microphone.label == "Microphone")
        #expect(AppModel.RecordSource.systemAudio.label == "System audio")
    }

    @Test("Route enum covers transcript, batch, queue")
    func routeAllCases() {
        let raws = AppModel.Route.allCases.map(\.rawValue).sorted()
        #expect(raws == ["batch", "queue", "transcript"])
    }
}
