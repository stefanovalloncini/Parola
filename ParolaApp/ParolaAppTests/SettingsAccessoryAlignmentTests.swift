import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola

@MainActor
@Suite("Settings accessory alignment", .serialized)
struct SettingsAccessoryAlignmentTests {

    private static let paneWidth: CGFloat = 620
    private static let rowInset: CGFloat = 16
    private static let scale: CGFloat = 2

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = UserDefaults(suiteName: "test-settings-alignment-\(UUID())")!
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("settings-alignment"))
    }

    /// Trailing edge of every control drawn inside a settings card, in pane points.
    /// A control keeps the same trailing edge for its whole height; wrapped text does not.
    private func accessoryEdges<Pane: View>(of pane: Pane) -> [CGFloat] {
        let renderer = ImageRenderer(content: pane.frame(width: Self.paneWidth))
        renderer.scale = Self.scale
        guard let image = renderer.cgImage else { return [] }
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(
            data: &data,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * image.width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
        func trailingInk(_ row: Int) -> Int? {
            let card = pixel(image.width - 6, row)
            guard card.3 > 200 else { return nil }
            for x in stride(from: image.width - 7, through: 0, by: -1) {
                let c = pixel(x, row)
                let delta = abs(c.0 - card.0) + abs(c.1 - card.1) + abs(c.2 - card.2) + abs(c.3 - card.3)
                if delta > 40 { return x }
            }
            return nil
        }

        var edges: [CGFloat] = []
        var bandStart = 0
        var bandEdge: Int?
        func closeBand(_ end: Int) {
            if let edge = bandEdge, end - bandStart >= 30 {
                edges.append(CGFloat(edge) / Self.scale)
            }
            bandEdge = nil
        }
        for row in 0..<image.height {
            let ink = trailingInk(row)
            if let ink, let current = bandEdge, abs(ink - current) <= 2 { continue }
            closeBand(row)
            if let ink {
                bandStart = row
                bandEdge = ink
            }
        }
        closeBand(image.height)
        return edges
    }

    private func expectFlush<Pane: View>(_ pane: Pane, count: Int, _ label: String) {
        let edges = accessoryEdges(of: pane)
        #expect(edges.count >= count, "\(label): found \(edges.count) accessory columns \(edges)")
        for edge in edges {
            #expect(abs(edge - (Self.paneWidth - Self.rowInset)) <= 2, "\(label): accessory ends at \(edge)pt")
        }
    }

    @Test("transcription defaults accessories share one trailing edge")
    func transcriptionDefaults() {
        withIsolatedDefaults { defaults in
            expectFlush(TranscriptionDefaultsPane().environment(makeModel(defaults)), count: 2, "transcription defaults")
        }
    }

    @Test("dictation accessories share one trailing edge")
    func dictation() {
        withIsolatedDefaults { defaults in
            expectFlush(DictationPane().environment(makeModel(defaults)), count: 2, "dictation")
        }
    }

    @Test("microphone accessories share one trailing edge")
    func microphone() {
        withIsolatedDefaults { defaults in
            expectFlush(MicrophonePane().environment(makeModel(defaults)), count: 2, "microphone")
        }
    }
}
