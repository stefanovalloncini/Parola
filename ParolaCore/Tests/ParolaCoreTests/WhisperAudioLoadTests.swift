import Foundation
import Testing
import WhisperKit
@testable import ParolaCore

@Suite("Whisper audio load", .serialized)
struct WhisperAudioLoadTests {
    private func makeWAV(at url: URL, seconds: Double = 0.3) throws {
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
        try data.write(to: url)
    }

    @Test("a readable file comes back as samples")
    func readableFileLoads() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("input.wav")
        try makeWAV(at: url)

        let samples = try await WhisperKitTranscriber.loadSamples(
            url: url, channelMode: .sumChannels(nil), deadline: .seconds(30)
        )
        #expect(samples.count > 1000)
    }

    @Test("a load that never returns fails the run instead of parking the engine")
    func wedgedLoadTimesOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wedged.wav")
        #expect(mkfifo(url.path, 0o644) == 0, "could not create the FIFO the test needs")
        defer {
            let writer = open(url.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }

        do {
            _ = try await WhisperKitTranscriber.loadSamples(
                url: url, channelMode: .sumChannels(nil), deadline: .seconds(3)
            )
            Issue.record("a load that never returns should fail")
        } catch let error as ParolaError {
            guard case .fileReadTimedOut(let name) = error else {
                Issue.record("expected fileReadTimedOut, got \(error)")
                return
            }
            #expect(name == "wedged.wav")
        }
    }

    @Test("an undecodable file names the audio rather than the engine")
    func undecodableFileFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nonsense.wav")
        try Data("not audio".utf8).write(to: url)

        await #expect(throws: ParolaError.self) {
            _ = try await WhisperKitTranscriber.loadSamples(
                url: url, channelMode: .sumChannels(nil), deadline: .seconds(30)
            )
        }
    }
}
