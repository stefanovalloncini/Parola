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

    @Test("a microphone that drifted less than one percent is stretched to end with the Mac audio")
    func smallDriftIsStretched() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try TestAudio.write(channels: [tone(2, 0.5, hz: 440)], to: dir.appendingPathComponent("mac.wav"))
        let mic = try TestAudio.write(channels: [silence(1.918) + tone(0.1, 0.5)], to: dir.appendingPathComponent("mic.wav"))
        let stereo = dir.appendingPathComponent("stereo.wav")
        let start = Date()

        try MeetingTakeMixer.mix(mac: mac, mic: mic, macStart: start, micStart: start, into: stereo, mono: nil)

        let mixed = try TestAudio.read(stereo)
        #expect(mixed.frameCount == Int(2 * TestAudio.sampleRate), "exactly as long as the Mac audio")
        #expect(mixed.rms(channel: 1, from: 1.902, to: 1.915) > 0.2, "the microphone's last tenth of a second ends with the take")
        #expect(mixed.rms(channel: 1, from: 0.1, to: 1.89) < 0.001)
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
        #expect(abs(mixed.rms(channel: 0, from: 0.05, to: 0.95) - sineRMS(0.5)) < 0.01, "the Mac side")
        #expect(abs(mixed.rms(channel: 0, from: 1.05, to: 1.95) - sineRMS(0.5)) < 0.01, "your side")

        let again = dir.appendingPathComponent("again.wav")
        try MeetingTakeMixer.downmix(stereo: stereo, into: again)
        let downmixed = try TestAudio.read(again)
        #expect(downmixed.frameCount == mixed.frameCount)
        let largest = zip(downmixed.channels[0], mixed.channels[0]).map { abs($0 - $1) }.max() ?? 1
        #expect(largest < 0.001, "the 16-bit stereo file differs from the float mix only by rounding")
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
