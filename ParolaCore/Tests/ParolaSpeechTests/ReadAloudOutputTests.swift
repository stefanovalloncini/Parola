import AVFoundation
import Foundation
import Testing
@testable import ParolaSpeech

@Suite("ReadAloudOutput, offline")
@MainActor
struct ReadAloudOutputTests {
    @Test("a unit renders for as long as it was recorded after resampling to 48 kHz", arguments: [22_050.0, 44_100.0])
    func resampledLength(sourceRate: Double) async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: sourceRate), sampleRate: sourceRate), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()

        let rendered = try render(output, seconds: 1.5)
        let sound = try #require(soundSpan(in: rendered))
        #expect(abs(sound.count - 48_000) <= 16)
        #expect(abs(peak(rendered[sound]) - 0.1) < 0.002)
        await events.wait(count: 1)
        #expect(events.received == [UnitFinished(epoch: 0, unitID: 0)])
    }

    @Test("at 2× the time-pitch unit plays a unit in half the time")
    func doubleSpeed() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.setSpeed(2)
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 2, rate: 24_000), sampleRate: 24_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()

        let rendered = try render(output, seconds: 2)
        let sound = try #require(soundSpan(in: rendered))
        #expect(abs(Double(sound.count) - 48_000) <= 48_000 * 0.05)
        await events.wait(count: 1)
    }

    @Test("speed stays between 0.75× and 2×")
    func speedClamps() throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        output.setSpeed(3)
        #expect(output.speed == 2)
        output.setSpeed(0.5)
        #expect(output.speed == 0.75)
        output.setSpeed(1.25)
        #expect(output.speed == 1.25)
    }

    @Test("two chunks of one unit join without a jump and keep the resampler's tail")
    func chunkJoin() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        let tone = sine(seconds: 1, rate: 22_050)
        output.schedule(PCMChunk(unitID: 0, samples: Array(tone[..<10_001]), sampleRate: 22_050), epoch: 0, gainDB: 0)
        output.schedule(PCMChunk(unitID: 0, samples: Array(tone[10_001...]), sampleRate: 22_050), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()

        let rendered = try render(output, seconds: 1.5)
        let sound = try #require(soundSpan(in: rendered))
        let inside = (sound.lowerBound + 200)..<(sound.upperBound - 200)
        #expect(maxCurvature(rendered[inside]) < 0.003)
        #expect(abs(sound.count - 48_000) <= 16)
        await events.wait(count: 1)
    }

    @Test("units finish in order, each carrying the epoch it was scheduled with")
    func finishOrder() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        for unit in 0..<3 {
            output.schedule(PCMChunk(unitID: unit, samples: sine(seconds: 0.2, rate: 24_000), sampleRate: 24_000), epoch: 3, gainDB: 0)
            output.finishUnit(unit, epoch: 3, pauseAfter: 0.1)
        }
        try output.resume()

        _ = try render(output, seconds: 1.2)
        await events.wait(count: 3)
        #expect(events.received == (0..<3).map { UnitFinished(epoch: 3, unitID: $0) })
    }

    @Test("completions from before a stop are dropped and the stream goes on")
    func stopDropsStaleCompletions() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        output.schedule(PCMChunk(unitID: 1, samples: sine(seconds: 1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(1, epoch: 0, pauseAfter: 0)
        try output.resume()
        _ = try render(output, seconds: 0.3)
        let before = output.generation

        output.stop()
        #expect(output.generation == before + 1)
        #expect(output.state == .idle)
        output.schedule(PCMChunk(unitID: 7, samples: sine(seconds: 0.1, rate: 48_000), sampleRate: 48_000), epoch: 1, gainDB: 0)
        output.finishUnit(7, epoch: 1, pauseAfter: 0)
        try output.resume()
        _ = try render(output, seconds: 0.3)

        await events.wait(count: 1)
        _ = output.unitFinishedEvents()
        await events.ended.wait("the stream to end")
        #expect(events.received == [UnitFinished(epoch: 1, unitID: 7)])
    }

    @Test("a new subscription drops what was scheduled before it, even with a matching epoch")
    func resubscribeDropsEarlierUnits() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let first = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        _ = try render(output, seconds: 0.2)

        let second = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.2, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        let rendered = try render(output, seconds: 1.2)

        await first.ended.wait("the replaced stream to end")
        await second.wait(count: 1)
        #expect(first.received == [])
        #expect(second.received == [UnitFinished(epoch: 0, unitID: 0)])
        let sound = try #require(soundSpan(in: rendered))
        #expect(abs(sound.count - 9_600) <= 16)
    }

    @Test("a unit's pause plays as silence before the next unit")
    func pauseAfterIsSilence() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.25, rate: 24_000), sampleRate: 24_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0.5)
        output.schedule(PCMChunk(unitID: 1, samples: sine(seconds: 0.25, rate: 24_000), sampleRate: 24_000), epoch: 0, gainDB: 0)
        output.finishUnit(1, epoch: 0, pauseAfter: 0)
        try output.resume()

        let rendered = try render(output, seconds: 1.5)
        let sound = try #require(soundSpan(in: rendered))
        let gap = try #require(longestQuiet(in: rendered, within: sound))
        #expect(abs(gap.count - 24_000) <= 48)
        #expect(peak(rendered[(gap.lowerBound + 100)..<(gap.upperBound - 100)]) < 1e-4)
        await events.wait(count: 2)
    }

    @Test("a unit with no audio plays only its pause and still finishes")
    func pauseOnlyUnit() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.finishUnit(0, epoch: 0, pauseAfter: 0.3)
        output.schedule(PCMChunk(unitID: 1, samples: sine(seconds: 0.2, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(1, epoch: 0, pauseAfter: 0)
        try output.resume()

        let rendered = try render(output, seconds: 1)
        let sound = try #require(soundSpan(in: rendered))
        #expect(abs(sound.lowerBound - 14_400) <= 128)
        await events.wait(count: 2)
        #expect(events.received.map(\.unitID) == [0, 1])
    }

    @Test("a +6 dB voice gain doubles a quiet signal")
    func voiceGain() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.5, rate: 48_000, amplitude: 0.05), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0.2)
        output.schedule(PCMChunk(unitID: 1, samples: sine(seconds: 0.5, rate: 48_000, amplitude: 0.05), sampleRate: 48_000), epoch: 0, gainDB: 6)
        output.finishUnit(1, epoch: 0, pauseAfter: 0)
        try output.resume()

        let rendered = try render(output, seconds: 1.5)
        let plain = peak(rendered[4_800..<19_200])
        let louder = peak(rendered[38_400..<52_800])
        #expect(abs(louder / plain - pow(10, 6.0 / 20)) < 0.005)
        await events.wait(count: 2)
    }

    @Test("loud speech pulls the output down slowly, never per sentence")
    func levelling() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.5, rate: 48_000, amplitude: 0.5), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        _ = try render(output, seconds: 0.6)
        await events.wait(count: 1)
        let afterOneSentence = output.level.gainDB
        #expect(afterOneSentence < -0.5 && afterOneSentence > -2.5)

        output.schedule(PCMChunk(unitID: 1, samples: sine(seconds: 9, rate: 48_000, amplitude: 0.5), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(1, epoch: 0, pauseAfter: 0)
        _ = try render(output, seconds: 9.2)
        await events.wait(count: 2)
        #expect(output.level.gainDB < -9.5)

        let expected = 0.5 * Float(output.level.gain)
        output.schedule(PCMChunk(unitID: 2, samples: sine(seconds: 0.5, rate: 48_000, amplitude: 0.5), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(2, epoch: 0, pauseAfter: 0)
        let levelled = try render(output, seconds: 0.5)
        #expect(abs(peak(levelled[12_000..<24_000]) - expected) < 0.005)
    }

    @Test("an output change pauses without a fade, ends the stream and calls back once")
    func outputChangePauses() async throws {
        let monitor = FakeOutputDeviceMonitor()
        let output = try ReadAloudOutput(offline: true, monitor: monitor)
        var changes = 0
        output.onOutputChanged = { changes += 1 }
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        #expect(monitor.starts == [nil])
        #expect(monitor.isWatching)
        _ = try render(output, seconds: 0.2)
        let before = output.generation

        monitor.simulateChange()
        #expect(output.state == .paused)
        #expect(output.generation == before + 1)
        #expect(output.fadeTask == nil)
        #expect(changes == 1)
        #expect(!monitor.isWatching)
        #expect(throws: (any Error).self) { try output.renderOffline(frames: 256) }
        await events.ended.wait("the stream to end")
        #expect(events.received == [])

        monitor.simulateChange()
        output.engineConfigurationChanged()
        #expect(changes == 1)
    }

    @Test("resuming after an output change plays none of the audio queued before it")
    func resumeAfterOutputChange() async throws {
        let monitor = FakeOutputDeviceMonitor()
        let output = try ReadAloudOutput(offline: true, monitor: monitor)
        _ = output.unitFinishedEvents()
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        _ = try render(output, seconds: 0.2)
        monitor.simulateChange()

        try output.resume()
        #expect(output.state == .playing)
        #expect(monitor.starts.count == 2)
        #expect(peak(try render(output, seconds: 1)) == 0)

        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.2, rate: 48_000), sampleRate: 48_000), epoch: 1, gainDB: 0)
        output.finishUnit(0, epoch: 1, pauseAfter: 0)
        try output.resume()
        _ = try render(output, seconds: 0.4)
        await events.wait(count: 1)
        #expect(events.received == [UnitFinished(epoch: 1, unitID: 0)])
    }

    @Test("an idle output ignores a change of output")
    func idleIgnoresOutputChange() throws {
        let monitor = FakeOutputDeviceMonitor()
        let output = try ReadAloudOutput(offline: true, monitor: monitor)
        var changes = 0
        output.onOutputChanged = { changes += 1 }
        monitor.simulateChange()
        output.engineConfigurationChanged()
        #expect(output.state == .idle)
        #expect(changes == 0)
    }

    @Test("an engine configuration change while reading takes the output-change path")
    func configurationChangePauses() throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        var changes = 0
        output.onOutputChanged = { changes += 1 }
        _ = output.unitFinishedEvents()
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        try output.resume()
        output.engineConfigurationChanged()
        #expect(output.state == .paused)
        #expect(changes == 1)
    }

    @Test("a faded pause ramps to silence, then pauses the engine; resume picks up where it stopped")
    func fadedPause() async throws {
        let clock = TestClock()
        let output = try ReadAloudOutput(offline: true, monitor: nil, clock: clock)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        let start = try render(output, seconds: 0.1)

        output.pause(fade: true)
        #expect(output.state == .paused)
        var fading: [Float] = []
        for _ in 0..<8 {
            fading += samples(of: try output.renderOffline(frames: 256))
        }
        #expect(peak(fading[..<128]) > 0.05)
        #expect(peak(fading[1_536...]) == 0)

        let fade = try #require(output.fadeTask)
        await clock.waitForSleeper()
        clock.advance(by: ReadAloudOutput.fadeOutDuration)
        await fade.value
        #expect(throws: (any Error).self) { try output.renderOffline(frames: 256) }

        try output.resume()
        let rest = try render(output, seconds: 1)
        await events.wait(count: 1)
        #expect(abs(audibleFrames(rest) - (48_000 - start.count - fading.count)) <= 128)
    }

    @Test("an unfaded pause stops the engine at once and keeps the queued audio")
    func immediatePause() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let events = EventLog(output.unitFinishedEvents())
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 0.5, rate: 48_000), sampleRate: 48_000), epoch: 0, gainDB: 0)
        output.finishUnit(0, epoch: 0, pauseAfter: 0)
        try output.resume()
        let start = try render(output, seconds: 0.2)

        output.pause(fade: false)
        #expect(output.state == .paused)
        #expect(throws: (any Error).self) { try output.renderOffline(frames: 256) }

        try output.resume()
        let rest = try render(output, seconds: 0.5)
        await events.wait(count: 1)
        let heard = try #require(soundSpan(in: start + rest))
        #expect(abs(heard.count - 24_000) <= 16)
    }

    @Test("a stop leaves no tail from the effects behind")
    func stopLeavesNoTail() throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        _ = output.unitFinishedEvents()
        output.setSpeed(1.5)
        output.schedule(PCMChunk(unitID: 0, samples: sine(seconds: 1, rate: 48_000, amplitude: 0.8), sampleRate: 48_000), epoch: 0, gainDB: 0)
        try output.resume()
        _ = try render(output, seconds: 0.3)

        output.stop()
        try output.resume()
        #expect(peak(try render(output, seconds: 0.3)) == 0)
    }

    @Test("a caller on another actor drives the output through the sink protocol")
    func callerOnAnActor() async throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        let caller = SinkCaller(sink: output)
        let events = EventLog(try await caller.playOneUnit())
        _ = try render(output, seconds: 0.5)
        await events.wait(count: 1)
        #expect(events.received == [UnitFinished(epoch: 2, unitID: 4)])
        #expect(output.speed == 1.25)
    }

    @Test("an idle output renders nothing until resumed")
    func idleDoesNotRender() throws {
        let output = try ReadAloudOutput(offline: true, monitor: nil)
        _ = output.unitFinishedEvents()
        #expect(throws: (any Error).self) { try output.renderOffline(frames: 256) }
    }
}

