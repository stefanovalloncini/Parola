import Foundation
@preconcurrency import AVFoundation

/// Records microphone input to a temporary WAV file (16 kHz mono Float32 — Whisper's expected format).
///
/// Lifecycle: `start()` to begin, `prepare()` to stop and return the file URL,
/// or `cancel()` to stop and discard.
public actor MicAudioSource: AudioSource {
    private let engine = AVAudioEngine()
    private var writeFile: AVAudioFile?
    private var outputURL: URL?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isRecording = false
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var bufferContinuation: AsyncStream<BufferBox>.Continuation?
    private var consumerTask: Task<Void, Never>?

    public init() {}

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
        guard !isRecording else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw ParolaError.captureUnavailable("microphone not available (input format invalid; permission may be denied)")
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

        self.outputFormat = outFormat
        self.converter = conv
        self.writeFile = file
        self.outputURL = url

        let (stream, cont) = AsyncStream<BufferBox>.makeStream(bufferingPolicy: .unbounded)
        self.bufferContinuation = cont
        self.consumerTask = Task { [weak self] in
            for await box in stream {
                await self?.write(box: box)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let copy = Self.copy(buffer) else { return }
            cont.yield(BufferBox(buffer: copy))
        }

        engine.prepare()
        try engine.start()
        isRecording = true
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
        emitLevel(MicAudioSource.normalisedLevel(of: box.buffer))

        guard let conv = converter, let outFormat = outputFormat, let file = writeFile else { return }
        let ratio = outFormat.sampleRate / box.buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(box.buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return }

        var error: NSError?
        let status = conv.convert(to: outBuffer, error: &error) { _, outStatus in
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

    private static func normalisedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channels[0]
        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumSquares += sample * sample
        }
        let rms = sqrtf(sumSquares / Float(frameCount))
        let minDb: Float = -55
        let db = 20 * log10f(max(rms, 1e-7))
        let clamped = max(minDb, min(0, db))
        return (clamped - minDb) / -minDb
    }

    public func prepare() throws -> URL {
        stop()
        guard let url = outputURL else {
            throw ParolaError.captureUnavailable("recording was not started")
        }
        return url
    }

    public func cancel() {
        stop()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }

    private func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        bufferContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
        writeFile = nil
        isRecording = false
        for continuation in levelContinuations.values {
            continuation.finish()
        }
        levelContinuations.removeAll()
    }
}

// Unchecked Sendable: each box owns a freshly-copied PCM buffer and is handed off to a single
// consumer (the actor's write(box:)), which then uses it synchronously inside convert(to:error:).
private final class BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
