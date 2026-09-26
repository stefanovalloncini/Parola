import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Language probe scratch")
struct LanguageProbeScratchTests {
    private static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-probe-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Lets the reader parked in `open()` go: a writer opening and closing the FIFO hands it an EOF.
    private static func unpark(_ fifo: URL) {
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
        if descriptor >= 0 { close(descriptor) }
    }

    @Test("a source that never opens times the probe out instead of parking it")
    func stalledSourceTimesOut() async throws {
        let dir = try Self.makeDirectory()
        let fifo = dir.appendingPathComponent("stalled.wav")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        defer {
            Self.unpark(fifo)
            try? FileManager.default.removeItem(at: dir)
        }

        let startedAt = ContinuousClock.now
        var bodyRan = false
        var timedOut = false
        do {
            _ = try await LanguageProbeScratch.withScratch(from: fifo, deadline: .milliseconds(300)) { _ in
                bodyRan = true
            }
        } catch ParolaError.fileReadTimedOut(let name) {
            timedOut = name == "stalled.wav"
        }

        #expect(timedOut)
        #expect(!bodyRan)
        #expect(startedAt.duration(to: .now) < .seconds(5))
    }

    @Test("the scratch exists while the probe listens and is gone afterwards")
    func scratchLivesForTheBody() async throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 3))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(sin(2 * .pi * 440 * Double(frame) / 16_000)) * 0.8
        }
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)

        let scratch = try await LanguageProbeScratch.withScratch(from: source) { url -> URL in
            #expect(FileManager.default.fileExists(atPath: url.path))
            return url
        }

        let used = try #require(scratch)
        #expect(!FileManager.default.fileExists(atPath: used.path))
    }
}

@Suite("In-flight cancel")
struct InFlightCancelTests {
    private actor Calls {
        private(set) var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    @Test("cancel reaches the run that holds the engine, from any task")
    func cancelReachesTheCurrentRun() async {
        let inFlight = InFlightCancel()
        let calls = Calls()
        let first = inFlight.claim { await calls.record("first") }
        #expect(first.prior == nil)

        await Task.detached { await inFlight.cancel() }.value

        #expect(await calls.names == ["first"])
    }

    @Test("a stale run's release leaves the newer run's cancel in place")
    func staleReleaseKeepsTheNewerClaim() async {
        let inFlight = InFlightCancel()
        let calls = Calls()
        let first = inFlight.claim { await calls.record("first") }
        let second = inFlight.claim { await calls.record("second") }
        await second.prior?()

        inFlight.release(first.epoch)
        await inFlight.cancel()
        inFlight.release(second.epoch)
        await inFlight.cancel()

        #expect(await calls.names == ["first", "second"])
    }
}
