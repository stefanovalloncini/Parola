import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Streaming audio persister")
struct StreamingAudioPersisterTests {
    @Test("appended samples land in a readable WAV")
    func appendsToWav() async throws {
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        persister.append([0.1, 0.2, 0.3])
        persister.append([0.4, 0.5])
        let url = try #require(await persister.finish())
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 5)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        #expect(samples.count == 5)
        #expect(abs(samples[0] - 0.1) < 0.0001)
        #expect(abs(samples[4] - 0.5) < 0.0001)
    }

    @Test("finish with no samples returns nil and leaves no file")
    func emptyRecordingYieldsNil() async throws {
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        #expect(await persister.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: persister.url.path))
    }

    @Test("a backlog drop keeps the audio that did land")
    func dropKeepsWrittenAudio() async throws {
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        persister.append([0.1, 0.2])
        persister.noteDrop()

        let url = try #require(await persister.finish())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(persister.droppedAudio)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a write that fails keeps the audio written before it")
    func failedWriteKeepsWrittenAudio() async throws {
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000, failingAfter: 1))
        persister.append([0.1, 0.2, 0.3])
        persister.append([0.4, 0.5])
        persister.append([0.6])

        let url = try #require(await persister.finish())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(persister.writeFailed)
        #expect(try AVAudioFile(forReading: url).length == 3)
    }

    @Test("a write that fails before anything landed leaves no file")
    func failedFirstWriteLeavesNothing() async throws {
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000, failingAfter: 0))
        persister.append([0.1, 0.2])

        #expect(await persister.finish() == nil)
        #expect(persister.writeFailed)
        #expect(!FileManager.default.fileExists(atPath: persister.url.path))
    }

    @Test("discard deletes the written file")
    func discardDeletesFile() async throws {
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        persister.append([0.1, 0.2])
        await persister.discard()
        #expect(!FileManager.default.fileExists(atPath: persister.url.path))
    }
}
