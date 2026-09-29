import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Repairing a take's WAV header", .tags(.fileSystem))
struct WAVHeaderRepairTests {
    private func makeWAV(frames: AVAudioFrameCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-repair-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    /// What a writer that never closed its file leaves: the sizes it wrote when it opened.
    private func zeroSizes(of url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let dataChunk = try #require(bytes.range(of: Data("data".utf8)))
        bytes.replaceSubrange(4..<8, with: Data(count: 4))
        bytes.replaceSubrange(dataChunk.upperBound..<(dataChunk.upperBound + 4), with: Data(count: 4))
        try bytes.write(to: url)
    }

    @Test("a take whose writer never closed it opens again, with every frame it holds")
    func repairsZeroedSizes() throws {
        let url = try makeWAV(frames: 1_600)
        defer { try? FileManager.default.removeItem(at: url) }
        try zeroSizes(of: url)
        #expect(((try? AVAudioFile(forReading: url))?.length ?? 0) == 0)

        #expect(WAVHeaderRepair.makeReadable(url))

        #expect(try AVAudioFile(forReading: url).length == 1_600)
    }

    @Test("a file that already opens is left as it is")
    func leavesAGoodFileAlone() throws {
        let url = try makeWAV(frames: 800)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(WAVHeaderRepair.makeReadable(url))

        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a file that isn't a WAV, or has no audio after its header, stays unreadable")
    func refusesWhatItCannotFix() throws {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("parola-repair-\(UUID().uuidString).wav")
        try Data("not audio at all".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        #expect(!WAVHeaderRepair.makeReadable(text))

        let empty = try makeWAV(frames: 1)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bytes = try Data(contentsOf: empty)
        let dataChunk = try #require(bytes.range(of: Data("data".utf8)))
        try bytes.prefix(dataChunk.upperBound + 4).write(to: empty)
        #expect(!WAVHeaderRepair.makeReadable(empty))
    }
}
