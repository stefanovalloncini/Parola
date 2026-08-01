import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Capture file writer")
struct CaptureFileWriterTests {
    @Test("a clean run reports no failure")
    func cleanRun() throws {
        let counter = WriteCounter()
        let writer = CaptureFileWriter { _ in counter.bump() }
        writer.write(Self.buffer())
        writer.write(Self.buffer())

        #expect(counter.count == 2)
        #expect(writer.failure == nil)
    }

    @Test("a failing write is latched and later writes are skipped")
    func failedWriteStopsWriting() throws {
        let counter = WriteCounter()
        let writer = CaptureFileWriter { _ in
            counter.bump()
            throw CocoaError(.fileWriteOutOfSpace)
        }
        writer.write(Self.buffer())
        writer.write(Self.buffer())
        writer.write(Self.buffer())

        #expect(counter.count == 1)
        #expect(writer.failure != nil)
    }

    @Test("the first failure wins")
    func firstFailureWins() {
        let writer = CaptureFileWriter { _ in }
        writer.fail("fell behind")
        writer.fail("disk full")

        #expect(writer.failure == "fell behind")
    }

    @Test("a reported drop is counted without failing the take")
    func dropKeepsWriting() throws {
        let counter = WriteCounter()
        let writer = CaptureFileWriter { _ in counter.bump() }
        writer.noteDrop()
        writer.noteDrop()
        writer.write(Self.buffer())

        #expect(counter.count == 1)
        #expect(writer.droppedChunks == 2)
        #expect(writer.failure == nil)
    }

    @Test("writes land in the backing file")
    func writesLandInFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-writer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        var writer: CaptureFileWriter? = try Self.fileWriter(at: url)
        writer?.write(Self.buffer(frames: 8))
        writer?.write(Self.buffer(frames: 8))
        writer = nil

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16)
    }

    private static func fileWriter(at url: URL) throws -> CaptureFileWriter {
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        return CaptureFileWriter(file: file)
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private static func buffer(frames: AVAudioFrameCount = 8) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
