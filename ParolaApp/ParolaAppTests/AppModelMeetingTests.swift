import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("AppModel meeting detection")
struct AppModelMeetingTests {
    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            libraryURL: makeTempLibraryURL("meeting")
        )
    }

    @Test("a fired detection surfaces the app name on the model")
    func fireSetsDetectedApp() {
        let model = makeModel()
        model.meetingDetector.isEnabled = true
        model.meetingDetectedApp = nil

        model.meetingDetector.fire(appName: "Acme Conference")

        #expect(model.meetingDetectedApp == "Acme Conference")
    }

    @Test("dismissing the prompt clears the detected app")
    func dismissClearsDetectedApp() {
        let model = makeModel()
        model.meetingDetectedApp = "Zoom"

        model.dismissMeetingPrompt()

        #expect(model.meetingDetectedApp == nil)
    }

    @Test("starting a meeting recording tags it as a Meeting and clears the prompt")
    func startMeetingRecordingSelectsMeetingCategory() async {
        let fixture = try? makeSilentMeetingWAV()
        guard let fixture else { Issue.record("could not write fixture"); return }
        defer { try? FileManager.default.removeItem(at: fixture) }
        await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)
        defer { Task { await MockAudioSourceRegistry.shared.clear() } }

        let model = makeModel()
        model.meetingDetectedApp = "Zoom"

        model.startMeetingRecording()

        #expect(model.pendingRecordingCategory == .meeting)
        #expect(model.meetingDetectedApp == nil)

        model.cancelCurrentWork()
        #expect(model.pendingRecordingCategory == .transcription)
    }

    private func makeSilentMeetingWAV() throws -> URL {
        let sampleRate = 16_000, channels = 1, bytesPerSample = 2
        let frames = Int(Double(sampleRate) * 0.3)
        let dataBytes = frames * channels * bytesPerSample
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
        le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
        ascii("data"); le32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-meeting-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}
