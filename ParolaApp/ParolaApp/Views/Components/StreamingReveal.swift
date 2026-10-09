import SwiftUI

/// The live-transcription look: settled text, the words that just arrived dimmed, a caret at the end.
enum StreamingReveal {
    static let caretBlinkPeriod: Double = 0.6
    static let caretGlyph = "\u{258F}"

    /// How far the words that have just arrived are held back, in the demo card as well as the live pane.
    static let freshOpacity: Double = 0.5

    static func attributed(settled: String, fresh: String) -> AttributedString {
        var text = AttributedString(settled)
        text.foregroundColor = DS.Color.primaryText
        if !fresh.isEmpty {
            var tail = AttributedString(fresh)
            tail.foregroundColor = DS.Color.primaryText.opacity(freshOpacity)
            text.append(tail)
        }
        return text
    }

    static func caret(visible: Bool) -> Text {
        Text(verbatim: caretGlyph)
            .foregroundStyle(DS.Color.accentInk.opacity(visible ? 1 : 0))
    }
}
