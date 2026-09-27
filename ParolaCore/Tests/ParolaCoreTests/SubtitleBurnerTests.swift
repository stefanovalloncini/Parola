import Foundation
import CoreMedia
import Testing
@testable import ParolaCore

@Suite("Subtitle burner")
struct SubtitleBurnerTests {
    @Test("renderSize is unchanged for an identity transform")
    func identityTransform() {
        let size = CGSize(width: 1280, height: 720)
        let computed = SubtitleBurner.renderSize(naturalSize: size, transform: .identity)
        #expect(computed == size)
    }

    @Test("renderSize swaps for a 90-degree rotation")
    func rotated90() {
        let size = CGSize(width: 1280, height: 720)
        let transform = CGAffineTransform(rotationAngle: .pi / 2)
        let computed = SubtitleBurner.renderSize(naturalSize: size, transform: transform)
        #expect(computed == CGSize(width: 720, height: 1280))
    }

    @Test("the frame duration is the source's shortest frame")
    func frameDurationFromMinFrame() {
        let duration = SubtitleBurner.frameDuration(minFrameDuration: CMTime(value: 1, timescale: 24), nominalFrameRate: 24)
        #expect(duration == CMTime(value: 1, timescale: 24))
    }

    @Test("without a usable shortest frame, the nominal rate sets it, then 30 fps")
    func frameDurationFallbacks() {
        let fromNominal = SubtitleBurner.frameDuration(minFrameDuration: .invalid, nominalFrameRate: 25)
        #expect(abs(fromNominal.seconds - 1.0 / 25) < 1e-6)
        let glitch = SubtitleBurner.frameDuration(minFrameDuration: CMTime(value: 1, timescale: 1000), nominalFrameRate: 29.97)
        #expect(abs(glitch.seconds - 1.0 / 29.97) < 1e-6)
        let nothing = SubtitleBurner.frameDuration(minFrameDuration: .invalid, nominalFrameRate: 0)
        #expect(nothing == CMTime(value: 1, timescale: 30))
    }

    @Test("caption sizes scale with the frame's short side")
    func metricsScaleWithTheFrame() {
        let style = SubtitleBurner.Style()
        let hd = SubtitleBurner.CaptionMetrics(style: style, renderSize: CGSize(width: 1920, height: 1080))
        let uhd = SubtitleBurner.CaptionMetrics(style: style, renderSize: CGSize(width: 3840, height: 2160))
        let portrait = SubtitleBurner.CaptionMetrics(style: style, renderSize: CGSize(width: 720, height: 1280))
        #expect(hd.fontSize == 28)
        #expect(uhd.fontSize == 56)
        #expect(uhd.bottomInset == 120)
        #expect(uhd.horizontalInset == 80)
        #expect(uhd.strokeWidth == 8)
        #expect(abs(portrait.fontSize - 28 * 720 / 1080) < 0.001)
    }

    @Test("the caption on screen is the one that started last and hasn't ended")
    func cueLookup() {
        let track = captionTrack([
            BurnCue(start: 1, end: 2, text: "one"),
            BurnCue(start: 2, end: 3, text: "two"),
            BurnCue(start: 5, end: 6, text: "three"),
        ])
        #expect(track.cueIndex(at: 0.5) == nil)
        #expect(track.cueIndex(at: 1) == 0)
        #expect(track.cueIndex(at: 1.99) == 0)
        #expect(track.cueIndex(at: 2) == 1)
        #expect(track.cueIndex(at: 4) == nil)
        #expect(track.cueIndex(at: 5.5) == 2)
        #expect(track.cueIndex(at: 6) == nil)
    }

    @Test("only the last two cues drawn stay in memory")
    func cacheHoldsTwo() {
        let track = captionTrack((0..<10).map { BurnCue(start: Double($0), end: Double($0) + 0.9, text: "cue \($0)") })
        for second in 0..<10 {
            #expect(track.image(at: Double(second) + 0.5) != nil)
        }
        #expect(track.cachedCueCount == 2)
    }

    @Test("a caption sits centred above the bottom inset")
    func captionPlacement() throws {
        let track = captionTrack([BurnCue(start: 0, end: 1, text: "Centred")])
        let extent = try #require(track.image(at: 0.5)?.extent)
        let halo = SubtitleBurner.Outline(color: CGColor(gray: 0, alpha: 1), blur: 8).padding
        #expect(abs(extent.midX - 960) <= 1)
        #expect(extent.minY == 60 - halo)
    }

    @Test("building the cues stops when the burn is cancelled")
    func cueBuildingIsCancellable() async {
        let transcript = Transcript(
            segments: (0..<2000).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "cue") },
            language: "en", modelName: "test"
        )
        let size = CGSize(width: 1920, height: 1080)
        let metrics = SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: size)
        let task = Task { () throws -> [BurnCue] in
            while !Task.isCancelled { await Task.yield() }
            return try SubtitleBurner.cues(
                from: transcript, options: ExportSpec.standard(for: .srt).options, metrics: metrics, renderSize: size
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func captionTrack(_ cues: [BurnCue]) -> BurnCaptionTrack {
        let size = CGSize(width: 1920, height: 1080)
        return BurnCaptionTrack(
            cues: cues, language: "en",
            metrics: SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: size),
            renderSize: size
        )
    }

    @Test("Style defaults are sensible")
    func defaults() {
        let style = SubtitleBurner.Style()
        #expect(style.fontSize == 28)
        #expect(style.bottomInset == 60)
        #expect(style.strokeWidth == 4)
    }
}
