import AVFoundation

/// Converts one captured buffer of a live stream through a persistent `AVAudioConverter`.
///
/// The input block signals `.noDataNow` (never `.endOfStream`) once the chunk is handed over:
/// end-of-stream latches the converter permanently, so every later chunk of the recording
/// would convert to zero frames and be dropped.
enum StreamChunkConverter {
    /// Converts into `scratch`, growing it when a chunk needs more room; the returned buffer is the scratch itself.
    static func convert(
        chunk: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat,
        reusing scratch: inout AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / chunk.format.sampleRate
        let capacity = AVAudioFrameCount(Double(chunk.frameLength) * ratio + 1024)
        if (scratch?.frameCapacity ?? 0) < capacity || scratch?.format != outputFormat {
            scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let outBuffer = scratch else { return nil }
        outBuffer.frameLength = 0

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return chunk
        }
        guard status != .error, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }
}
