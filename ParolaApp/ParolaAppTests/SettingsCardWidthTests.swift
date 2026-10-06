import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Settings card width", .serialized)
struct SettingsCardWidthTests {
    private static let paneWidth: CGFloat = 620
    private static let scale: CGFloat = 2

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-settings-cards-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("settings-cards"))
    }

    /// The rows where a card is drawn at one pixel column, as [start, end) runs; shorter runs are buttons.
    private func cardRuns<Pane: View>(of pane: Pane) -> (leading: [Range<Int>], trailing: [Range<Int>]) {
        let renderer = ImageRenderer(content: pane.frame(width: Self.paneWidth, alignment: .leading))
        renderer.scale = Self.scale
        guard let image = renderer.cgImage else { return ([], []) }
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

        func runs(atColumn x: Int) -> [Range<Int>] {
            var found: [Range<Int>] = []
            var start: Int?
            for row in 0..<image.height {
                let opaque = data[(row * image.width + x) * 4 + 3] > 200
                if opaque, start == nil { start = row }
                if !opaque, let begun = start {
                    if row - begun >= 60 { found.append(begun..<row) }
                    start = nil
                }
            }
            if let begun = start, image.height - begun >= 60 { found.append(begun..<image.height) }
            return found
        }
        return (runs(atColumn: 12), runs(atColumn: image.width - 12))
    }

    private func expectFullWidthCards<Pane: View>(_ pane: Pane, atLeast count: Int, _ label: String) {
        let runs = cardRuns(of: pane)
        #expect(runs.leading.count >= count, "\(label): \(runs.leading.count) cards reach the leading edge \(runs)")
        let matched = runs.leading.count == runs.trailing.count && zip(runs.leading, runs.trailing).allSatisfy { lead, trail in
            abs(lead.lowerBound - trail.lowerBound) <= 3 && abs(lead.upperBound - trail.upperBound) <= 3
        }
        #expect(matched, "\(label): cards end short of the trailing edge \(runs)")
    }

    @Test("Advanced's cards span the pane")
    func advanced() {
        withIsolatedDefaults { defaults in
            expectFullWidthCards(AdvancedPane().environment(makeModel(defaults)), atLeast: 2, "advanced")
        }
    }

    @Test("MCP & Automation's cards line up with the other panes and span them")
    func automation() {
        withIsolatedDefaults { defaults in
            expectFullWidthCards(AutomationPane().environment(makeModel(defaults)), atLeast: 3, "automation")
        }
    }

    @Test("the bridge switch is named for what it controls")
    func bridgeSwitchName() throws {
        try withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = HostedWindow(AutomationPane().environment(model), width: Self.paneWidth, height: 1400)
            defer { hosted.close() }
            let elements = HostedAccessibility.elements(in: hosted.host)
            let match = elements.first { $0.identifier?.hasSuffix("Automation.Toggle.BridgeEnabled") == true }
            let toggle = try #require(match)
            #expect(toggle.name == String(localized: "MCP automation bridge"))
        }
    }
}