private actor SinkCaller {
    let sink: any ReadAloudOutputSink

    init(sink: any ReadAloudOutputSink) {
        self.sink = sink
    }

    func playOneUnit() async throws -> AsyncStream<UnitFinished> {
        let events = await sink.unitFinishedEvents()
        await sink.setSpeed(1.25)
        let samples = (0..<4_800).map { Float(0.1 * sin(2 * Double.pi * 440 * Double($0) / 24_000)) }
        await sink.schedule(PCMChunk(unitID: 4, samples: samples, sampleRate: 24_000), epoch: 2, gainDB: 0)
        await sink.finishUnit(4, epoch: 2, pauseAfter: 0.05)
        try await sink.resume()
        return events
    }
}

@MainActor
private final class EventLog {
    let ended: TestSignal
    private let log: Awaitable<[UnitFinished]>
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<UnitFinished>) {
        let log = Awaitable<[UnitFinished]>([])
        let ended = TestSignal()
        self.log = log
        self.ended = ended
        task = Task {
            for await event in stream {
                log.update { $0.append(event) }
            }
            ended.fire()
        }
    }

    var received: [UnitFinished] { log.value }

    func wait(count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await log.wait(until: { $0.count >= count }, "\(count) unit-finished event(s)", sourceLocation: sourceLocation)
    }
}

