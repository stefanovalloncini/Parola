import Accelerate
import AVFoundation
import Foundation

/// Folds a meeting's two recordings into one take: the Mac's audio on the left, your microphone on the right,
/// and a mono mix of both for an engine that hears one channel, the two averaged so loud overlapping speech never clips.
public enum MeetingTakeMixer {
    /// A microphone that ends short of the Mac audio by less than this fraction ran on a slower clock, so it is
    /// stretched to end with it; one shorter still stopped early, and one longer ran past, and both are only lined up.
    public static let driftTolerance = 0.0002

    /// How far a microphone may run past the Mac audio and still be cut where the Mac audio ends: about how much longer it
    /// records while Stop winds the Mac capture down. A longer run means the Mac capture stopped early, so your side is kept whole.
    public static let stopOverrunLimit: TimeInterval = 2

    static let chunkFrames = 32_768

    /// `macStart` and `micStart` say when each file's first sample was captured, which lines the two up; a microphone
    /// that stopped before the take did is never stretched, and `trimsMicOverrun` drops what it heard after the Mac
    /// audio ended, as at Stop, up to `stopOverrunLimit`; past that the Mac side gets silence to the end of yours.
    /// The stereo file is 16-bit; the mono mix is Float32.
    public static func mix(
        mac: URL, mic: URL, macStart: Date, micStart: Date, into stereo: URL, mono: URL?, micStoppedEarly: Bool = false,
        trimsMicOverrun: Bool = false
    ) throws {
        let macFile = try AVAudioFile(forReading: mac)
        let micFile = try AVAudioFile(forReading: mic)
        let rate = macFile.processingFormat.sampleRate
        let plan = MixPlan(
            macFrames: Int(macFile.length),
            rate: rate,
            micFrames: Int(micFile.length),
            micRate: micFile.processingFormat.sampleRate,
            offset: micStart.timeIntervalSince(macStart),
            tolerance: micStoppedEarly ? 0 : driftTolerance,
            trimsOverrun: trimsMicOverrun
        )
        var left = try MonoFileReader(file: macFile)
        var right = StretchedReader(source: try MonoFileReader(file: micFile), plan: plan)
        let writer = try MixWriter(stereo: stereo, mono: mono, rate: rate)
        var written = 0
        while written < plan.outputFrames {
            let count = min(chunkFrames, plan.outputFrames - written)
            let macSamples = try left.next(count)
            let micSamples = try right.next(count, startingAt: written)
            try writer.write(left: macSamples, right: micSamples)
            written += count
        }
    }

    /// The mono mix of a meeting's stereo take, for an engine run on it again.
    public static func downmix(stereo: URL, into mono: URL) throws {
        let file = try AVAudioFile(forReading: stereo)
        let format = file.processingFormat
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)),
              let mixed = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw ParolaError.audioLoadFailed(stereo, underlying: "could not build the mix buffers")
        }
        let target = try AVAudioFile(forWriting: mono, settings: output.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(format.channelCount)
        while file.framePosition < file.length {
            chunk.frameLength = 0
            try file.read(into: chunk, frameCount: AVAudioFrameCount(chunkFrames))
            let frames = Int(chunk.frameLength)
            guard frames > 0, let source = chunk.floatChannelData, let sink = mixed.floatChannelData?[0] else { break }
            Self.average(source, channels: channels, frames: frames, into: sink)
            mixed.frameLength = AVAudioFrameCount(frames)
            try target.write(from: mixed)
        }
    }

    /// Whether a file holds two channels, as a meeting's take does once its microphone is mixed in.
    public static func isStereo(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url))?.fileFormat.channelCount == 2
    }

    /// Averages the channels into `sink`, adding from a zero so a negative zero reads as positive, as the scalar sum did.
    static func average(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels count: Int,
        frames: Int,
        into sink: UnsafeMutablePointer<Float>
    ) {
        let length = vDSP_Length(frames)
        var zero: Float = 0
        vDSP_vsadd(channels[0], 1, &zero, sink, 1, length)
        guard count > 1 else { return }
        for channel in 1..<count { vDSP_vadd(sink, 1, channels[channel], 1, sink, 1, length) }
        var scale = 1 / Float(count)
        vDSP_vsmul(sink, 1, &scale, sink, 1, length)
    }

    static let limiterKnee: Float = 0.9
    // Below 16-bit full scale, so the take file never holds a clipped sample.
    static let limiterCeiling: Float = 0.99

    static func limited(_ sample: Float) -> Float {
        guard !sample.isNaN else { return 0 }
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let headroom = limiterCeiling - limiterKnee
        let shaped = limiterKnee + headroom * tanh((magnitude - limiterKnee) / headroom)
        return sample < 0 ? -shaped : shaped
    }
}

