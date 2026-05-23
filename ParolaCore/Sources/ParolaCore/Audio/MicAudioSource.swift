import Foundation
@preconcurrency import AVFoundation

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Records microphone input to a temporary WAV file (16 kHz mono Float32 — Whisper's expected format).
///
/// Lifecycle: `start()` to begin, `prepare()` to stop and return the file URL,
/// or `cancel()` to stop and discard.
public actor MicAudioSource: AudioSource {
    private let engine = AVAudioEngine()
    private let preferredDeviceUID: String?
    private var session: Session?
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]

    private struct Session {
        var outputURL: URL
        var converter: AVAudioConverter
        var outputFormat: AVAudioFormat
        var writeFile: AVAudioFile?
        var bufferContinuation: AsyncStream<BufferBox>.Continuation
        var consumerTask: Task<Void, Never>
    }

    public init(deviceUID: String? = nil) {
        self.preferredDeviceUID = deviceUID
    }

    /// Emits a normalised 0...1 amplitude per captured buffer. Multiple subscribers are supported.
    public func levels() -> AsyncStream<Float> {
        AsyncStream { continuation in
            let id = UUID()
            levelContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeLevelContinuation(id) }
            }
        }
    }

    private func removeLevelContinuation(_ id: UUID) {
        levelContinuations.removeValue(forKey: id)
    }

    private func emitLevel(_ level: Float) {
        for continuation in levelContinuations.values {
            continuation.yield(level)
        }
    }

    public func start() throws {
        guard session == nil else { return }

        let inputNode = engine.inputNode
        if let uid = preferredDeviceUID, !uid.isEmpty {
            try Self.applyInputDevice(uid: uid, to: inputNode)
        }
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw ParolaError.captureUnavailable("microphone not available — input format invalid (mic permission?)")
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ParolaError.captureUnavailable("could not create 16 kHz mono Float32 format")
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw ParolaError.captureUnavailable("could not create audio converter \(inputFormat) → \(outFormat)")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-mic-\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: outFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let (stream, cont) = AsyncStream<BufferBox>.makeStream(bufferingPolicy: .unbounded)
        let consumer = Task { [weak self] in
            for await box in stream {
                await self?.write(box: box)
            }
        }
        session = Session(
            outputURL: url,
            converter: conv,
            outputFormat: outFormat,
            writeFile: file,
            bufferContinuation: cont,
            consumerTask: consumer
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let copy = Self.copy(buffer) else { return }
            cont.yield(BufferBox(buffer: copy))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            cont.finish()
            consumer.cancel()
            session = nil
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

    private func write(box: BufferBox) {
        emitLevel(AudioLevel.normalised(of: box.buffer))

        guard let current = session, let file = current.writeFile else { return }
        let ratio = current.outputFormat.sampleRate / box.buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(box.buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: current.outputFormat, frameCapacity: outCap) else { return }

        var error: NSError?
        let status = current.converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if box.consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            box.consumed = true
            outStatus.pointee = .haveData
            return box.buffer
        }
        if status == .error || outBuffer.frameLength == 0 { return }
        try? file.write(from: outBuffer)
    }

    public func prepare() async throws -> URL {
        guard let url = session?.outputURL else {
            throw ParolaError.captureUnavailable("recording was not started")
        }
        await stop()
        return url
    }

    public func cancel() async {
        let url = session?.outputURL
        await stop()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func stop() async {
        guard let current = session else { return }
        // Order: stop engine, remove tap, finish continuation, drain consumer — writes must complete before the file handle is released.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        current.bufferContinuation.finish()
        await current.consumerTask.value
        session = nil
        for continuation in levelContinuations.values {
            continuation.finish()
        }
        levelContinuations.removeAll()
    }
}

/// Unchecked Sendable: each box owns a freshly-copied PCM buffer, handed off once to a single consumer.
private final class BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
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
