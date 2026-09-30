import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// A capture that is already done: Stop hands back its file.
struct StubSource: LiveAudioSource {
    let url: URL
    func start() async throws {}
    func prepare() async throws -> URL { url }
    func cancel() async {}
}

func tempWAV(_ label: String = "take") throws -> URL {
    try makeTakeWAV(label, prefix: "parola-test")
}

func makeTakeWAV(_ label: String, seconds: Double = 0.3, in directory: URL? = nil, prefix: String = "parola-trust") throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * seconds)
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
    let folder = directory ?? FileManager.default.temporaryDirectory
    let url = folder.appendingPathComponent("\(prefix)-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

/// A model for take tests: test mode, a library of its own, room on disk, no AI cards and no count-in.
@MainActor
func makeRecordingModel(_ label: String, clock: any Clock<Duration> = ContinuousClock()) -> AppModel {
    let model = AppModel(bootstrap: AppBootstrap(
        mode: .test, library: makeTempLibraryURL(label), defaultsOverride: temporaryDefaults(),
        sideEffects: [], filePicker: TestFilePicker(), clock: clock
    ))
    model.recordingCountInSeconds = 0
    model.freeDiskSpaceProvider = { 50_000_000_000 }
    model.cardMetadataOperation = { _ in nil }
    return model
}

struct FixtureTakeDidNotStart: Error {}

/// A mic take from a silent fixture, once its clock runs; a take treats its fixture as its own audio, so `copyingFixture` puts it in the in-flight folder, where the take may delete it.
@MainActor
@discardableResult
func startFixtureTake(_ model: AppModel, copyingFixture: Bool = false, seconds: Double = 0.3) async throws -> URL {
    let folder = copyingFixture
        ? model.inflightRecordingsURL
        : model.library.libraryURL.appendingPathComponent("fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fixture = try makeTakeWAV("fixture", seconds: seconds, in: folder, prefix: copyingFixture ? "parola-mic" : "parola-test")
    await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
    model.useStreaming = false
    model.startRecording(source: .microphone)
    let capturing = await waitUntil { model.recording?.state == .recording && model.recording?.audioURL != nil }
    guard capturing else { throw FixtureTakeDidNotStart() }
    return fixture
}

/// Every file transcription answers with these segments until the mocks are cleared.
func installMockTranscriber(segments: [(start: Double, end: Double, text: String)], gate: MockTranscriberGate? = nil) async {
    await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
        segments: segments.map { TranscriptSegmentSeed(start: $0.start, end: $0.end, text: $0.text) },
        gate: gate
    ))
}

/// The newest entry in the model's library, once one has landed.
@MainActor
func landedEntry(_ model: AppModel, timeoutMs: Int = 5_000) async -> LibraryEntry? {
    var landed: LibraryEntry?
    await waitUntil(timeoutMs: timeoutMs) {
        landed = await model.library.list().first
        return landed != nil
    }
    return landed
}
