import SwiftUI

/// The live-transcription look: text that has settled in the primary colour, the words that just
/// arrived dimmed behind it, and a caret blinking at the end.
enum StreamingReveal {
    static let caretBlinkPeriod: Double = 0.6

    static func attributed(settled: String, fresh: String) -> AttributedString {
        var text = AttributedString(settled)
        text.foregroundColor = DS.Color.primaryText
        if !fresh.isEmpty {
            var tail = AttributedString(fresh)
            tail.foregroundColor = DS.Color.primaryText.opacity(0.5)
            text.append(tail)
        }
        return text
    }

    static func caret(visible: Bool) -> Text {
        Text(verbatim: "\u{258F}")
            .foregroundStyle(DS.Color.accentText.opacity(visible ? 1 : 0))
    }
}