private func sine(seconds: Double, rate: Double, amplitude: Float = 0.1, frequency: Double = 440) -> [Float] {
    (0..<Int(seconds * rate)).map { index in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
    }
}

@MainActor
private func render(_ output: ReadAloudOutput, seconds: Double) throws -> [Float] {
    samples(of: try output.renderOffline(frames: AVAudioFrameCount(seconds * ReadAloudOutput.sampleRate)))
}

private func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

private let audible: Float = 1e-3

private func soundSpan(in samples: [Float]) -> Range<Int>? {
    guard let first = samples.firstIndex(where: { abs($0) > audible }),
          let last = samples.lastIndex(where: { abs($0) > audible })
    else { return nil }
    return first..<(last + 1)
}

private func longestQuiet(in samples: [Float], within span: Range<Int>) -> Range<Int>? {
    var best: Range<Int>?
    var start: Int?
    for index in span {
        if abs(samples[index]) <= audible {
            if start == nil { start = index }
        } else if let quietStart = start {
            if index - quietStart > best?.count ?? 0 { best = quietStart..<index }
            start = nil
        }
    }
    return best
}

private func audibleFrames(_ samples: [Float]) -> Int {
    soundSpan(in: samples)?.count ?? 0
}

private func peak(_ samples: some Collection<Float>) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

private func maxCurvature(_ samples: ArraySlice<Float>) -> Float {
    var worst: Float = 0
    var index = samples.startIndex + 1
    while index < samples.endIndex - 1 {
        worst = max(worst, abs(samples[index + 1] - 2 * samples[index] + samples[index - 1]))
        index += 1
    }
    return worst
}
