import SwiftUI

/// One `Text`, not a stack of them, so a row's meta line truncates whole instead of losing a fact.
struct MetaLine: View {
    private let parts: [String]
    private let tint: Color?

    init(_ parts: [String?], tint: Color? = nil) {
        self.parts = Self.present(parts)
        self.tint = tint
    }

    nonisolated static func present(_ parts: [String?]) -> [String] {
        parts.compactMap { $0 }.filter { !$0.isEmpty }
    }

    nonisolated static func joined(_ parts: [String?]) -> String {
        present(parts).joined(separator: " · ")
    }

    /// The middots sit back so the facts read as facts, not as a line of punctuation.
    nonisolated static func attributed(_ parts: [String], color: Color) -> AttributedString {
        var line = AttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                var separator = AttributedString(" · ")
                separator.foregroundColor = color.opacity(0.5)
                line.append(separator)
            }
            var piece = AttributedString(part)
            piece.foregroundColor = color
            line.append(piece)
        }
        return line
    }

    var body: some View {
        Text(Self.attributed(parts, color: tint ?? DS.Color.secondaryText))
            .font(DS.Font.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}
