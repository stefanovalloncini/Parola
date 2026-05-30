#if os(macOS)
import Foundation
import AVFoundation
import ScreenCaptureKit

/// Captures system audio output via ScreenCaptureKit and writes 16 kHz mono Float32 WAV.
///
/// Requires the host process to have Screen Recording permission. The very first call
/// will trigger the standard TCC prompt.
@available(macOS 13.0, *)
public actor SystemAudioSource: LiveAudioSource {
    private var stream: SCStream?
    private var handler: SampleHandler?
    private let outputURL: URL
    private let outputFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.parola.system-audio")
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]

    public init() {
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-system-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("unreachable: failed to build target audio format")
        }
        self.outputFormat = format
    }

    public func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw ParolaError.captureUnavailable("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            throw ParolaError.captureUnavailable("no display available for system audio capture")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        guard let srcFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ) else {
            throw ParolaError.captureUnavailable("could not build source audio format")
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: outputFormat) else {
            throw ParolaError.captureUnavailable("could not create audio converter")
        }
        let writeFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let levelSink: @Sendable (Float) -> Void = { [weak self] level in
            guard let self else { return }
            Task { await self.emitLevel(level) }
        }
        let handler = SampleHandler(
            converter: converter,
            writeFile: writeFile,
            outputFormat: outputFormat,
            queue: callbackQueue,
            onLevel: levelSink
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: handler)
        do {
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: callbackQueue)
            try await stream.startCapture()
        } catch {
            try? await stream.stopCapture()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        self.stream = stream
        self.handler = handler
    }

    public func prepare() async throws -> URL {
        try await stop()
        return outputURL
    }

    public func cancel() async {
        try? await stop()
        try? FileManager.default.removeItem(at: outputURL)
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

    private func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let handler {
            await handler.drain()
        }
        handler = nil
        for continuation in levelContinuations.values {
            continuation.finish()
        }
        levelContinuations.removeAll()
    }
}

// Unchecked Sendable: state is set in init, then mutated only on the serial DispatchQueue
// passed in via `queue` (ScreenCaptureKit's sample-handler queue). `drain()` synchronises
// with that queue before the owning actor releases this handler.
@available(macOS 13.0, *)
private final class SampleHandler: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let converter: AVAudioConverter
    private let writeFile: AVAudioFile
    private let outputFormat: AVAudioFormat
    private let queue: DispatchQueue
    private let onLevel: @Sendable (Float) -> Void

    init(
        converter: AVAudioConverter,
        writeFile: AVAudioFile,
        outputFormat: AVAudioFormat,
        queue: DispatchQueue,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.converter = converter
        self.writeFile = writeFile
        self.outputFormat = outputFormat
        self.queue = queue
        self.onLevel = onLevel
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else {
            return
        }
        let maybeSrcFormat: AVAudioFormat? = withUnsafePointer(to: asbd) { ptr in
            AVAudioFormat(streamDescription: ptr)
        }
        guard let srcFormat = maybeSrcFormat else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let copied = Self.copy(sampleBuffer: sampleBuffer, srcFormat: srcFormat, frameCount: frameCount) else {
            return
        }

        let ratio = outputFormat.sampleRate / copied.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(copied.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        let box = AudioBufferBox(buffer: copied)
        let convStatus = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if box.consumed { outStatus.pointee = .endOfStream; return nil }
            box.consumed = true
            outStatus.pointee = .haveData
            return box.buffer
        }
        if convStatus == .error || outBuffer.frameLength == 0 { return }
        try? writeFile.write(from: outBuffer)
        onLevel(AudioLevel.normalised(of: copied))
    }

    /// Allocates a fresh PCM buffer and copies samples out of the sample buffer. The original
    /// `CMBlockBuffer` may be returned to ScreenCaptureKit's pool the moment this method
    /// returns — copying decouples our buffer's lifetime from theirs.
    private static func copy(
        sampleBuffer: CMSampleBuffer,
        srcFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        var blockBufferOut: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard status == noErr else { return nil }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, bufferListNoCopy: &abl) else {
            return nil
        }
        inBuffer.frameLength = frameCount

        guard
            let copy = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount),
            let srcChannels = inBuffer.floatChannelData,
            let dstChannels = copy.floatChannelData
        else { return nil }
        copy.frameLength = frameCount

        let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
        for ch in 0..<Int(srcFormat.channelCount) {
            memcpy(dstChannels[ch], srcChannels[ch], bytesPerChannel)
        }
        _ = blockBufferOut
        return copy
    }

    /// Awaits a no-op block on the sample-handler queue. Any in-flight callback finishes
    /// before this returns.
    func drain() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
    }
}

/// Unchecked Sendable: the box is touched synchronously inside the single convert call that creates it.
private final class AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
#endif
