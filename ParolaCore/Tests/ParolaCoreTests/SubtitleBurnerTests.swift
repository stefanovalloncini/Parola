import Foundation
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

    @Test("Style defaults are sensible")
    func defaults() {
        let style = SubtitleBurner.Style()
        #expect(style.fontSize == 28)
        #expect(style.bottomInset == 60)
        #expect(style.strokeWidth == 4)
    }
}
