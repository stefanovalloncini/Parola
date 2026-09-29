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
    public nonisolated let levelMeter = LevelMeter()
    private var captureFailure: String?

    public init() {
        self.outputURL = RecordingScratch.fileURL(prefix: "parola-system")
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
        guard stream == nil else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            ParolaLog.error(.audioCapture, "screencapturekit unavailable", [.error: .error(error)])
            throw ParolaError.captureUnavailable("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            ParolaLog.error(.audioCapture, "no display available for system audio")
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

        let handler = SampleHandler(
            converter: converter,
            writer: CaptureFileWriter(file: writeFile),
            outputFormat: outputFormat,
            queue: callbackQueue,
            onLevel: { [levelMeter] in levelMeter.record($0) }
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: handler)
        do {
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: callbackQueue)
            try await stream.startCapture()
        } catch {
            ParolaLog.error(
                .audioCapture,
                "system audio capture failed to start",
                [.error: .error(error)]
            )
            try? await stream.stopCapture()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        self.stream = stream
        self.handler = handler
    }

    public func prepare() async throws -> URL {
        try await stop()
        if let captureFailure {
            ParolaLog.error(.audioRecording, "system audio take cut short by a write failure")
            throw CaptureInterrupted(url: outputURL, reason: captureFailure)
        }
        return outputURL
    }

    public func inFlightURL() -> URL? { outputURL }

    public func cancel() async {
        try? await stop()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let handler {
            await handler.drain()
            captureFailure = handler.failure
        }
        handler = nil
        levelMeter.reset()
    }
}

// Unchecked Sendable: state is set in init, then mutated only on the serial DispatchQueue
// passed in via `queue` (ScreenCaptureKit's sample-handler queue). `drain()` synchronises
// with that queue before the owning actor releases this handler.
@available(macOS 13.0, *)
private final class SampleHandler: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let converter: AVAudioConverter
    private let writer: CaptureFileWriter
    private let outputFormat: AVAudioFormat
    private let queue: DispatchQueue
    private let onLevel: @Sendable (Float) -> Void
    private var sampleScratch: AVAudioPCMBuffer?
    private var outputScratch: AVAudioPCMBuffer?

    var failure: String? { writer.failure }

    init(
        converter: AVAudioConverter,
        writer: CaptureFileWriter,
        outputFormat: AVAudioFormat,
        queue: DispatchQueue,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.converter = converter
        self.writer = writer
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
        guard let copied = SystemAudioSampleCopy.copy(
            sampleBuffer: sampleBuffer,
            srcFormat: srcFormat,
            frameCount: frameCount,
            reusing: &sampleScratch
        ) else {
            return
        }

        guard let outBuffer = StreamChunkConverter.convert(
            chunk: copied,
            with: converter,
            to: outputFormat,
            reusing: &outputScratch
        ) else { return }
        writer.write(outBuffer)
        onLevel(AudioLevel.normalised(of: copied))
    }

    func drain() async {
        await queue.drain()
    }
}

/// Copies samples out of a capture callback's sample buffer into a fresh PCM buffer. The
/// original `CMBlockBuffer` may be returned to ScreenCaptureKit's pool the moment the
/// callback returns — copying decouples our buffer's lifetime from theirs.
@available(macOS 13.0, *)
enum SystemAudioSampleCopy {
    /// Copies into `scratch`, growing it when a callback delivers more frames; the returned buffer is the scratch itself.
    static func copy(
        sampleBuffer: CMSampleBuffer,
        srcFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        reusing scratch: inout AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        if (scratch?.frameCapacity ?? 0) < frameCount || scratch?.format != srcFormat {
            scratch = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        }
        guard let copy = scratch else { return nil }
        copy.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: copy.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return copy
    }
}

#endif
