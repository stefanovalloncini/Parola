import Foundation
import ParolaCore

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
