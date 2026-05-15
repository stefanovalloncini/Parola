#if os(macOS)
import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Captures system audio output via ScreenCaptureKit and writes 16 kHz mono Float32 WAV.
///
/// Requires the host process to have Screen Recording permission. The very first call
/// will trigger the standard TCC prompt.
///
/// Unchecked Sendable: `stream`, `writeFile`, and `converter` are read inside the SC
/// sample-handler queue and written from `start`/`stop` via `queue.sync`. The serial
/// queue is the lock — outside callers wait for in-flight samples to drain before
/// mutating these fields.
@available(macOS 13.0, *)
public final class SystemAudioSource: NSObject, AudioSource, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var writeFile: AVAudioFile?
    private let outputURL: URL
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "com.parola.system-audio")

    public override init() {
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
        super.init()
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
        // Minimal video config; we never read the frames but ScreenCaptureKit insists.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        // Source audio is 48 kHz stereo Float32; converter resamples to 16 kHz mono.
        guard let srcFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ) else {
            throw ParolaError.captureUnavailable("could not build source audio format")
        }
        let converter = AVAudioConverter(from: srcFormat, to: outputFormat)
        let writeFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        queue.sync {
            self.converter = converter
            self.writeFile = writeFile
        }

        try await stream.startCapture()
        self.stream = stream
    }

    public func prepare() async throws -> URL {
        try await stop()
        return outputURL
    }

    public func cancel() async {
        try? await stop()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        queue.sync {
            self.writeFile = nil
            self.converter = nil
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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

        var blockBufferOut: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBufferOut
        )
        guard status == noErr else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            bufferListNoCopy: &audioBufferList
        ) else { return }
        inBuffer.frameLength = frameCount

        guard let converter = self.converter, let writeFile = self.writeFile else { return }

        let ratio = outputFormat.sampleRate / inBuffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        let box = AudioBufferBox(buffer: inBuffer)
        let convStatus = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if box.consumed { outStatus.pointee = .endOfStream; return nil }
            box.consumed = true
            outStatus.pointee = .haveData
            return box.buffer
        }
        if convStatus == .error || outBuffer.frameLength == 0 { return }
        try? writeFile.write(from: outBuffer)
    }
}

/// Unchecked Sendable: each box is touched only by the converter callback that owns it,
/// inside the SC sample-handler queue where it's created.
private final class AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
#endif
