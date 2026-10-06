import AVFoundation
import ParolaCore

/// Brings one reading unit's audio to the output format. Every chunk of the unit goes through the same
/// converter, so the filter carries across the joins, and `flush()` drains what it still holds at the end.
final class UnitResampler {
    let unitID: Int
    let sourceRate: Double

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init?(unitID: Int, sourceRate: Double, outputFormat: AVAudioFormat) {
        guard sourceRate > 0,
              let inputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sourceRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.unitID = unitID
        self.sourceRate = sourceRate
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ samples: [Float], gain: Float) -> [Float] {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0]
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample * gain
        }
        return run(input, endOfStream: false)
    }

    func flush() -> [Float] {
        run(nil, endOfStream: true)
    }

    private func run(_ input: AVAudioPCMBuffer?, endOfStream: Bool) -> [Float] {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        var pending = input
        var output: [Float] = []
        while let slice = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: slice, error: &error) { _, inputStatus in
                if let next = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let channel = slice.floatChannelData?[0], slice.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(slice.frameLength)))
            }
            if status == .error {
                ParolaLog.error(.readAloud, "a reading unit could not be resampled", error.map { [.error: .error($0)] } ?? [:])
            }
            guard status == .haveData else { break }
        }
        return output
    }
}
