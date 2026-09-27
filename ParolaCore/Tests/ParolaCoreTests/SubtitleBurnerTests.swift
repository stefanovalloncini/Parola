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

    @Test("Style defaults are sensible")
    func defaults() {
        let style = SubtitleBurner.Style()
        #expect(style.fontSize == 28)
        #expect(style.bottomInset == 60)
        #expect(style.strokeWidth == 4)
    }
}