/// Where the microphone's samples land in the take.
struct MixPlan {
    let outputFrames: Int
    let micFirstOutputFrame: Double
    /// Microphone frames captured before the Mac audio began are skipped.
    let micFirstSourceFrame: Double
    let micFramesPerOutputFrame: Double
    let micFrames: Int

    func position(ofOutputFrame frame: Int) -> Double {
        micFirstSourceFrame + (Double(frame) - micFirstOutputFrame) * micFramesPerOutputFrame
    }

    init(macFrames: Int, rate: Double, micFrames: Int, micRate: Double, offset: TimeInterval, tolerance: Double, trimsOverrun: Bool) {
        self.micFrames = micFrames
        let natural = micRate / rate
        let start = max(0, offset * rate)
        let skipped = max(0, -offset * micRate)
        let usable = Double(micFrames) - skipped
        micFirstOutputFrame = start
        micFirstSourceFrame = skipped
        guard usable > 0 else {
            micFramesPerOutputFrame = natural
            outputFrames = macFrames
            return
        }
        let naturalEnd = start + usable / natural
        let span = Double(macFrames) - start
        let shortfall = Double(macFrames) - naturalEnd
        if span > 0, shortfall > 0, shortfall / span < tolerance {
            micFramesPerOutputFrame = usable / span
            outputFrames = macFrames
        } else {
            micFramesPerOutputFrame = natural
            let micEnd = Int(naturalEnd.rounded(.up))
            let trims = trimsOverrun && Double(micEnd - macFrames) <= MeetingTakeMixer.stopOverrunLimit * rate
            outputFrames = trims ? macFrames : max(macFrames, micEnd)
        }
    }
}

/// Reads a file front to back as one channel, its channels averaged, with silence once it runs out.
struct MonoFileReader {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let channels: Int

    init(file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(MeetingTakeMixer.chunkFrames)) else {
            throw ParolaError.audioLoadFailed(file.url, underlying: "could not build a read buffer")
        }
        self.file = file
        self.buffer = buffer
        self.channels = max(1, Int(file.processingFormat.channelCount))
    }

    mutating func next(_ count: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var filled = 0
        try out.withUnsafeMutableBufferPointer { destination in
            while filled < count, file.framePosition < file.length {
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(MeetingTakeMixer.chunkFrames, count - filled)))
                let frames = Int(buffer.frameLength)
                guard frames > 0, let data = buffer.floatChannelData, let base = destination.baseAddress else { break }
                MeetingTakeMixer.average(data, channels: channels, frames: frames, into: base + filled)
                filled += frames
            }
        }
        return out
    }
}

/// The microphone as the take hears it: silent until its first sample lands, then read at the plan's pace.
struct StretchedReader {
    private var source: MonoFileReader
    private let plan: MixPlan
    private var window: [Float] = []
    private var windowStart = 0
    private var read = 0

    init(source: MonoFileReader, plan: MixPlan) {
        self.source = source
        self.plan = plan
    }

    mutating func next(_ count: Int, startingAt first: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let firstActive = max(0, Int(plan.micFirstOutputFrame.rounded(.up)) - first)
        if firstActive < count {
            try fill(through: Int(plan.position(ofOutputFrame: first + count - 1)) + 1)
            out.withUnsafeMutableBufferPointer { fillActive(into: $0, from: firstActive, startingAt: first) }
        }
        let nextFrame = Double(first + count)
        if nextFrame > plan.micFirstOutputFrame {
            forget(before: Int(plan.position(ofOutputFrame: first + count)))
        }
        return out
    }

