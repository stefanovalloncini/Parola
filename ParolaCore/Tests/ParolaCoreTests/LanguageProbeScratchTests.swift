import AVFoundation
import Foundation
import Testing
import os
@testable import ParolaCore
import ParolaTestSupport

@Suite("Language probe scratch")
struct LanguageProbeScratchTests {
    private static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-probe-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a source that never opens times the probe out instead of parking it")
    func stalledSourceTimesOut() async throws {
        let dir = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("stalled.wav")
        #expect(mkfifo(fifo.path, 0o644) == 0)

        let clock = TestClock()
        let bodyRan = TestSignal()
        let timedOut = try await FIFOFixture.holding(fifo) {
            let probe = GuardedTask { () -> Bool in
                do {
                    _ = try await LanguageProbeScratch.withScratch(
                        from: fifo, deadline: .milliseconds(300), clock: clock
                    ) { _ in bodyRan.fire() }
                    return false
                } catch ParolaError.fileReadTimedOut(let name) {
                    return name == "stalled.wav"
                }
            }
            await clock.waitForSleeper()
            clock.advance(by: .milliseconds(300))
            return try await probe.value("the probe to time out while the source is still parked")
        }

        #expect(timedOut == true)
        #expect(!bodyRan.fired)
    }

    @Test("a read that resumes after the deadline deletes the scratch it went on to write")
    func lateWriteCleansUpAfterItself() async throws {
        let clock = TestClock()
        let resume = DispatchSemaphore(value: 0)
        let written = Awaitable<URL?>(nil)
        let source = URL(fileURLWithPath: "/tmp/parola-stalled-share.wav")
        let probe = GuardedTask {
            try await LanguageProbeScratch.withScratch(
                from: source,
                deadline: .milliseconds(100),
                clock: clock,
                extract: { _, scratch in
                    resume.wait()
                    FileManager.default.createFile(atPath: scratch.path, contents: Data("late".utf8))
                    written.update { $0 = scratch }
                    return true
                }
            ) { _ in }
        }

        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(100))
        await #expect(throws: ParolaError.self) {
            _ = try await probe.value("the probe to time out while the read is still parked")
        }
        resume.signal()

        guard await written.wait(until: { $0 != nil }, "the late read to write its scratch"),
              let scratch = written.value else { return }
        defer { try? FileManager.default.removeItem(at: scratch) }
        await pollUntil("the late read to delete its scratch") {
            !FileManager.default.fileExists(atPath: scratch.path)
        }
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
