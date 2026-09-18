import AppKit
import SwiftUI
import Testing
@testable import Parola

@Suite("Inspector info rows")
@MainActor
struct InfoRowTests {

    private func height(_ value: String?) -> CGFloat {
        let host = NSHostingView(rootView: InfoRow(icon: "clock", label: "Audio duration", value: value))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// An em dash for a fact the document does not carry reads as a placeholder nobody designed.
    @Test("a row with no value takes no height instead of drawing an em dash")
    func emptyRowsCollapse() {
        #expect(height(nil) == 0)
        #expect(height("") == 0)
        #expect(height("00:04") > 0)
    }

    /// "2 min, 5 sec · 16× real time" does not fit the 300pt inspector column on one line.
    @Test("a wrapping row takes a second line instead of truncating away half the value")
    func wrappingRowsGrowInstead() {
        func height(wraps: Bool) -> CGFloat {
            let host = NSHostingView(
                rootView: InfoRow(
                    icon: "stopwatch",
                    label: "Transcribed in",
                    value: "2 min, 5 sec · 16×\u{00A0}real time",
                    numeric: true,
                    wraps: wraps
                )
                .frame(width: 220)
            )
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        #expect(height(wraps: true) > height(wraps: false))
    }

    @Test("a numeric value takes the mono tier and a name does not")
    func numericValuesAreMono() {
        let numeric = NSHostingView(
            rootView: InfoRow(icon: "character", label: "Characters", value: "834", numeric: true)
        )
        let text = NSHostingView(
            rootView: InfoRow(icon: "character", label: "Characters", value: "834", numeric: false)
        )
        #expect(numeric.fittingSize.width != text.fittingSize.width)
    }
}