    private func fillActive(into out: UnsafeMutableBufferPointer<Float>, from firstActive: Int, startingAt first: Int) {
        window.withUnsafeBufferPointer { samples in
            func sample(_ frame: Int) -> Float {
                let index = frame - windowStart
                return index >= 0 && index < samples.count ? samples[index] : 0
            }
            for index in firstActive..<out.count {
                let position = plan.position(ofOutputFrame: first + index)
                let lower = Int(position)
                guard lower < plan.micFrames else { break }
                let a = sample(lower)
                let b = sample(lower + 1)
                out[index] = a + (b - a) * Float(position - Double(lower))
            }
        }
    }

    private mutating func fill(through frame: Int) throws {
        while windowStart + window.count <= frame, read < plan.micFrames {
            let count = min(MeetingTakeMixer.chunkFrames, plan.micFrames - read)
            window.append(contentsOf: try source.next(count))
            read += count
        }
    }

    private mutating func forget(before frame: Int) {
        let drop = min(window.count, frame - windowStart)
        guard drop > 0 else { return }
        window.removeFirst(drop)
        windowStart += drop
    }
}

/// Writes the take's stereo file and, when asked for, the mono mix beside it, a chunk at a time.
struct MixWriter {
    private let stereo: AVAudioFile
    private let mono: AVAudioFile?
    private let stereoBuffer: AVAudioPCMBuffer
    private let monoBuffer: AVAudioPCMBuffer

    init(stereo: URL, mono: URL?, rate: Double) throws {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(MeetingTakeMixer.chunkFrames)),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(MeetingTakeMixer.chunkFrames)) else {
            throw ParolaError.audioLoadFailed(stereo, underlying: "could not build the mix buffers")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.stereo = try AVAudioFile(forWriting: stereo, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.mono = try mono.map {
            try AVAudioFile(forWriting: $0, settings: monoFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        self.stereoBuffer = stereoBuffer
        self.monoBuffer = monoBuffer
    }

    func write(left: [Float], right: [Float]) throws {
        let frames = min(left.count, right.count)
        guard frames > 0, let channels = stereoBuffer.floatChannelData, let mixed = monoBuffer.floatChannelData?[0] else { return }
        left.withUnsafeBufferPointer { leftSamples in
            right.withUnsafeBufferPointer { rightSamples in
                var leftPeak: Float = 0
                var rightPeak: Float = 0
                vDSP_maxmgv(leftSamples.baseAddress!, 1, &leftPeak, vDSP_Length(frames))
                vDSP_maxmgv(rightSamples.baseAddress!, 1, &rightPeak, vDSP_Length(frames))
                var leftSquares: Float = 0
                var rightSquares: Float = 0
                vDSP_svesq(leftSamples.baseAddress!, 1, &leftSquares, vDSP_Length(frames))
                vDSP_svesq(rightSamples.baseAddress!, 1, &rightSquares, vDSP_Length(frames))
                let hasNaN = (leftSquares + rightSquares).isNaN
                if !hasNaN, leftPeak <= MeetingTakeMixer.limiterKnee, rightPeak <= MeetingTakeMixer.limiterKnee {
                    channels[0].update(from: leftSamples.baseAddress!, count: frames)
                    channels[1].update(from: rightSamples.baseAddress!, count: frames)
                    if mono != nil {
                        var half: Float = 0.5
                        vDSP_vasm(leftSamples.baseAddress!, 1, rightSamples.baseAddress!, 1, &half, mixed, 1, vDSP_Length(frames))
                    }
                } else {
                    for frame in 0..<frames {
                        let leftLimited = MeetingTakeMixer.limited(leftSamples[frame])
                        let rightLimited = MeetingTakeMixer.limited(rightSamples[frame])
                        channels[0][frame] = leftLimited
                        channels[1][frame] = rightLimited
                        mixed[frame] = (leftLimited + rightLimited) / 2
                    }
                }
            }
        }
        stereoBuffer.frameLength = AVAudioFrameCount(frames)
        try stereo.write(from: stereoBuffer)
        guard let mono else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frames)
        try mono.write(from: monoBuffer)
    }
}
