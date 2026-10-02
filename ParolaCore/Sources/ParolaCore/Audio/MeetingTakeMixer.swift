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
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][frame] }
                sink[frame] = sum / Float(channels)
            }
            mixed.frameLength = AVAudioFrameCount(frames)
            try target.write(from: mixed)
        }
    }

    /// Whether a file holds two channels, as a meeting's take does once its microphone is mixed in.
    public static func isStereo(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url))?.fileFormat.channelCount == 2
    }

    static func clamped(_ sample: Float) -> Float {
        min(1, max(-1, sample))
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
        var out: [Float] = []
        out.reserveCapacity(count)
        while out.count < count, file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(MeetingTakeMixer.chunkFrames, count - out.count)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[channel][frame] }
                out.append(sum * scale)
            }
        }
        if out.count < count { out.append(contentsOf: repeatElement(0, count: count - out.count)) }
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
        for index in 0..<count {
            let frame = Double(first + index)
            guard frame >= plan.micFirstOutputFrame else { continue }
            let position = plan.micFirstSourceFrame + (frame - plan.micFirstOutputFrame) * plan.micFramesPerOutputFrame
            let lower = Int(position)
            guard lower < plan.micFrames else { break }
            try fill(through: lower + 1)
            let a = sample(lower)
            let b = sample(lower + 1)
            out[index] = a + (b - a) * Float(position - Double(lower))
        }
        let nextFrame = Double(first + count)
        if nextFrame > plan.micFirstOutputFrame {
            forget(before: Int(plan.micFirstSourceFrame + (nextFrame - plan.micFirstOutputFrame) * plan.micFramesPerOutputFrame))
        }
        return out
    }

    private mutating func fill(through frame: Int) throws {
        while windowStart + window.count <= frame, read < plan.micFrames {
            let count = min(MeetingTakeMixer.chunkFrames, plan.micFrames - read)
            window.append(contentsOf: try source.next(count))
            read += count
        }
    }

    private func sample(_ frame: Int) -> Float {
        let index = frame - windowStart
        return index >= 0 && index < window.count ? window[index] : 0
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
        for frame in 0..<frames {
            channels[0][frame] = MeetingTakeMixer.clamped(left[frame])
            channels[1][frame] = MeetingTakeMixer.clamped(right[frame])
            mixed[frame] = (MeetingTakeMixer.clamped(left[frame]) + MeetingTakeMixer.clamped(right[frame])) / 2
        }
        stereoBuffer.frameLength = AVAudioFrameCount(frames)
        try stereo.write(from: stereoBuffer)
        guard let mono else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frames)
        try mono.write(from: monoBuffer)
    }
}
