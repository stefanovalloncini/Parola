import Foundation
import AVFoundation

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Records microphone input to a temporary WAV file (16 kHz mono Float32 — Whisper's expected format).
///
/// Lifecycle: `start()` to begin, `prepare()` to stop and return the file URL,
/// or `cancel()` to stop and discard.
public actor MicAudioSource: LiveAudioSource {
    private static let tapChunksPerMinuteAt48kHz = 700
    private static let maxBufferedTapChunks = 3 * tapChunksPerMinuteAt48kHz
    private let engine = AVAudioEngine()
    private let preferredDeviceUID: String?
    private let filePrefix: String
    private let fileURL: URL?
    private var session: Session?
    private var outputScratch: AVAudioPCMBuffer?
    public nonisolated let levelMeter = LevelMeter()

    private struct Session {
        var outputURL: URL
        var converter: AVAudioConverter
        var outputFormat: AVAudioFormat
        var writer: CaptureFileWriter
        var bufferContinuation: AsyncStream<BufferBox>.Continuation
        var consumerTask: Task<Void, Never>
    }

    /// `filePrefix` names the file after its purpose, which is how a sweep tells a take from dictation scratch;
    /// `fileURL`, when given, is the file itself, as for a meeting's microphone track named after its take.
    public init(deviceUID: String? = nil, filePrefix: String = "parola-mic", fileURL: URL? = nil) {
        self.preferredDeviceUID = deviceUID
        self.filePrefix = filePrefix
        self.fileURL = fileURL
    }

    public func inFlightURL() async -> URL? { session?.outputURL }

    public func setPaused(_ paused: Bool) async {
        session?.writer.setPaused(paused)
        guard !paused else { return }
        session?.converter.reset()
    }

    public func start() throws {
        guard session == nil else { return }

        let inputNode = engine.inputNode
        if let uid = preferredDeviceUID, !uid.isEmpty {
            try Self.applyInputDevice(uid: uid, to: inputNode)
        }
        let tapFormat = inputNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0 else {
            ParolaLog.error(.audioCapture, "microphone input format is invalid")
            throw ParolaError.captureUnavailable("microphone not available — input format invalid (mic permission?)")
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            ParolaLog.fault(.audioCapture, "could not build the capture format")
            throw ParolaError.captureUnavailable("could not create 16 kHz mono Float32 format")
        }
        guard let conv = AVAudioConverter(from: tapFormat, to: outFormat) else {
            ParolaLog.fault(.audioCapture, "could not create the audio converter")
            throw ParolaError.captureUnavailable("could not create audio converter \(tapFormat) → \(outFormat)")
        }

        let url = try fileURL.map { requested in
            try FileManager.default.createDirectory(at: requested.deletingLastPathComponent(), withIntermediateDirectories: true)
            return requested
        } ?? RecordingScratch.fileURL(prefix: filePrefix)
        let file = try AVAudioFile(
            forWriting: url,
            settings: outFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writer = CaptureFileWriter(file: file)

        let (stream, cont) = AsyncStream<BufferBox>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maxBufferedTapChunks)
        )
        let consumer = Task { [weak self] in
            for await box in stream {
                await self?.write(box: box)
            }
        }
        session = Session(
            outputURL: url,
            converter: conv,
            outputFormat: outFormat,
            writer: writer,
            bufferContinuation: cont,
            consumerTask: consumer
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, time in
            guard !writer.isPaused, let copy = Self.copy(buffer) else { return }
            let capturedAt = time.isHostTimeValid ? Self.instant(ofHostTime: time.hostTime) : nil
            if case .dropped = cont.yield(BufferBox(buffer: copy, capturedAt: capturedAt)) {
                writer.noteDrop()
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            ParolaLog.error(.audioCapture, "audio engine failed to start", [.error: .error(error)])
            inputNode.removeTap(onBus: 0)
            cont.finish()
            consumer.cancel()
            session = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            buffer.frameLength > 0,
            let src = buffer.floatChannelData,
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
            let dst = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for ch in 0..<Int(buffer.format.channelCount) { memcpy(dst[ch], src[ch], bytes) }
        return copy
    }

    /// The continuous-clock moment of a host time, which is how a tap stamps its buffer's first sample.
    static func instant(
        ofHostTime hostTime: UInt64, now: UInt64 = mach_absolute_time(), clockNow: ContinuousClock.Instant = .now
    ) -> ContinuousClock.Instant {
        guard now > hostTime else { return clockNow }
        return clockNow - .seconds(AVAudioTime.seconds(forHostTime: now - hostTime))
    }

    private func write(box: BufferBox) {
        levelMeter.record(AudioLevel.normalised(of: box.buffer), capturedAt: box.capturedAt)

        guard let current = session else { return }
        guard let outBuffer = StreamChunkConverter.convert(
            chunk: box.buffer,
            with: current.converter,
            to: current.outputFormat,
            reusing: &outputScratch
        ) else { return }
        current.writer.write(outBuffer)
    }

    public func prepare() async throws -> URL {
        guard let current = session else {
            throw ParolaError.captureUnavailable("recording was not started")
        }
        let url = current.outputURL
        let writer = current.writer
        await stop()
        if let failure = writer.failure {
            ParolaLog.error(
                .audioRecording,
                "take cut short by a write failure",
                [.count: .int(writer.droppedChunks)]
            )
            throw CaptureInterrupted(url: url, reason: failure)
        }
        return url
    }

    public func cancel() async {
        let url = session?.outputURL
        await stop()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func stop() async {
        guard let current = session else { return }
        // removeTap runs first, while the engine's render cycle still serialises with it: a tap block in flight has yielded its buffer before finish() closes the stream, and the consumer drains it before the file is released.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        current.bufferContinuation.finish()
        await current.consumerTask.value
        session = nil
        outputScratch = nil
        levelMeter.reset()
    }
}

/// Unchecked Sendable: each box owns a freshly-copied PCM buffer, handed off once to a single consumer.
private final class BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let capturedAt: ContinuousClock.Instant?
    init(buffer: AVAudioPCMBuffer, capturedAt: ContinuousClock.Instant?) {
        self.buffer = buffer
        self.capturedAt = capturedAt
    }
}

extension MicAudioSource {
    #if canImport(CoreAudio) && os(macOS)
    static func applyInputDevice(uid: String, to inputNode: AVAudioInputNode) throws {
        guard var deviceID = AudioDevices.deviceID(forUID: uid) else {
            return
        }
        guard let unit = inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw ParolaError.captureUnavailable("could not set input device (\(status))")
        }
    }
    #else
    static func applyInputDevice(uid: String, to inputNode: AVAudioInputNode) throws {}
    #endif
}
