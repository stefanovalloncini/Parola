import Foundation
import Testing
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreVideo
@testable import ParolaCore

@Suite("Subtitle burn end-to-end")
struct SubtitleBurnTests {
    @Test("Caption pixels appear during a cue and are absent before it")
    func burnRendersCaptionPixels() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-burn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("src.mp4")
        let out = dir.appendingPathComponent("out.mp4")
        try await writeBlackVideo(to: src, width: 320, height: 240, seconds: 2.0)

        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0.5, end: 1.5, text: "BURNED CAPTION")],
            language: "unknown",
            modelName: "test",
            durationSeconds: 2.0
        )
        let reports = ProgressReports()
        try await SubtitleBurner.burn(transcript: transcript, video: src, to: out) { fraction in
            reports.append(fraction)
        }
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(OutputMarker.isMarked(out))

        // A short clip can finish between polls, so the callback may never fire; when it does,
        // every report must be a sane, non-decreasing fraction.
        let observed = reports.values
        #expect(observed.allSatisfy { (0.0...1.0).contains($0) })
        #expect(observed == observed.sorted())

        let duringCue = try await brightPixelCount(of: out, atSeconds: 1.0)
        let beforeCue = try await brightPixelCount(of: out, atSeconds: 0.1)

        // The black source has no bright pixels; a rendered white caption adds hundreds.
        // CATextLayer's text drew nothing in this export path — the bug this guards against.
        #expect(duringCue > 100)
        #expect(beforeCue == 0)
    }

    @Test("renderTextImage rasterizes glyphs and returns nil for empty text")
    func renderTextImageProducesGlyphs() throws {
        let font = Format.cascadingFont(name: "Helvetica-Bold", size: 28, language: "unknown")
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let box = CGSize(width: 240, height: 84)

        let image = try #require(SubtitleBurner.renderTextImage(text: "ABC", font: font, color: white, size: box, scale: 2))
        #expect(image.width == 480)
        #expect(image.height == 168)
        #expect(brightPixelCount(in: image) > 50)

        #expect(SubtitleBurner.renderTextImage(text: "", font: font, color: white, size: box, scale: 2) == nil)
    }
}

private final class ProgressReports: @unchecked Sendable {
    // NSLock-guarded storage; the burner invokes the callback off the test's task.
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func writeBlackVideo(to url: URL, width: Int, height: Int, seconds: Double) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let fps: Int32 = 30
    let frames = Int(seconds * Double(fps))
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        writer.finishWriting { cont.resume() }
    }
}

private func brightPixelCount(of video: URL, atSeconds seconds: Double) async throws -> Int {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    return brightPixelCount(in: image)
}

private func brightPixelCount(in image: CGImage, threshold: Int = 180) -> Int {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var count = 0
    var i = 0
    while i < data.count {
        let luma = (Int(data[i]) * 299 + Int(data[i + 1]) * 587 + Int(data[i + 2]) * 114) / 1000
        if luma > threshold { count += 1 }
        i += 4
    }
    return count
}
