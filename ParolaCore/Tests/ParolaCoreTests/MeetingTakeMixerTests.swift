import AVFoundation
import Foundation
import Testing
import ParolaTestSupport
@testable import ParolaCore

@Suite("Meeting take mixer")
struct MeetingTakeMixerTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * TestAudio.sampleRate))
    }

    private func tone(_ seconds: Double, _ amplitude: Float, hz: Double = 220) -> [Float] {
        TestAudio.sine(seconds: seconds, hz: hz, amplitude: amplitude)
    }

    private func sineRMS(_ amplitude: Float) -> Float {
        amplitude / Float(2).squareRoot()
    }

    @Test("the mixed file is as long as the Mac audio and carries both sides")
    func mixesTwoSides() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.tone(seconds: 10, hz: 440, amplitude: 0.5, at: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.tone(seconds: 9.95, hz: 220, amplitude: 0.5, at: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let mono = dir.appendingPathComponent("mono.wav")
        let start = Date()
        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start.addingTimeInterval(0.05),
                                 into: stereo, mono: mono)
        let stereoFile = try AVAudioFile(forReading: stereo)
        let macFile = try AVAudioFile(forReading: mac)
        #expect(stereoFile.processingFormat.channelCount == 2)
        #expect(abs(Double(stereoFile.length) / stereoFile.fileFormat.sampleRate
                    - Double(macFile.length) / macFile.fileFormat.sampleRate) < 0.02)
        #expect(try AVAudioFile(forReading: mono).processingFormat.channelCount == 1)
    }

    @Test("the Mac audio goes on the left and your microphone on the right")
    func sidesKeepTheirChannels() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(2, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [tone(2, 0.2)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(abs(mixed.rms(channel: 0, from: 0.1, to: 1.9) - sineRMS(0.5)) < 0.01)
        #expect(abs(mixed.rms(channel: 1, from: 0.1, to: 1.9) - sineRMS(0.2)) < 0.01)
        #expect(try AVAudioFile(forReading: stereo).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test("a microphone that started later is silent on its side until its first sample")
    func lateMicIsLinedUp() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(2, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [tone(1.5, 0.4)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start.addingTimeInterval(0.5), into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(abs(mixed.seconds - 2) < 0.001)
        #expect(mixed.rms(channel: 1, from: 0, to: 0.48) < 0.001)
        #expect(mixed.rms(channel: 1, from: 0.55, to: 1.95) > 0.25)
    }

    @Test("a microphone that started first loses only what it heard before the Mac audio began")
    func earlyMicDropsItsHead() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(2, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [tone(0.5, 0.5) + tone(2, 0.1)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start.addingTimeInterval(-0.5), into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(abs(mixed.seconds - 2) < 0.001)
        #expect(abs(mixed.rms(channel: 1, from: 0.05, to: 1.95) - sineRMS(0.1)) < 0.01)
    }

    /// A mic that holds silence but for one 10 ms burst at `burst` seconds; a long take's tests run at 8 kHz, the lowest rate a WAV file is written at, to stay quick.
    private func micWithBurst(at burst: Double, seconds: Double, in dir: URL, rate: Double = 16_000) throws -> URL {
        var samples = [Float](repeating: 0, count: Int((seconds * rate).rounded()))
        let first = Int(burst * rate)
        for index in first..<min(samples.count, first + Int(rate / 100)) { samples[index] = 0.9 }
        return try TestAudio.write(channels: [samples], sampleRate: rate, to: dir.appendingPathComponent("mic.wav"))
    }

    private func macAudio(seconds: Double, in dir: URL, rate: Double = 16_000) throws -> URL {
        try TestAudio.write(
            channels: [TestAudio.sine(seconds: seconds, hz: 220, amplitude: 0.3, sampleRate: rate)], sampleRate: rate,
            to: dir.appendingPathComponent("mac.wav")
        )
    }

    private func frames(of file: URL) throws -> Int {
        Int(try AVAudioFile(forReading: file).length)
    }

    /// When the burst starts on your side of the mix.
    private func burstOnset(in stereo: URL) throws -> Double? {
        let mixed = try TestAudio.read(stereo)
        guard let index = mixed.channels[1].firstIndex(where: { $0 > 0.5 }) else { return nil }
        return Double(index) / mixed.sampleRate
    }

    @Test("a microphone that drifted less than a fiftieth of a percent is stretched to end with the Mac audio")
    func smallDriftIsStretched() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try macAudio(seconds: 50, in: dir, rate: 8_000)
        let mic = try micWithBurst(at: 25, seconds: 49.9925, in: dir, rate: 8_000)
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        #expect(try frames(of: stereo) == 50 * 8_000, "exactly as long as the Mac audio")
        let onset = try #require(try burstOnset(in: stereo))
        #expect(abs(onset - 25.00375) < 0.001, "stretched by 50/49.9925, so the burst moves 3.75 ms later")
    }

    /// When a sound the microphone heard `second` seconds into its file lands in the take, by the plan.
    private func landing(of second: Double, in plan: MixPlan, rate: Double) -> Double {
        (plan.micFirstOutputFrame + (second * rate - plan.micFirstSourceFrame) / plan.micFramesPerOutputFrame) / rate
    }

    @Test("in a 400 s take, a microphone 0.32 s short that nothing flagged is lined up, not stretched: a sound at 200 s stays at 200 s")
    func longTakeShortMicIsNotStretched() {
        let plan = MixPlan(
            macFrames: 400 * 16_000, rate: 16_000, micFrames: Int((400 - 0.32) * 16_000), micRate: 16_000, offset: 0,
            tolerance: MeetingTakeMixer.driftTolerance, trimsOverrun: false
        )
        #expect(abs(landing(of: 200, in: plan, rate: 16_000) - 200) < 0.000_001)
        #expect(plan.outputFrames == 400 * 16_000)
    }

    @Test("a microphone that ran past a 400 s take's Mac audio is never compressed, by 0.2 s or by less than the drift allows: a sound at 200 s stays at 200 s")
    func overrunIsNeverCompressed() {
        for (overrun, trims) in [(0.2, true), (0.2, false), (0.05, true), (0.05, false)] {
            let plan = MixPlan(
                macFrames: 400 * 16_000, rate: 16_000, micFrames: Int((400 + overrun) * 16_000), micRate: 16_000, offset: 0,
                tolerance: MeetingTakeMixer.driftTolerance, trimsOverrun: trims
            )
            #expect(abs(landing(of: 200, in: plan, rate: 16_000) - 200) < 0.000_001, "\(overrun) s past")
            #expect(plan.outputFrames == (trims ? 400 * 16_000 : Int((400 + overrun) * 16_000)), "Stop trims what is past the Mac audio")
        }
    }

    @Test("Stop's mix ends with the Mac audio and drops what the microphone heard after it, never compressing the rest")
    func stopTrimsTheOverrun() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try macAudio(seconds: 20, in: dir, rate: 8_000)
        let mic = try micWithBurst(at: 10, seconds: 20.2, in: dir, rate: 8_000)
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil, trimsMicOverrun: true)

        #expect(try frames(of: stereo) == 20 * 8_000)
        let onset = try #require(try burstOnset(in: stereo))
        #expect(abs(onset - 10) < 0.001)
    }

    @Test("a microphone half a percent short is lined up, not stretched: that is a mic that stopped, not drift")
    func halfAPercentIsNotDrift() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try macAudio(seconds: 20, in: dir)
        let mic = try micWithBurst(at: 10, seconds: 19.9, in: dir)
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        let onset = try #require(try burstOnset(in: stereo))
        #expect(abs(onset - 10) < 0.001)
    }

    @Test("a microphone that stopped early is never stretched, however little it is short: a sound at 25 s stays at 25 s")
    func stoppedMicIsNeverStretched() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try macAudio(seconds: 50, in: dir, rate: 8_000)
        let start = Date()
        for short in [0.3, 0.0075] {
            let mic = try micWithBurst(at: 25, seconds: 50 - short, in: dir, rate: 8_000)
            let stereo = dir.appendingPathComponent("stereo-\(short).wav")

            try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil, micStoppedEarly: true)

            let onset = try #require(try burstOnset(in: stereo))
            #expect(abs(onset - 25) < 0.001, "a mic \(short) s short")
            #expect(try frames(of: stereo) == 50 * 8_000)
        }
    }

    @Test("a microphone cut short is lined up and padded with silence, never stretched")
    func cutShortMicIsPadded() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(2, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [tone(1, 0.4)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(abs(mixed.seconds - 2) < 0.001)
        #expect(mixed.rms(channel: 1, from: 0.05, to: 0.95) > 0.25)
        #expect(mixed.rms(channel: 1, from: 1.05, to: 1.95) < 0.001)
    }

    @Test("a microphone that outlasts the Mac audio keeps all of it, with silence on the Mac side")
    func longerMicIsKept() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(1, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [tone(2, 0.4)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(abs(mixed.seconds - 2) < 0.001)
        #expect(mixed.rms(channel: 0, from: 1.05, to: 1.95) < 0.001)
        #expect(mixed.rms(channel: 1, from: 1.05, to: 1.95) > 0.25)
    }

    @Test("the mono mix carries both sides, and a stereo take downmixes to the same mono")
    func monoHoldsBothSides() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(1, 0.5, hz: 440) + silence(1)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [silence(1) + tone(1, 0.5)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let mono = dir.appendingPathComponent("mono.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: mono)

        let mixed = try TestAudio.read(mono)
        #expect(mixed.channels.count == 1)
        #expect(abs(mixed.rms(channel: 0, from: 0.05, to: 0.95) - sineRMS(0.25)) < 0.01, "the Mac side, averaged with your silence")
        #expect(abs(mixed.rms(channel: 0, from: 1.05, to: 1.95) - sineRMS(0.25)) < 0.01, "your side")

        let again = dir.appendingPathComponent("again.wav")
        try MeetingTakeMixer.downmix(stereo: stereo, into: again)
        let downmixed = try TestAudio.read(again)
        #expect(downmixed.frameCount == mixed.frameCount)
        let largest = zip(downmixed.channels[0], mixed.channels[0]).map { abs($0 - $1) }.max() ?? 1
        #expect(largest < 0.001, "the 16-bit stereo file differs from the float mix only by rounding")
    }

    @Test("loud speech on both sides at once never clips the mono mix")
    func monoKeepsHeadroom() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(1, 0.8, hz: 220)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [tone(1, 0.8, hz: 220)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let mono = dir.appendingPathComponent("mono.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: mono)

        let peak = try TestAudio.read(mono).channels[0].map(abs).max() ?? 0
        #expect(abs(peak - 0.8) < 0.01, "the two sides averaged, with no sample pinned at full scale")
        let again = dir.appendingPathComponent("again.wav")
        try MeetingTakeMixer.downmix(stereo: stereo, into: again)
        let downmixedPeak = try TestAudio.read(again).channels[0].map(abs).max() ?? 0
        #expect(downmixedPeak < 0.81)
    }

    @Test("a microphone that recorded nothing leaves your side silent and the take as long as the Mac audio")
    func emptyMicIsSilence() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(1, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [[]], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(abs(mixed.seconds - 1) < 0.001)
        #expect(mixed.rms(channel: 1, from: 0, to: 1) == 0)
        #expect(MeetingTakeMixer.isStereo(stereo))
        #expect(!MeetingTakeMixer.isStereo(mac))
    }
}
